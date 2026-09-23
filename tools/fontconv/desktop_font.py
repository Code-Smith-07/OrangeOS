#!/usr/bin/env python3
"""Bake Inter into a compact coverage atlas. Run only when changing the font.

Requires Pillow; the OS and ordinary builds do not. Source and license live
in assets/fonts. The generated atlas remains under SIL OFL 1.1.
"""
import pathlib
import struct
import sys
import json
import subprocess
from PIL import Image, ImageDraw, ImageFont

ROOT = pathlib.Path(__file__).resolve().parents[2]
DEST = ROOT / "userland/libs/typography/inter-atlas.bin"
SIZES = (13, 26, 39, 52, 65, 78, 91, 104)


def bake(source, sizes, axes, dest, metric_axes=None):
    metadata = bytearray()
    pixels = bytearray()
    header_size = len(sizes) * 95 * 12
    for size in sizes:
        font = ImageFont.truetype(str(ROOT / "assets/fonts" / source), size)
        font.set_variation_by_axes(axes)
        # Retain the established advance-width contract while refining coverage.
        # Retina body and 1x headings share atlas entries, so selecting weights
        # by physical atlas size would produce inconsistent text across displays.
        metrics = font
        if metric_axes is not None:
            metrics = ImageFont.truetype(str(ROOT / "assets/fonts" / source), size)
            metrics.set_variation_by_axes(metric_axes)
        for code in range(32, 127):
            char = chr(code)
            left, top, right, bottom = font.getbbox(char, anchor="ls")
            width, height = right - left, bottom - top
            tile = Image.new("L", (max(1, width), max(1, height)))
            ImageDraw.Draw(tile).text((-left, -top), char, font=font, anchor="ls", fill=255)
            advance = round(metrics.getlength(char))
            metadata.extend(struct.pack("<IBBbbB3x", header_size + len(pixels), width, height, left, top + round(size * .8), advance))
            if width and height:
                pixels.extend(tile.tobytes())
    dest.write_bytes(metadata + pixels)
    print(f"Generated {dest.relative_to(ROOT)} ({dest.stat().st_size} bytes)")


def main():
    if "--menu-only" in sys.argv:
        bake_menu()
        return
    bake("Inter.ttf", SIZES, [14, 450], DEST, metric_axes=[14, 500])
    bake("JetBrainsMono.ttf", (13,26), [450], DEST.with_name("mono-atlas.bin"))
    bake_menu()


def bake_menu():
    # Dedicated optical size/weight; native backing-pixel advances and kerning
    # prevent the menu's spacing being quantized to doubled 1x metrics.
    bake("Inter.ttf", (13, 26), [14, 500], DEST.with_name("menu-atlas.bin"))
    kerning = bytearray()
    pairs = "\n".join(chr(a) + chr(b) for a in range(32, 127) for b in range(32, 127)) + "\n"
    for size in (13, 26):
        # Pillow builds without libraqm silently omit GPOS pair kerning. Use
        # the installed HarfBuzz CLI at bake time; guest builds stay offline.
        widths = []
        for enabled in (False, True):
            result = subprocess.run([
                "hb-shape", str(ROOT / "assets/fonts/Inter.ttf"),
                f"--font-size={size * 64}", "--variations=opsz=14,wght=500",
                "--direction=ltr", "--script=Latn", "--language=en",
                f"--features=kern={int(enabled)},liga=0,clig=0,calt=0",
                "--output-format=json"], input=pairs, text=True, capture_output=True, check=True)
            rows = result.stdout.splitlines()
            assert len(rows) == 95 * 95
            widths.append([sum(g["ax"] for g in json.loads(row)) for row in rows])
        for plain, kerned in zip(*widths):
            kerning.extend(struct.pack("b", round((kerned - plain) / 64)))
    assert any(kerning), "Menu kerning must not silently degrade to all zeros"
    DEST.with_name("menu-kerning.bin").write_bytes(kerning)


if __name__ == "__main__":
    main()
