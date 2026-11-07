#!/usr/bin/env python3
"""Windows and toolkit (docs/design/014, M2), driven in a real desktop.

Build: zig build -Ddesktop-profile && scripts/mkdisk.sh
       (add -Dwpe-probes and ORANGE_WPE_PROBES=1 for --browser)

Checks, reading Peel's "peel: frame" lines and the apps' own logs:
  1. Title bars are the measured 28 points, with the red close button
     where macOS puts it (centre 14, 14).
  2. The terminal resizes from its bottom-right corner and its left edge,
     re-lays out its text grid, and stops at its minimum size.
  3. A double click on the title bar zooms to the work area and back.
  4. Dragging the title to the left screen edge offers a tile and tiles
     the window to the left half; dragging it away restores its size.
  5. Files is a toolbar window (content under the window buttons): its
     toolbar background moves the window, a double click there zooms it,
     and its grid reflows to the new size.
  6. Minimise shrinks into the dock and the dock brings it back, both
     with motion; with Reduce Motion on (saved to /data) there is none.
  7. --browser: the browser's tab strip zooms it and WebKit is resized.
"""
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(__file__))
from desktop_smoke import Guest  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[1]
BAR_H, DOCK_H = 28, 64
FRAME = re.compile(r"peel: frame (\d+) (\w+) (-?\d+),(-?\d+) (\d+)x(\d+) content (-?\d+),(-?\d+) (\d+)x(\d+)")


def frames(g, wid, what=None):
    out = []
    for m in FRAME.finditer(g.log()):
        if int(m[1]) == wid and (what is None or m[2] == what):
            out.append(tuple(int(v) for v in m.groups()[2:]))
    return out


def last_frame(g, wid):
    f = frames(g, wid)
    return f[-1] if f else None


def window_id(g, title):
    m = re.search(rf'peel: window (\d+) "{re.escape(title)}"', g.log())
    return int(m[1]) if m else None


def press(g):
    g.monitor("mouse_button 1")
    time.sleep(.15)


def release(g):
    g.monitor("mouse_button 0")
    time.sleep(.4)


def drag(g, x0, y0, x1, y1):
    g.move(x0, y0)
    press(g)
    g.move(x1, y1)
    release(g)


def double_click(g, x, y):
    g.move(x, y)
    for _ in range(2):
        g.monitor("mouse_button 1")
        time.sleep(.04)
        g.monitor("mouse_button 0")
        time.sleep(.06)
    time.sleep(.5)


def close_enough(a, b, tolerance=30):
    return all(abs(x - y) <= tolerance for x, y in zip(a, b))


def work_area(g):
    return (0, BAR_H, g.width, g.height - BAR_H - DOCK_H - 14)


def tile(g, kind):
    x, y, w, h = work_area(g)
    gap = 8
    half = (w - gap * 3) // 2
    return {"fill": (x + gap, y + gap, w - gap * 2, h - gap * 2),
            "left": (x + gap, y + gap, half, h - gap * 2)}[kind]


def boot(image, browser):
    g = Guest(extra_args=("-drive", f"id=data0,file={image},format=raw,if=none",
                          "-device", "ide-hd,drive=data0,bus=ahci.1"))
    g.until(lambda: '"Welcome"' in g.log() and "squeeze: window" in g.log(), "boot to desktop", 90)
    g.scale = 2 if "framebuffer: 2560x1600" in g.log() else 1
    size = re.search(r"peel: (\d+)x(\d+)", g.log())
    g.width, g.height = int(size.group(1)) // g.scale, int(size.group(2)) // g.scale
    time.sleep(1.5)
    return g


