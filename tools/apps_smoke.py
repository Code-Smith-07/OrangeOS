#!/usr/bin/env python3
"""Calculator and Image Viewer (docs/design/014, M4), in a real desktop.

Build: zig build -Ddesktop-profile && scripts/mkdisk.sh

  1. Calculator: sums typed on the keyboard and clicked on its keys give
     the right answers; dividing by zero says so; the keys are drawn (an
     orange operator key, a dark display).
  2. Image Viewer: a PNG with transparency opened from Files is decoded at
     its real size; Right steps to the next picture in the folder; + zooms.
  3. Quick Look shows a picture in Files.
"""
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
from desktop_smoke import Guest, frame_of  # noqa: E402

KEYS = {" ": "spc", "*": "shift-8", "+": "shift-equal", "/": "slash", "-": "minus", "=": "equal", ".": "dot"}


def typed(g, text):
    for ch in text:
        g.key(KEYS.get(ch, ch))


def spotlight(g, text):
    before = g.log().count("desktop: spotlight open")
    g.key("alt-spc")
    g.until(lambda: g.log().count("desktop: spotlight open") > before, "Spotlight opens")
    typed(g, text)
    time.sleep(.8)
    g.key("ret")


def last_calc(g):
    found = re.findall(r"calculator: (.) -> (.+)", g.log())
    return found[-1][1] if found else None


def close_enough(a, b, tolerance=40):
    return all(abs(x - y) <= tolerance for x, y in zip(a, b))


def main():
    g = Guest()
    try:
        g.until(lambda: '"Welcome"' in g.log() and "squeeze: window" in g.log(), "boot to desktop", 90)
        g.scale = 2
        time.sleep(1.5)

        # 1. Calculator.
        spotlight(g, "calc")
        g.until(lambda: "calculator: painted" in g.log(), "Calculator opens", 30)
        wid = int(re.search(r'peel: window (\d+) "Calculator"', g.log())[1])
        time.sleep(1)
        typed(g, "12*3=")
        g.until(lambda: last_calc(g) == "36", "12 x 3 = 36 on the keyboard")
        typed(g, "+0.5=")
        g.until(lambda: last_calc(g) == "36.5", "the result carries into the next sum")
        fx, fy, fw, fh, cx, cy = frame_of(g, wid)

        def key_at(col, row):
            return cx + 12 + col * 57 + 24, cy + 94 + row * 52 + 22

        for col, row in ((0, 0), (0, 1), (3, 3), (1, 1), (3, 4)):  # AC 7 + 8 =
            g.click(*key_at(col, row))
        g.until(lambda: last_calc(g) == "15", "7 + 8 = 15 on the keys")
        for col, row in ((3, 0), (0, 4), (3, 4)):  # / 0 =
            g.click(*key_at(col, row))
        g.until(lambda: last_calc(g) == "Not a number", "dividing by zero is an error")
        g.move(cx + 120, cy + 350)
        time.sleep(.5)
        g.screenshot("01-calculator")
        orange = g.pixel(key_at(3, 1)[0] - 16, key_at(3, 1)[1] + 14)
        assert close_enough(orange, (0xF2, 0x8A, 0x1E)), f"operator key colour {orange}"
        display = g.pixel(cx + 30, cy + 30)
        assert max(display) < 60, f"display colour {display}"
        g.key("esc")
        g.until(lambda: last_calc(g) == "0", "Esc clears")
        print("PASS Calculator: keyboard and key sums, the error, and its drawn keys", flush=True)

        # 2. Image Viewer, opened from Files.
        spotlight(g, "files")
        g.until(lambda: "files: listed /:" in g.log(), "Files opens (no data disk: the computer)", 30)
        time.sleep(1)
        for folder in ("share", "pictures"):
            g.key("ctrl-f")
            typed(g, folder)
            g.key("ret")
            g.key("ret")
        g.until(lambda: "files: listed /share/pictures: 2 entries" in g.log(), "Files reaches the sample pictures")
        g.key("end")
        g.until(lambda: "files: selected orange-os.png" in g.log(), "the PNG is selected")
        g.key("spc")
        g.until(lambda: "files: quick look picture /share/pictures/orange-os.png, 512x512" in g.log(), "Quick Look decodes the PNG")
        time.sleep(1)
        g.screenshot("02-quick-look-picture")
        g.key("spc")
        time.sleep(.5)
        g.key("ret")
        g.until(lambda: "desktop: open /share/pictures/orange-os.png with Image Viewer" in g.log(), "Return opens it with Image Viewer")
        g.until(lambda: "viewer: opened /share/pictures/orange-os.png, 512x512" in g.log(), "Image Viewer decodes the PNG", 40)
        time.sleep(2)
        g.screenshot("03-viewer")
        # The orange is orange: a pixel near the middle of the picture.
        vid = int(re.search(r'peel: window (\d+) "Image Viewer"', g.log())[1])
        vx, vy, vw, vh, vcx, vcy = frame_of(g, vid)
        middle = g.pixel(vcx + 360, vcy + 52 + (520 - 52 - 26) // 2 + 30)
        assert middle[0] > 200 and middle[2] < 120, f"picture colour {middle}"
        g.key("left")
        g.until(lambda: "viewer: opened /share/pictures/app-icons.png, 1480x240" in g.log(), "Left steps to the other picture", 40)
        g.key("shift-equal")
        g.until(lambda: "viewer: zoom" in g.log(), "+ zooms in")
        time.sleep(2)
        g.screenshot("04-viewer-zoomed")
        print("PASS Image Viewer: PNG from Files, next picture, zoom; Quick Look shows pictures", flush=True)
        assert "CPU EXCEPTION" not in g.log() and "[app fault]" not in g.log()
    finally:
        g.close()
    print(f"App checks passed; evidence in {g.output}", flush=True)


if __name__ == "__main__":
    main()
