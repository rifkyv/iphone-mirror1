"""iPhone Mirror receiver for Windows.

Receives the screen and game audio from the iPhone Mirror broadcast extension over USB,
decodes the video (hardware decoding when available) and shows it in a window that
TikTok LIVE Studio / OBS can capture. Audio plays on the PC's default output device.

Hotkeys in the mirror window:
  F11 / F      fullscreen on/off
  1            window size = exact video pixels (sharpest for Window Capture)
  R            rotate 90 degrees (if the picture is sideways)
  Up / Down    bitrate +2 / -2 Mbps (applied live)
  K            request a fresh keyframe
  M            mute / unmute PC audio
  T            always on top on/off
  Esc          leave fullscreen
"""

from __future__ import annotations

import argparse
import ctypes
import json
import os
import socket
import struct
import sys
import threading
import time
from pathlib import Path

import warnings

warnings.filterwarnings("ignore", message="Using SDL2 binaries from pysdl2-dll")

import av  # noqa: E402
import numpy as np  # noqa: E402
import sdl2  # noqa: E402

import usbmux  # noqa: E402

APP_VERSION = "1.0.0"
DEVICE_PORT = 7890
WINDOW_TITLE = "iPhone Mirror"
BASE_DIR = Path(__file__).resolve().parent
SETTINGS_FILE = BASE_DIR / "settings.json"

DEFAULT_SETTINGS = {
    "codec": "h264",  # h264 or hevc
    "bitrate_mbps": 20,
    "fps": 60,
    "max_long_side": 1920,  # 0 = native resolution
    "keyframe_interval": 2.0,
    "audio": True,
    "audio_latency_ms": 60,
    "hw_decode": True,
    "always_on_top": False,
}

MSG_HELLO, MSG_VIDEO, MSG_AUDIO, MSG_STATS = 1, 2, 3, 4
YUV_CONVERSION_JPEG, YUV_CONVERSION_BT709 = 0, 2  # SDL_YUV_CONVERSION_MODE values
ORIENTATION_ANGLE = {1: 0, 2: 0, 3: 180, 4: 180, 5: 90, 6: 90, 7: 270, 8: 270}


def log(msg: str) -> None:
    print(time.strftime("[%H:%M:%S] ") + msg, flush=True)


def load_settings() -> dict:
    settings = dict(DEFAULT_SETTINGS)
    try:
        settings.update(json.loads(SETTINGS_FILE.read_text(encoding="utf-8")))
    except FileNotFoundError:
        pass
    except Exception as error:
        log(f"settings.json tidak bisa dibaca ({error}), pakai default")
    return settings


def save_settings(settings: dict) -> None:
    try:
        SETTINGS_FILE.write_text(json.dumps(settings, indent=2), encoding="utf-8")
    except Exception as error:
        log(f"settings.json tidak bisa disimpan: {error}")


def device_config(settings: dict) -> dict:
    return {
        "cmd": "config",
        "proto": 1,
        "codec": "hevc" if settings["codec"] == "hevc" else "h264",
        "bitrate": int(max(1, min(100, float(settings["bitrate_mbps"]))) * 1_000_000),
        "fps": int(max(10, min(60, int(settings["fps"])))),
        "max_long_side": int(settings["max_long_side"]),
        "keyframe_interval": float(settings["keyframe_interval"]),
        "audio": bool(settings["audio"]),
    }


# ----------------------------------------------------------------------------- decoding


class VideoDecoder:
    def __init__(self, codec: str, hw: bool) -> None:
        self.codec = codec
        self.hw_name = None
        name = "hevc" if codec == "hevc" else "h264"
        hwaccel = None
        if hw:
            try:
                from av.codec.hwaccel import HWAccel, hwdevices_available

                available = hwdevices_available()
                for device_type in ("d3d11va", "dxva2", "videotoolbox", "vaapi", "cuda"):
                    if device_type in available:
                        hwaccel = HWAccel(device_type=device_type, allow_software_fallback=True)
                        self.hw_name = device_type
                        break
            except Exception:
                hwaccel = None
        try:
            self.ctx = av.CodecContext.create(name, "r", hwaccel=hwaccel)
        except Exception:
            self.ctx = av.CodecContext.create(name, "r")
            self.hw_name = None
        try:
            self.ctx.flags = int(self.ctx.flags) | int(av.codec.context.Flags.low_delay)
        except Exception:
            pass
        try:
            self.ctx.thread_type = "SLICE"  # frame threading would add latency
        except Exception:
            pass

    def decode(self, data: bytes) -> list:
        return self.ctx.decode(av.Packet(data))


