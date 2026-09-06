#!/usr/bin/env python3
"""Bake original SVG artwork to RGBA sprites; normal OS builds are offline.

Regenerate: PYTHONPATH=build/svg-tools DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/lib
python3 tools/iconconv/desktop_icons.py
Requires CairoSVG 2.8.2 + Pillow. No SVG parser or font/network dependency in guest.
"""
import io
import pathlib
import struct
import cairosvg
from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parents[2]
NAMES = ("welcome", "terminal", "clock", "about", "windows", "appearance",
         "files", "trash", "chevron_left", "chevron_right", "chevron_up",
         "document", "brand", "controls", "close", "minimize", "maximize", "pointer")

def main():
    header = bytearray()
    data = bytearray()
    sheet = Image.new("RGBA", (8 * 192, 192), "#e5e4f1")
    for i, name in enumerate(NAMES):
        size = 192 if i < 8 else 48
        svg = ROOT / "assets/icons" / (name + ".svg")
        png = cairosvg.svg2png(url=str(svg), output_width=size * 2, output_height=size * 2)
        rgba = Image.open(io.BytesIO(png)).convert("RGBA").resize((size, size), Image.Resampling.LANCZOS)
        if i < 8:
            sheet.alpha_composite(rgba, (i * 192, 0))
        header.extend(struct.pack("<HHI", size, size, len(NAMES) * 8 + len(data)))
        # Premultiplied colour avoids dark fringes when scaling transparent edges.
        # Full RGBA preserves smooth gradients; palette quantization visibly
        # banded the translucent icon highlights in the actual guest preview.
        for r, g, b, a in rgba.getdata():
            data.extend(bytes((r * a // 255, g * a // 255, b * a // 255, a)))
    dest = ROOT / "userland/libs/desktop-ui/icons.bin"
    dest.write_bytes(header + data)
    sheet.save(ROOT / "build/icon-contact-sheet.png")
    print(f"Generated {len(NAMES)} SVG sprites: {dest.stat().st_size} bytes")

if __name__ == "__main__":
    main()
