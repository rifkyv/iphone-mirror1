# iPhone Mirror wire protocol (v1)

Transport: TCP over USB. The broadcast extension on the iPhone listens on
127.0.0.1:7890. The PC reaches it through Apple's usbmuxd (Connect message).

## PC -> iPhone

UTF-8 JSON, one object per line (`\n` terminated).

First line (and any later reconfiguration):

```json
{"cmd": "config", "proto": 1, "codec": "h264", "bitrate": 20000000, "fps": 60,
 "max_long_side": 1920, "keyframe_interval": 2.0, "audio": true}
```

- `codec`: `h264` or `hevc`
- `bitrate`: bits per second (1 000 000 to 100 000 000)
- `fps`: frame rate cap (10 to 60)
- `max_long_side`: scale so the long side of the picture is at most this. 0 = native
- `keyframe_interval`: seconds between keyframes
- `audio`: send app audio

Other commands:

```json
{"cmd": "keyframe"}
```

## iPhone -> PC

Every message: `type: u8`, `length: u32 big endian`, then `length` bytes.

| type | name      | payload |
|------|-----------|---------|
| 1    | HELLO     | JSON `{"proto":1,"app":"1.0.0","screen":[w,h]}` |
| 2    | VIDEO     | `flags u8` (bit0 = keyframe, bit1 = HEVC, else H.264), `orientation u8` (CGImagePropertyOrientation: 1 up, 3 down, 6 right, 8 left), `pts_us u64 BE`, then one access unit in Annex-B. Keyframes carry VPS/SPS/PPS. |
| 3    | AUDIO     | `sample_rate u32 BE`, `channels u8`, `bits u8`, `flags u8` (bit0 float, bit1 big endian), `reserved u8`, then interleaved PCM |
| 4    | STATS     | JSON, once per second: `{"fps":..,"kbps":..,"dropped":..,"w":..,"h":..,"codec":"h264","bitrate":..}` |
