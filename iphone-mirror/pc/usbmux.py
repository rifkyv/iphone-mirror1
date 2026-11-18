"""Minimal usbmuxd client: list USB-attached iPhones and open a TCP tunnel to a device port.

On Windows usbmuxd is the "Apple Mobile Device Service" installed with iTunes or the
Apple Devices app, listening on 127.0.0.1:27015. On macOS/Linux it is the unix socket
/var/run/usbmuxd. The USBMUXD_SOCKET_ADDRESS environment variable overrides both
("127.0.0.1:27015" or "UNIX:/path/to/socket").
"""

from __future__ import annotations

import os
import plistlib
import socket
import struct
import sys

_HEADER = struct.Struct("<IIII")  # length, version, message type, tag
_PLIST_VERSION = 1
_PLIST_MESSAGE = 8


class UsbmuxError(Exception):
    pass


def _open_socket() -> socket.socket:
    addr = os.environ.get("USBMUXD_SOCKET_ADDRESS", "").strip()
    if addr.upper().startswith("UNIX:"):
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(addr[5:])
        return sock
    if addr:
        host, _, port = addr.rpartition(":")
        return socket.create_connection((host or "127.0.0.1", int(port)), timeout=5)
    if sys.platform == "win32":
        try:
            return socket.create_connection(("127.0.0.1", 27015), timeout=5)
        except OSError as error:
            raise UsbmuxError(
                "Apple Mobile Device Service tidak ditemukan. Install aplikasi 'Apple Devices' "
                "dari Microsoft Store (atau iTunes), lalu coba lagi."
            ) from error
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect("/var/run/usbmuxd")
    return sock


def _recv_exact(sock: socket.socket, n: int) -> bytes:
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise UsbmuxError("usbmuxd closed the connection")
        buf += chunk
    return bytes(buf)


def _request(sock: socket.socket, payload: dict, tag: int = 1) -> dict:
    payload = {"ClientVersionString": "iphone-mirror", "ProgName": "iphone-mirror", **payload}
    body = plistlib.dumps(payload)
    sock.sendall(_HEADER.pack(_HEADER.size + len(body), _PLIST_VERSION, _PLIST_MESSAGE, tag) + body)
    length, _version, _mtype, _tag = _HEADER.unpack(_recv_exact(sock, _HEADER.size))
    return plistlib.loads(_recv_exact(sock, length - _HEADER.size))


def list_devices() -> list[dict]:
    """Return USB-attached devices as dicts with DeviceID and SerialNumber."""
    sock = _open_socket()
    try:
        sock.settimeout(5)
        reply = _request(sock, {"MessageType": "ListDevices"})
    finally:
        sock.close()
    devices = []
    for entry in reply.get("DeviceList", []):
        props = entry.get("Properties", {})
        if props.get("ConnectionType", "USB") != "USB":
            continue
        devices.append(
            {
                "DeviceID": props.get("DeviceID", entry.get("DeviceID")),
                "SerialNumber": props.get("SerialNumber", ""),
            }
        )
    return devices


def connect(device_id: int, port: int, timeout: float = 5.0) -> socket.socket:
    """Open a TCP tunnel to `port` on the device. Raises UsbmuxError if nothing listens there."""
    sock = _open_socket()
    try:
        sock.settimeout(timeout)
        reply = _request(
            sock,
            {
                "MessageType": "Connect",
                "DeviceID": int(device_id),
                "PortNumber": socket.htons(port),
            },
        )
        if reply.get("MessageType") != "Result" or reply.get("Number", -1) != 0:
            raise UsbmuxError(f"port {port} di iPhone belum terbuka (result {reply.get('Number')})")
        sock.settimeout(None)
        return sock
    except Exception:
        sock.close()
        raise