class AudioOut:
    """Plays PCM from the iPhone on the default output device with a small, bounded queue."""

    def __init__(self, latency_ms: int) -> None:
        self.latency_ms = max(20, int(latency_ms))
        self.device = 0
        self.rate = 0
        self.started = False
        self.muted = False

    def _open(self, rate: int) -> None:
        self.close()
        want = sdl2.SDL_AudioSpec(rate, sdl2.AUDIO_F32SYS, 2, 256)
        have = sdl2.SDL_AudioSpec(0, 0, 0, 0)
        dev = sdl2.SDL_OpenAudioDevice(None, 0, ctypes.byref(want), ctypes.byref(have), 0)
        if dev == 0:
            log(f"Audio PC tidak bisa dibuka: {sdl2.SDL_GetError().decode(errors='ignore')}")
            return
        self.device, self.rate, self.started = dev, rate, False

    def close(self) -> None:
        if self.device:
            sdl2.SDL_CloseAudioDevice(self.device)
        self.device, self.rate, self.started = 0, 0, False

    def push(self, rate: int, channels: int, bits: int, flags: int, pcm: bytes) -> None:
        if channels <= 0 or rate <= 0 or not pcm:
            return
        is_float, big = bool(flags & 1), bool(flags & 2)
        endian = ">" if big else "<"
        if is_float and bits == 32:
            arr = np.frombuffer(pcm, dtype=endian + "f4").astype(np.float32)
        elif is_float and bits == 64:
            arr = np.frombuffer(pcm, dtype=endian + "f8").astype(np.float32)
        elif bits == 16:
            arr = np.frombuffer(pcm, dtype=endian + "i2").astype(np.float32) / 32768.0
        elif bits == 32:
            arr = np.frombuffer(pcm, dtype=endian + "i4").astype(np.float32) / 2147483648.0
        else:
            return
        frames = arr.size // channels
        if frames == 0:
            return
        arr = arr[: frames * channels].reshape(frames, channels)
        if channels == 1:
            arr = np.repeat(arr, 2, axis=1)
        elif channels > 2:
            arr = arr[:, :2]
        if self.muted:
            arr = np.zeros_like(arr)
        arr = np.ascontiguousarray(arr, dtype=np.float32)

        if self.device == 0 or self.rate != rate:
            self._open(rate)
            if self.device == 0:
                return
        bytes_per_ms = rate * 2 * 4 / 1000.0
        queued = sdl2.SDL_GetQueuedAudioSize(self.device)
        if queued > self.latency_ms * 2.5 * bytes_per_ms:
            # Too far behind (PC hiccup): drop the backlog so audio stays in sync.
            sdl2.SDL_ClearQueuedAudio(self.device)
            queued = 0
        sdl2.SDL_QueueAudio(self.device, arr.ctypes.data_as(ctypes.c_void_p), arr.nbytes)
        if not self.started and queued + arr.nbytes >= self.latency_ms * bytes_per_ms:
            sdl2.SDL_PauseAudioDevice(self.device, 0)
            self.started = True


# ----------------------------------------------------------------------------- network


