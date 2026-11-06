#!/usr/bin/env python3
"""Spotlight, the Alt+Tab switcher and kept preferences (docs/design/014, M1).

Build: zig build -Ddesktop-profile && scripts/mkdisk.sh

Boots twice on one fresh data disk:
  1. Alt+Space opens Spotlight; "clo" finds Clock (drawn highlighted) and
     Return opens it; a sum is worked out; the menu-bar magnifier opens it
     too; "dark" finds the Midnight Aurora theme, which Return applies and
     saves to /data.
  2. Alt held with Tab twice walks the switcher through the open windows,
     and releasing Alt focuses the one highlighted.
  3. After a reboot the theme is read back from /data.
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
KEYS = {" ": "spc", "*": "shift-8", "+": "shift-equal", "/": "slash", "-": "minus", "(": "shift-9", ")": "shift-0"}
ACCENT = (0x16, 0x89, 0xDB)  # Coastal Glass accent: the highlighted result


def boot(image):
    g = Guest(extra_args=("-drive", f"id=data0,file={image},format=raw,if=none",
                          "-device", "ide-hd,drive=data0,bus=ahci.1"))
    g.until(lambda: '"Welcome"' in g.log() and "squeeze: window" in g.log(), "boot to desktop", 90)
    g.scale = 2 if "framebuffer: 2560x1600" in g.log() else 1
    size = re.search(r"peel: (\d+)x(\d+)", g.log())
    g.width, g.height = int(size.group(1)) // g.scale, int(size.group(2)) // g.scale
    time.sleep(1)
    return g


def typed(g, text):
    for ch in text:
        g.key(KEYS.get(ch, ch))


def spotlight_line(g):
    found = re.findall(r'desktop: spotlight "([^"]*)" (\d+) results(?:, selected "([^"]*)")?', g.log())
    return found[-1] if found else None


def qmp_key(g, key, down):
    g.command("input-send-event", {"events": [{"type": "key", "data": {"down": down, "key": {"type": "qcode", "data": key}}}]})
    time.sleep(.35)


def close_enough(a, b, tolerance=24):
    return all(abs(x - y) <= tolerance for x, y in zip(a, b))


def main():
    work = pathlib.Path(tempfile.mkdtemp(prefix="orange-spotlight-"))
    image = work / "data.img"
    subprocess.run([sys.executable, str(ROOT / "tools/mkdata.py"), str(image), "--size-mib", "64"], check=True)

    g = boot(image)
    try:
        assert "desktop: no saved preferences (first start)" in g.log(), g.log()[-2000:]
        print("PASS a fresh data disk has no saved preferences", flush=True)

        # 1. Alt+Space, type, Return.
        g.key("alt-spc")
        g.until(lambda: "desktop: spotlight open" in g.log(), "Alt+Space opens Spotlight")
        typed(g, "clo")
        g.until(lambda: spotlight_line(g) and spotlight_line(g)[0] == "clo", "the query reaches Spotlight")
        query, count, selected = spotlight_line(g)
        assert selected == "Clock", spotlight_line(g)
        # The highlighted first row is drawn in the accent colour (to the
        # right of its text, left of the "Open" hint).
        top = max(28 + 24, g.height // 5)
        row_y = top + 56 + 9 + 3
        pixel = g.pixel(g.width // 2 + 120, row_y)
        assert close_enough(pixel, ACCENT), f"highlighted row colour {pixel}"
        g.screenshot("01-spotlight-clo")
        print(f"PASS \"clo\" finds {count} results, Clock first and highlighted", flush=True)
        g.key("ret")
        g.until(lambda: "desktop: launched /bin/clock" in g.log(), "Return opens Clock")

        # 2. A sum.
        g.key("alt-spc")
        g.until(lambda: g.log().count("desktop: spotlight open") == 2, "Spotlight opens again")
        typed(g, "(12*7+3)/2")
        g.until(lambda: spotlight_line(g) and spotlight_line(g)[0] == "(12*7+3)/2", "the sum is typed")
        assert spotlight_line(g)[2] == "43.5", spotlight_line(g)
        g.screenshot("02-spotlight-sum")
        print("PASS (12*7+3)/2 = 43.5", flush=True)
        for _ in range(4):
            g.key("backspace")
        g.until(lambda: spotlight_line(g)[0] == "(12*7+", "Backspace removes characters")
        assert spotlight_line(g)[1] == "0", spotlight_line(g)
        print("PASS an unfinished sum finds nothing", flush=True)
        g.key("esc")
        time.sleep(1)

        # 3. The menu-bar magnifier; a theme by keyword; Return applies it.
        g.click(g.width - 300, 14)
        g.until(lambda: g.log().count("desktop: spotlight open") == 3, "the menu-bar magnifier opens Spotlight")
        typed(g, "dark")
        g.until(lambda: spotlight_line(g) and spotlight_line(g)[0] == "dark", "the keyword is typed")
        assert spotlight_line(g)[2] == "Midnight Aurora", spotlight_line(g)
        g.key("ret")
        g.until(lambda: "desktop: theme 2 Midnight Aurora" in g.log(), "Return applies the theme")
        g.until(lambda: "desktop: preferences saved, theme 2" in g.log(), "the theme is saved to /data")
        g.key("esc")
        time.sleep(1)

        # 4. Alt+Tab, Tab, release: the third most recent window.
        order = []
        qmp_key(g, "alt", True)
        qmp_key(g, "tab", True)
        qmp_key(g, "tab", False)
        g.until(lambda: "desktop: switcher 2 of" in g.log(), "Alt+Tab opens the switcher on the previous window")
        g.screenshot("03-switcher")
        qmp_key(g, "tab", True)
        qmp_key(g, "tab", False)
        g.until(lambda: "desktop: switcher 3 of" in g.log(), "Tab moves to the next window")
        order = re.findall(r'desktop: switcher (\d+) of (\d+) "([^"]*)"', g.log())
        qmp_key(g, "alt", False)
        g.until(lambda: "desktop: switched to" in g.log(), "releasing Alt switches")
        switched = re.findall(r'desktop: switched to "([^"]*)"', g.log())[-1]
        assert switched == order[-1][2], (switched, order)
        print(f"PASS the switcher offered {order[-1][1]} windows and switched to \"{switched}\"", flush=True)
        # Wait for /data's periodic save before power-off.
        time.sleep(4)
        g.monitor("stop")
    finally:
        g.close()

    g = boot(image)
    try:
        g.until(lambda: "desktop: preferences loaded, theme 2 Midnight Aurora" in g.log(), "the theme is back after a reboot")
        g.screenshot("04-after-reboot")
    finally:
        g.close()
    print(f"Spotlight checks passed; evidence in {work} and the guest output folders", flush=True)


if __name__ == "__main__":
    main()
