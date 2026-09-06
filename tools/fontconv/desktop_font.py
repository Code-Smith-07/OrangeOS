#!/usr/bin/env python3
"""Bake Inter into a compact coverage atlas. Run only when changing the font.

Requires Pillow; the OS and ordinary builds do not. Source and license live
in assets/fonts. The generated atlas remains under SIL OFL 1.1.
"""
import pathlib
import struct
from PIL import Image, ImageDraw, ImageFont

ROOT = pathlib.Path(__file__).resolve().parents[2]
DEST = ROOT / "userland/libs/typography/inter-atlas.bin"
SIZES = (13, 26, 39, 52, 65, 78, 91, 104)


def bake(source, sizes, axes, dest):
    metadata = bytearray()
    pixels = bytearray()
    header_size = len(sizes) * 95 * 12
    for size in sizes:
        font = ImageFont.truetype(str(ROOT / "assets/fonts" / source), size)
        font.set_variation_by_axes(axes)
        for code in range(32, 127):
            char = chr(code)
            left, top, right, bottom = font.getbbox(char, anchor="ls")
            width, height = right - left, bottom - top
            tile = Image.new("L", (max(1, width), max(1, height)))
            ImageDraw.Draw(tile).text((-left, -top), char, font=font, anchor="ls", fill=255)
            advance = round(font.getlength(char))
            metadata.extend(struct.pack("<IBBbbB3x", header_size + len(pixels), width, height, left, top + round(size * .8), advance))
            if width and height:
                pixels.extend(tile.tobytes())
    dest.write_bytes(metadata + pixels)
    print(f"Generated {dest.relative_to(ROOT)} ({dest.stat().st_size} bytes)")


def main():
    bake("Inter.ttf", SIZES, [14, 500], DEST)
    bake("JetBrainsMono.ttf", (13,26), [450], DEST.with_name("mono-atlas.bin"))


if __name__ == "__main__":
    main()