class Link(threading.Thread):
    """Finds the iPhone, connects through usbmuxd, and feeds video/audio to the player."""

    def __init__(self, player: "Player", settings: dict, direct: str | None) -> None:
        super().__init__(daemon=True)
        self.player = player
        self.settings = settings
        self.direct = direct
        self.stop_event = threading.Event()
        self._sock: socket.socket | None = None
        self._send_lock = threading.Lock()
        self._last_status = ""
        self._last_key_request = 0.0
        self.device_stats: dict = {}
        self.rx_bytes = 0
        self.rx_frames = 0

    def status(self, text: str) -> None:
        if text != self._last_status:
            self._last_status = text
            log(text)

    def send(self, obj: dict) -> None:
        line = (json.dumps(obj) + "\n").encode()
        with self._send_lock:
            sock = self._sock
            if sock is None:
                return
            try:
                sock.sendall(line)
            except OSError:
                pass

    def request_keyframe(self) -> None:
        now = time.monotonic()
        if now - self._last_key_request > 0.5:
            self._last_key_request = now
            self.send({"cmd": "keyframe"})

    def _open(self) -> socket.socket:
        if self.direct:
            host, _, port = self.direct.rpartition(":")
            return socket.create_connection((host or "127.0.0.1", int(port)), timeout=3)
        devices = usbmux.list_devices()
        if not devices:
            raise ConnectionError("Menunggu iPhone... colok pakai kabel USB dan pilih 'Trust' di iPhone")
        last_error: Exception | None = None
        for dev in devices:
            try:
                return usbmux.connect(dev["DeviceID"], DEVICE_PORT, timeout=3)
            except Exception as error:
                last_error = error
        raise ConnectionError(
            "iPhone terdeteksi. Buka Control Center > tahan tombol Screen Recording > "
            "pilih 'iPhone Mirror' > Start Broadcast"
        ) from last_error

    def run(self) -> None:
        while not self.stop_event.is_set():
            try:
                sock = self._open()
            except Exception as error:
                self.status(str(error))
                self.stop_event.wait(1.0)
                continue
            try:
                self._session(sock)
            except Exception as error:
                if not self.stop_event.is_set():
                    self.status(f"Koneksi terputus ({error}). Menyambung ulang...")
            finally:
                with self._send_lock:
                    self._sock = None
                try:
                    sock.close()
                except OSError:
                    pass
                self.player.on_disconnect()
            self.stop_event.wait(0.5)

    def _session(self, sock: socket.socket) -> None:
        sock.settimeout(None)
        try:
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except OSError:
            pass
        with self._send_lock:
            self._sock = sock
        cfg = device_config(self.settings)
        self.send(cfg)
        self.status(
            f"Tersambung. Minta {cfg['codec'].upper()} {cfg['bitrate'] / 1e6:.0f} Mbps, "
            f"{cfg['fps']} fps, sisi panjang {cfg['max_long_side'] or 'asli'}"
        )
        reader = sock.makefile("rb", buffering=1 << 16)
        decoder: VideoDecoder | None = None
        waiting_key = True
        while not self.stop_event.is_set():
            header = reader.read(5)
            if len(header) < 5:
                raise ConnectionError("iPhone menutup koneksi")
            mtype, length = header[0], struct.unpack(">I", header[1:5])[0]
            if length > 64 * 1024 * 1024:
                raise ConnectionError("paket rusak")
            payload = reader.read(length)
            if len(payload) < length:
                raise ConnectionError("iPhone menutup koneksi")
            self.rx_bytes += 5 + length

            if mtype == MSG_VIDEO:
                if length < 10:
                    continue
                flags, orientation = payload[0], payload[1]
                is_key = bool(flags & 1)
                data = payload[10:]
                want_codec = "hevc" if flags & 2 else "h264"  # the iPhone says what it really sent
                if decoder is None or decoder.codec != want_codec:
                    decoder = VideoDecoder(want_codec, bool(self.settings["hw_decode"]))
                    log(f"Decoder {want_codec.upper()} siap ({'hardware ' + decoder.hw_name if decoder.hw_name else 'software'})")
                    waiting_key = True
                if waiting_key and not is_key:
                    self.request_keyframe()
                    continue
                waiting_key = False
                t0 = time.perf_counter()
                try:
                    frames = decoder.decode(data)
                except Exception:
                    waiting_key = True
                    self.request_keyframe()
                    continue
                dt = time.perf_counter() - t0
                for frame in frames:
                    self.rx_frames += 1
                    self.player.submit_frame(frame, ORIENTATION_ANGLE.get(orientation, 0), dt)
            elif mtype == MSG_AUDIO:
                if length < 8:
                    continue
                rate = struct.unpack(">I", payload[0:4])[0]
                self.player.audio.push(rate, payload[4], payload[5], payload[6], payload[8:])
            elif mtype == MSG_STATS:
                try:
                    self.device_stats = json.loads(payload.decode("utf-8"))
                except Exception:
                    pass
            elif mtype == MSG_HELLO:
                try:
                    hello = json.loads(payload.decode("utf-8"))
                    log(f"iPhone Mirror app versi {hello.get('app', '?')}, layar {hello.get('screen')}")
                except Exception:
                    pass


# ----------------------------------------------------------------------------- player