def main():
    browser = "--browser" in sys.argv
    work = pathlib.Path(tempfile.mkdtemp(prefix="orange-windows-"))
    image = work / "data.img"
    subprocess.run([sys.executable, str(ROOT / "tools/mkdata.py"), str(image), "--size-mib", "64"], check=True)
    g = boot(image, browser)
    try:
        # 1. The measured title bar and window buttons.
        welcome = window_id(g, "Welcome")
        fx, fy, fw, fh, cx, cy, cw, ch = last_frame(g, welcome)
        assert cy - fy == 28, f"title bar is {cy - fy} points"
        g.click(fx + fw // 2, fy + 14)  # focus Welcome (a click on its title)
        red = g.pixel(fx + 14, fy + 14)
        assert close_enough(red, (0xFF, 0x5F, 0x57)), f"close button colour {red}"
        print(f"PASS title bars are 28 points; the close button sits at 14,14 {red}", flush=True)

        # 2. Resize the terminal from its corner, then its left edge.
        term = window_id(g, "Squeeze - juice")
        fx, fy, fw, fh, *_ = last_frame(g, term)
        assert frames(g, term, "opened")[0] and "resizable" in g.log()
        drag(g, fx + fw + 1, fy + fh + 1, fx + fw + 161, fy + fh + 81)
        g.until(lambda: frames(g, term, "resized"), "the corner drag resizes the terminal")
        r = frames(g, term, "resized")[-1]
        assert r[:4] == (fx, fy, fw + 160, fh + 80), (r, (fx, fy, fw, fh))
        cols, rows = min(160, (r[6] - 12) // 8), min(60, (r[7] - 12) // 14)
        g.until(lambda: f"squeeze: {cols} x {rows} cells" in g.log(), "the terminal re-lays out its grid")
        g.screenshot("01-terminal-resized")
        print(f"PASS the corner drag resized the terminal to {r[2]}x{r[3]} and its grid followed", flush=True)
        fx, fy, fw, fh = r[:4]
        before = len(frames(g, term, "resized"))
        drag(g, fx - 2, fy + fh // 2, fx + 700, fy + fh // 2)
        g.until(lambda: len(frames(g, term, "resized")) > before, "the left edge resizes")
        r = frames(g, term, "resized")[-1]
        minimum = 40 * 8 + 12 + 2
        assert r[2] == minimum and r[0] + r[2] == fx + fw, (r, minimum)
        print(f"PASS the left edge stops at the minimum width {minimum} with the right edge fixed", flush=True)

        # 3. Double-click the title: zoom to the work area, and back.
        fx, fy, fw, fh = r[:4]
        before = len(frames(g, term, "resized"))
        double_click(g, fx + fw // 2, fy + 14)
        g.until(lambda: f"desktop: tiled window {term} fill" in g.log(), "a double click zooms")
        g.until(lambda: len(frames(g, term, "resized")) > before, "the zoomed size is drawn")
        assert frames(g, term, "resized")[-1][:4] == tile(g, "fill"), (frames(g, term, "resized")[-1], tile(g, "fill"))
        g.screenshot("02-terminal-zoomed")
        before = len(frames(g, term, "resized"))
        zx, zy, zw, zh = tile(g, "fill")
        double_click(g, zx + zw // 2, zy + 14)
        g.until(lambda: f"desktop: untiled window {term}" in g.log(), "a second double click restores")
        g.until(lambda: len(frames(g, term, "resized")) > before, "the restored size is drawn")
        assert frames(g, term, "resized")[-1][:4] == (fx, fy, fw, fh), frames(g, term, "resized")[-1]
        print("PASS a double click on the title zooms to the work area and back", flush=True)

        # 4. Drag to the left edge: a tile is offered, then taken.
        g.move(fx + fw // 2, fy + 14)
        press(g)
        g.move(0, 300)
        g.until(lambda: "desktop: tile preview left" in g.log(), "the left edge offers a tile")
        g.screenshot("03-tile-preview")
        before = len(frames(g, term, "resized"))
        release(g)
        g.until(lambda: f"desktop: tiled window {term} left" in g.log(), "releasing tiles the window")
        g.until(lambda: len(frames(g, term, "resized")) > before, "the half-screen size is drawn")
        assert frames(g, term, "resized")[-1][:4] == tile(g, "left"), frames(g, term, "resized")[-1]
        print(f"PASS dragging to the left edge tiles the terminal to {tile(g, 'left')}", flush=True)
        lx, ly, lw, lh = tile(g, "left")
        before = len(frames(g, term, "resized"))
        drag(g, lx + 100, ly + 14, lx + 400, ly + 120)
        g.until(lambda: len(frames(g, term, "resized")) > before, "pulling a tiled window away restores its size")
        restored = frames(g, term, "resized")[-1]
        assert restored[2:4] == (fw, fh), (restored, fw, fh)
        print("PASS pulling the tiled window away gives it back its own size", flush=True)

        # 5. Files: a toolbar window that moves, zooms and reflows.
        g.key("alt-spc")
        g.until(lambda: "desktop: spotlight open" in g.log(), "Spotlight opens")
        for ch in "files":
            g.key(ch)
        time.sleep(.8)
        g.key("ret")
        g.until(lambda: window_id(g, "Files") and "files: painted" in g.log(), "Files opens", 30)
        files = window_id(g, "Files")
        time.sleep(1)
        fx, fy, fw, fh, cx, cy, cw, ch = frames(g, files, "opened")[0]
        assert cy == fy, "Files draws under the window buttons"
        red = g.pixel(fx + 26, fy + 26)
        assert close_enough(red, (0xFF, 0x5F, 0x57)), f"toolbar close button {red}"
        g.screenshot("04-files")
        print("PASS Files is a toolbar window with its close button at 26,26", flush=True)
        drag(g, fx + 380, fy + 26, fx + 480, fy + 76)
        g.until(lambda: frames(g, files, "moved"), "the toolbar background moves Files")
        moved = frames(g, files, "moved")[-1]
        assert moved[:2] == (fx + 100, fy + 50), (moved, fx, fy)
        print("PASS dragging Files' toolbar background moves the window", flush=True)
        double_click(g, moved[0] + 380, moved[1] + 26)
        g.until(lambda: f"desktop: tiled window {files} fill" in g.log(), "a double click on the toolbar zooms Files")
        zx, zy, zw, zh = tile(g, "fill")
        g.until(lambda: f"files: resized to {zw - 2}x{zh - 1}" in g.log(), "Files lays itself out at the zoomed size")
        per_page = re.findall(r"files: resized to \d+x\d+, (\d+) per page", g.log())[-1]
        assert int(per_page) > 8, per_page
        g.screenshot("05-files-zoomed")
        print(f"PASS Files zoomed to {zw - 2}x{zh - 1} and shows {per_page} items per page (8 before)", flush=True)

        # 6. Minimise into the dock and back, with motion.
        done = g.log().count(f"desktop: motion done {files}")
        g.click(zx + 19 + 20 + 7, zy + 26)
        g.until(lambda: f"desktop: minimized window {files}" in g.log(), "the yellow button minimises")
        g.until(lambda: g.log().count(f"desktop: motion done {files}") > done, "minimising moves into the dock")
        dock_x = (g.width - 740) // 2 + 16 + 0 * 76 + 36
        dock_y = g.height - DOCK_H - 14 + 8 + 27
        g.click(dock_x, dock_y)
        g.until(lambda: g.log().count(f"desktop: motion done {files}") > done + 1, "the dock brings Files back with motion")
        print("PASS minimise and restore move between the window and its dock tile", flush=True)

        # Reduce Motion: on, saved, and then nothing moves.
        g.key("f4")
        time.sleep(1)
        g.click(g.width - 376 + 360 - 20 - 21, 48 + 320 + 12)
        g.until(lambda: "desktop: reduce motion on" in g.log(), "the switch turns Reduce Motion on")
        g.until(lambda: "preferences saved, theme 0, reduce motion 1" in g.log(), "Reduce Motion is saved")
        g.screenshot("06-reduce-motion")
        g.key("esc")
        time.sleep(1)
        done = g.log().count(f"desktop: motion done {files}")
        g.click(zx + 19 + 20 + 7, zy + 26)
        g.until(lambda: g.log().count(f"desktop: minimized window {files}") == 2, "minimise again")
        time.sleep(1.5)
        assert g.log().count(f"desktop: motion done {files}") == done, "Reduce Motion still animated"
        print("PASS with Reduce Motion on, minimising is instant (and the choice is saved)", flush=True)

        # 7. The browser follows its window size (images with WPE only).
        if browser:
            g.click((g.width - 740) // 2 + 16 + 5 * 76 + 36, dock_y)
            g.until(lambda: "orange-browser: tabs 1" in g.log(), "the browser opens", 180)
            wid = window_id(g, "Orange Browser")
            time.sleep(3)
            bx, by, bw, bh, *_ = frames(g, wid, "opened")[0]
            double_click(g, bx + bw - 60, by + 18)
            g.until(lambda: f"orange-browser: resized to {zw - 2}x{zh - 1}" in g.log(), "the tab strip zooms the browser", 30)
            time.sleep(5)
            g.screenshot("07-browser-zoomed")
            print("PASS the browser's tab strip zooms it and WebKit lays out at the new size", flush=True)
        g.monitor("stop")
    finally:
        g.close()
    print(f"Window checks passed; evidence in {g.output}", flush=True)


if __name__ == "__main__":
    main()
