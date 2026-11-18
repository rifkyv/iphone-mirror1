"""Settings window shown before mirroring starts (Tkinter, ships with Python on Windows)."""

from __future__ import annotations

import tkinter as tk
from tkinter import ttk

RESOLUTIONS = [
    ("Asli (paling tajam, paling berat)", 0),
    ("2560 (sisi panjang)", 2560),
    ("1920 (rekomendasi buat live)", 1920),
    ("1600", 1600),
    ("1280 (paling ringan)", 1280),
]
CODECS = [("H.264 (paling stabil, rekomendasi)", "h264"), ("H.265 / HEVC (lebih hemat bitrate)", "hevc")]


def run(settings: dict) -> dict | None:
    result: dict | None = None
    root = tk.Tk()
    root.title("iPhone Mirror - Pengaturan")
    root.resizable(False, False)
    try:
        root.tk.call("tk", "scaling", 1.3)
    except tk.TclError:
        pass

    frm = ttk.Frame(root, padding=16)
    frm.grid()

    ttk.Label(frm, text="iPhone Mirror", font=("Segoe UI", 16, "bold")).grid(column=0, row=0, columnspan=2, sticky="w")
    ttk.Label(frm, text="Mirroring iPhone lewat kabel USB, bitrate bebas, suara ikut ke PC.").grid(
        column=0, row=1, columnspan=2, sticky="w", pady=(0, 12)
    )

    codec_labels = [c[0] for c in CODECS]
    codec_var = tk.StringVar(value=next((c[0] for c in CODECS if c[1] == settings.get("codec")), codec_labels[0]))
    ttk.Label(frm, text="Codec").grid(column=0, row=2, sticky="w", pady=4)
    ttk.Combobox(frm, textvariable=codec_var, values=codec_labels, state="readonly", width=38).grid(column=1, row=2, pady=4)

    bitrate_var = tk.IntVar(value=int(settings.get("bitrate_mbps", 20)))
    ttk.Label(frm, text="Bitrate (Mbps)").grid(column=0, row=3, sticky="w", pady=4)
    bitrate_row = ttk.Frame(frm)
    bitrate_row.grid(column=1, row=3, sticky="we", pady=4)
    bitrate_label = ttk.Label(bitrate_row, width=4)
    scale = ttk.Scale(
        bitrate_row, from_=2, to=60, orient="horizontal", length=260,
        command=lambda v: (bitrate_var.set(int(float(v))), bitrate_label.config(text=str(bitrate_var.get()))),
    )
    scale.set(bitrate_var.get())
    scale.grid(column=0, row=0)
    bitrate_label.config(text=str(bitrate_var.get()))
    bitrate_label.grid(column=1, row=0, padx=6)

    fps_var = tk.StringVar(value=str(int(settings.get("fps", 60))))
    ttk.Label(frm, text="Frame rate").grid(column=0, row=4, sticky="w", pady=4)
    ttk.Combobox(frm, textvariable=fps_var, values=["60", "30"], state="readonly", width=38).grid(column=1, row=4, pady=4)

    res_labels = [r[0] for r in RESOLUTIONS]
    res_var = tk.StringVar(value=next((r[0] for r in RESOLUTIONS if r[1] == settings.get("max_long_side")), res_labels[2]))
    ttk.Label(frm, text="Resolusi").grid(column=0, row=5, sticky="w", pady=4)
    ttk.Combobox(frm, textvariable=res_var, values=res_labels, state="readonly", width=38).grid(column=1, row=5, pady=4)

    audio_var = tk.BooleanVar(value=bool(settings.get("audio", True)))
    ttk.Checkbutton(frm, text="Suara game iPhone masuk ke PC", variable=audio_var).grid(column=1, row=6, sticky="w", pady=4)

    hw_var = tk.BooleanVar(value=bool(settings.get("hw_decode", True)))
    ttk.Checkbutton(frm, text="Decode pakai GPU (lebih ringan)", variable=hw_var).grid(column=1, row=7, sticky="w", pady=4)

    top_var = tk.BooleanVar(value=bool(settings.get("always_on_top", False)))
    ttk.Checkbutton(frm, text="Window selalu di atas", variable=top_var).grid(column=1, row=8, sticky="w", pady=4)

    ttk.Label(
        frm,
        text="Saran buat live TikTok: H.264, 20 Mbps, 60 fps, 1920.\n"
        "Bitrate bisa diubah pas lagi jalan pakai panah Atas/Bawah.",
        foreground="#555",
    ).grid(column=0, row=9, columnspan=2, sticky="w", pady=(10, 10))

    def start() -> None:
        nonlocal result
        result = dict(settings)
        result["codec"] = next(c[1] for c in CODECS if c[0] == codec_var.get())
        result["bitrate_mbps"] = int(bitrate_var.get())
        result["fps"] = int(fps_var.get())
        result["max_long_side"] = next(r[1] for r in RESOLUTIONS if r[0] == res_var.get())
        result["audio"] = bool(audio_var.get())
        result["hw_decode"] = bool(hw_var.get())
        result["always_on_top"] = bool(top_var.get())
        root.destroy()

    ttk.Button(frm, text="Mulai Mirroring", command=start).grid(column=0, row=10, columnspan=2, sticky="we", ipady=6)
    root.bind("<Return>", lambda _e: start())
    root.mainloop()
    return result