class Player:
    def __init__(self, settings: dict, exit_after_frames: int = 0) -> None:
        self.settings = settings
        self.exit_after_frames = exit_after_frames
        self.link: Link | None = None
        self.audio = AudioOut(settings["audio_latency_ms"])
        self._lock = threading.Lock()
        self._pending = None  # (frame, angle)
        self._event_queued = False
        self._last = None
        self.user_rotation = 0
        self.texture = None
        self.texture_key = None
        self.fullscreen = False
        self.sized_once = False
        self.shown_frames = 0
        self.decode_ms: list[float] = []
        self.quit = False

        sdl2.SDL_SetHint(sdl2.SDL_HINT_RENDER_SCALE_QUALITY, b"1")
        sdl2.SDL_SetHint(b"SDL_WINDOWS_DPI_AWARENESS", b"permonitorv2")
        if sys.platform == "win32":
            sdl2.SDL_SetHint(sdl2.SDL_HINT_RENDER_DRIVER, b"direct3d11")
        if sdl2.SDL_Init(sdl2.SDL_INIT_VIDEO | sdl2.SDL_INIT_AUDIO | sdl2.SDL_INIT_EVENTS) != 0:
            raise RuntimeError(sdl2.SDL_GetError().decode(errors="ignore"))
        self.frame_event = sdl2.SDL_RegisterEvents(1)
        flags = sdl2.SDL_WINDOW_RESIZABLE | sdl2.SDL_WINDOW_ALLOW_HIGHDPI
        if settings.get("always_on_top"):
            flags |= sdl2.SDL_WINDOW_ALWAYS_ON_TOP
        self.window = sdl2.SDL_CreateWindow(
            WINDOW_TITLE.encode(), sdl2.SDL_WINDOWPOS_CENTERED, sdl2.SDL_WINDOWPOS_CENTERED, 960, 540, flags
        )
        self.renderer = sdl2.SDL_CreateRenderer(self.window, -1, sdl2.SDL_RENDERER_ACCELERATED)
        if not self.renderer:
            self.renderer = sdl2.SDL_CreateRenderer(self.window, -1, 0)
        info = sdl2.SDL_RendererInfo()
        sdl2.SDL_GetRendererInfo(self.renderer, ctypes.byref(info))
        log(f"Renderer: {info.name.decode(errors='ignore')}")
        self._clear()

    # called from the network thread
    def submit_frame(self, frame, angle: int, decode_seconds: float) -> None:
        with self._lock:
            self._pending = (frame, angle)
            self.decode_ms.append(decode_seconds * 1000)
            if self._event_queued:
                return
            self._event_queued = True
        event = sdl2.SDL_Event()
        event.type = self.frame_event
        sdl2.SDL_PushEvent(ctypes.byref(event))

    def on_disconnect(self) -> None:
        with self._lock:
            self._pending = None

    def _clear(self) -> None:
        sdl2.SDL_SetRenderDrawColor(self.renderer, 0, 0, 0, 255)
        sdl2.SDL_RenderClear(self.renderer)
        sdl2.SDL_RenderPresent(self.renderer)

    def _upload(self, frame):
        fmt = frame.format.name
        if fmt not in ("yuv420p", "yuvj420p", "nv12"):
            frame = frame.reformat(format="yuv420p")
            fmt = "yuv420p"
        try:
            full_range = fmt == "yuvj420p" or int(frame.color_range) == 2
        except Exception:
            full_range = fmt == "yuvj420p"
        pixfmt = sdl2.SDL_PIXELFORMAT_NV12 if fmt == "nv12" else sdl2.SDL_PIXELFORMAT_IYUV
        key = (frame.width, frame.height, pixfmt, full_range)
        if key != self.texture_key:
            if self.texture:
                sdl2.SDL_DestroyTexture(self.texture)
            sdl2.SDL_SetYUVConversionMode(
                YUV_CONVERSION_JPEG if full_range else YUV_CONVERSION_BT709
            )
            self.texture = sdl2.SDL_CreateTexture(
                self.renderer, pixfmt, sdl2.SDL_TEXTUREACCESS_STREAMING, frame.width, frame.height
            )
            self.texture_key = key
        u8p = ctypes.POINTER(ctypes.c_ubyte)
        planes = [np.frombuffer(p, dtype=np.uint8) for p in frame.planes]
        if pixfmt == sdl2.SDL_PIXELFORMAT_NV12:
            sdl2.SDL_UpdateNVTexture(
                self.texture, None,
                planes[0].ctypes.data_as(u8p), frame.planes[0].line_size,
                planes[1].ctypes.data_as(u8p), frame.planes[1].line_size,
            )
        else:
            sdl2.SDL_UpdateYUVTexture(
                self.texture, None,
                planes[0].ctypes.data_as(u8p), frame.planes[0].line_size,
                planes[1].ctypes.data_as(u8p), frame.planes[1].line_size,
                planes[2].ctypes.data_as(u8p), frame.planes[2].line_size,
            )
        return frame.width, frame.height

    def _content_size(self, w: int, h: int, angle: int) -> tuple[int, int]:
        return (h, w) if angle % 180 == 90 else (w, h)

    def _fit_window_once(self, w: int, h: int, angle: int) -> None:
        if self.sized_once or self.fullscreen:
            return
        self.sized_once = True
        cw, ch = self._content_size(w, h, angle)
        bounds = sdl2.SDL_Rect()
        if sdl2.SDL_GetDisplayUsableBounds(0, ctypes.byref(bounds)) != 0:
            bounds.w, bounds.h = 1600, 900
        scale = min(bounds.w * 0.85 / cw, bounds.h * 0.85 / ch, 1.0)
        sdl2.SDL_SetWindowSize(self.window, max(200, int(cw * scale)), max(200, int(ch * scale)))
        sdl2.SDL_SetWindowPosition(self.window, sdl2.SDL_WINDOWPOS_CENTERED, sdl2.SDL_WINDOWPOS_CENTERED)

    def _draw(self) -> None:
        if self._last is None or not self.texture:
            self._clear()
            return
        w, h, angle = self._last
        angle = (angle + self.user_rotation) % 360
        out_w, out_h = ctypes.c_int(), ctypes.c_int()
        sdl2.SDL_GetRendererOutputSize(self.renderer, ctypes.byref(out_w), ctypes.byref(out_h))
        cw, ch = self._content_size(w, h, angle)
        scale = min(out_w.value / cw, out_h.value / ch)
        dw, dh = int(round(w * scale)), int(round(h * scale))
        dst = sdl2.SDL_Rect((out_w.value - dw) // 2, (out_h.value - dh) // 2, dw, dh)
        sdl2.SDL_SetRenderDrawColor(self.renderer, 0, 0, 0, 255)
        sdl2.SDL_RenderClear(self.renderer)
        sdl2.SDL_RenderCopyEx(self.renderer, self.texture, None, ctypes.byref(dst), float(angle), None, sdl2.SDL_FLIP_NONE)
        sdl2.SDL_RenderPresent(self.renderer)

    def _show_pending(self) -> None:
        with self._lock:
            pending = self._pending
            self._pending = None
            self._event_queued = False
        if pending is None:
            return
        frame, angle = pending
        w, h = self._upload(frame)
        self._last = (w, h, angle)
        self._fit_window_once(w, h, (angle + self.user_rotation) % 360)
        self._draw()
        self.shown_frames += 1
        if self.exit_after_frames and self.shown_frames >= self.exit_after_frames:
            self.quit = True

    def _native_size(self) -> None:
        if self._last is None:
            return
        if self.fullscreen:
            self._toggle_fullscreen()
        w, h, angle = self._last
        cw, ch = self._content_size(w, h, (angle + self.user_rotation) % 360)
        # Convert renderer pixels back to window units for high-DPI screens.
        win_w, win_h, out_w, out_h = ctypes.c_int(), ctypes.c_int(), ctypes.c_int(), ctypes.c_int()
        sdl2.SDL_GetWindowSize(self.window, ctypes.byref(win_w), ctypes.byref(win_h))
        sdl2.SDL_GetRendererOutputSize(self.renderer, ctypes.byref(out_w), ctypes.byref(out_h))
        ratio = (out_w.value / win_w.value) if win_w.value else 1.0
        sdl2.SDL_SetWindowSize(self.window, int(cw / ratio), int(ch / ratio))
        log(f"Ukuran window = ukuran asli video {cw}x{ch}")

    def _toggle_fullscreen(self) -> None:
        self.fullscreen = not self.fullscreen
        sdl2.SDL_SetWindowFullscreen(self.window, sdl2.SDL_WINDOW_FULLSCREEN_DESKTOP if self.fullscreen else 0)

    def _change_bitrate(self, delta: int) -> None:
        value = int(max(2, min(100, float(self.settings["bitrate_mbps"]) + delta)))
        self.settings["bitrate_mbps"] = value
        save_settings(self.settings)
        if self.link:
            self.link.send(device_config(self.settings))
        log(f"Bitrate diganti ke {value} Mbps")

    def _on_key(self, sym: int) -> None:
        if sym in (sdl2.SDLK_F11, sdl2.SDLK_f):
            self._toggle_fullscreen()
        elif sym == sdl2.SDLK_ESCAPE and self.fullscreen:
            self._toggle_fullscreen()
        elif sym == sdl2.SDLK_1:
            self._native_size()
        elif sym == sdl2.SDLK_r:
            self.user_rotation = (self.user_rotation + 90) % 360
            self._draw()
        elif sym == sdl2.SDLK_UP:
            self._change_bitrate(+2)
        elif sym == sdl2.SDLK_DOWN:
            self._change_bitrate(-2)
        elif sym == sdl2.SDLK_k and self.link:
            self.link.request_keyframe()
            log("Keyframe diminta")
        elif sym == sdl2.SDLK_m:
            self.audio.muted = not self.audio.muted
            log("Audio PC " + ("dimute" if self.audio.muted else "nyala"))
        elif sym == sdl2.SDLK_t:
            on = not bool(self.settings.get("always_on_top"))
            self.settings["always_on_top"] = on
            sdl2.SDL_SetWindowAlwaysOnTop(self.window, sdl2.SDL_TRUE if on else sdl2.SDL_FALSE)
            save_settings(self.settings)
            log("Always on top " + ("ON" if on else "OFF"))

    def _print_stats(self, elapsed: float, last_bytes: int, last_frames: int) -> tuple[int, int]:
        link = self.link
        if link is None:
            return last_bytes, last_frames
        rx_bytes, rx_frames = link.rx_bytes, link.rx_frames
        if rx_frames == last_frames:
            return rx_bytes, rx_frames
        with self._lock:
            samples = self.decode_ms[-120:]
            self.decode_ms = []
        dec = sum(samples) / len(samples) if samples else 0.0
        fps = (rx_frames - last_frames) / elapsed
        mbps = (rx_bytes - last_bytes) * 8 / elapsed / 1e6
        ds = link.device_stats
        size = f"{ds.get('w', '?')}x{ds.get('h', '?')}"
        log(
            f"{fps:4.0f} fps | {mbps:5.1f} Mbps | decode {dec:4.1f} ms | "
            f"iPhone: {size} {str(ds.get('codec', '')).upper()} target {ds.get('bitrate', 0) / 1e6:.0f} Mbps, "
            f"drop {ds.get('dropped', 0)}"
        )
        return rx_bytes, rx_frames

    def loop(self) -> None:
        event = sdl2.SDL_Event()
        stat_t = time.monotonic()
        last_bytes = last_frames = 0
        while not self.quit:
            if sdl2.SDL_WaitEventTimeout(ctypes.byref(event), 50):
                if event.type == sdl2.SDL_QUIT:
                    break
                if event.type == self.frame_event:
                    self._show_pending()
                elif event.type == sdl2.SDL_KEYDOWN:
                    self._on_key(event.key.keysym.sym)
                elif event.type == sdl2.SDL_WINDOWEVENT and event.window.event in (
                    sdl2.SDL_WINDOWEVENT_SIZE_CHANGED,
                    sdl2.SDL_WINDOWEVENT_EXPOSED,
                ):
                    self._draw()
            now = time.monotonic()
            if now - stat_t >= 2.0:
                last_bytes, last_frames = self._print_stats(now - stat_t, last_bytes, last_frames)
                stat_t = now
        self.close()

    def close(self) -> None:
        self.audio.close()
        if self.texture:
            sdl2.SDL_DestroyTexture(self.texture)
        sdl2.SDL_DestroyRenderer(self.renderer)
        sdl2.SDL_DestroyWindow(self.window)
        sdl2.SDL_Quit()


def main() -> int:
    parser = argparse.ArgumentParser(description="iPhone Mirror receiver")
    parser.add_argument("--no-launcher", action="store_true", help="skip the settings window")
    parser.add_argument("--direct", help="connect to host:port directly instead of usbmuxd (testing)")
    parser.add_argument("--exit-after-frames", type=int, default=0, help=argparse.SUPPRESS)
    args = parser.parse_args()

    print(f"iPhone Mirror {APP_VERSION}\n")
    settings = load_settings()
    if not args.no_launcher:
        try:
            import launcher

            result = launcher.run(settings)
        except ImportError:
            result = settings
        if result is None:
            return 0
        settings = result
    save_settings(settings)

    player = Player(settings, exit_after_frames=args.exit_after_frames)
    link = Link(player, settings, args.direct)
    player.link = link
    link.start()
    log("Hotkey: F11 fullscreen | 1 ukuran asli | R putar | Atas/Bawah bitrate | K keyframe | M mute | T on top")
    try:
        player.loop()
    finally:
        link.stop_event.set()
    log(f"Selesai. {player.shown_frames} frame ditampilkan.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
