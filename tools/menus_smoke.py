#!/usr/bin/env python3
"""App menus in the menu bar and the notification list (docs/design/014,
M6 and M7), in a real desktop.

Build: zig build -Ddesktop-profile && scripts/mkdisk.sh

  1. The menu bar shows the front app's name and its own menus, then
     Peel's Window menu; it changes when another app comes to the front.
  2. Choosing an app's item sends it to the app (Files: View > as List).
  3. The Window menu acts on the front window (Tile Left, Minimise).
  4. A program with no window posts a notification from the terminal: a
     banner appears and leaves by itself; the bell opens the list; Clear
     empties it.
"""
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
from desktop_smoke import Guest  # noqa: E402

BAR_H = 28
ITEM_H, GAP_H = 24, 9


def menu_bar(g):
    """The latest menu bar: app name, and {title: centre x}."""
    line = re.findall(r"desktop: menu bar ([^:]+):((?: [A-Za-z]+@\d+\+\d+)*)", g.log())[-1]
    titles = {m[0]: int(m[1]) + int(m[2]) // 2 for m in re.findall(r"([A-Za-z]+)@(\d+)\+(\d+)", line[1])}
    return line[0], titles


def open_menu(g, title):
    name, titles = menu_bar(g)
    before = g.log().count(f"desktop: menu {title} open")
    g.click(titles[title], 14)
    g.until(lambda: g.log().count(f"desktop: menu {title} open") > before, f"the {title} menu opens")
    x, y, w, h = (int(v) for v in re.findall(rf"desktop: menu {title} open at (\d+),(\d+) (\d+)x(\d+)", g.log())[-1])
    return x, y, w, h


def choose(g, title, rows):
    """Open `title` and click the item after `rows` (a list like "IIS":
    items and separators above it)."""
    x, y, w, h = open_menu(g, title)
    offset = sum(ITEM_H if r == "I" else GAP_H for r in rows)
    time.sleep(.4)
    g.click(x + w // 2, y + 6 + offset + ITEM_H // 2)


def main():
    g = Guest()
    try:
        g.until(lambda: '"Welcome"' in g.log() and "squeeze: window" in g.log(), "boot to desktop", 90)
        g.scale = 2
        time.sleep(1.5)

        # 1. The front app's menus.
        name, titles = menu_bar(g)
        assert "Window" in titles, titles
        g.key("alt-spc")
        g.until(lambda: "desktop: spotlight open" in g.log(), "Spotlight opens")
        for ch in "files":
            g.key(ch)
        time.sleep(.8)
        g.key("ret")
        g.until(lambda: "files: listed /:" in g.log(), "Files opens", 30)
        g.until(lambda: menu_bar(g)[0] == "Files", "the menu bar shows Files")
        name, titles = menu_bar(g)
        assert list(titles) == ["File", "View", "Go", "Window"], titles
        files = int(re.search(r'peel: window (\d+) "Files"', g.log())[1])
        time.sleep(1)
        print(f"PASS the menu bar shows Files' own menus, then Window: {list(titles)}", flush=True)

        # 2. An app's item reaches the app.
        open_menu(g, "View")
        time.sleep(.4)
        g.screenshot("01-view-menu")
        g.key("esc")
        time.sleep(.5)
        choose(g, "View", "I")  # as Icons, then as List
        g.until(lambda: "desktop: menu View > as List" in g.log(), "View > as List is chosen")
        g.until(lambda: "files: view list" in g.log(), "Files switches to its list")
        time.sleep(.5)
        g.screenshot("02-files-list")
        choose(g, "Go", "IISII")  # Back, Enclosing, -, Documents, Orange OS, [Applications]
        g.until(lambda: "files: listed /bin:" in g.log(), "Go > Applications opens /bin")
        print("PASS menu items act in the app: View > as List, Go > Applications", flush=True)

        # 3. The Window menu acts on the front window.
        choose(g, "Window", "IIS")  # Minimise, Zoom, -, [Tile Left]
        g.until(lambda: f"desktop: tiled window {files} left" in g.log(), "Window > Tile Left tiles Files")
        g.until(lambda: re.search(rf"peel: frame {files} resized 8,36 ", g.log()), "Files is drawn in the left half")
        time.sleep(.5)
        g.screenshot("03-tiled-by-menu")
        choose(g, "Window", "")  # [Minimise]
        g.until(lambda: f"desktop: minimized window {files}" in g.log(), "Window > Minimise minimises Files")
        g.until(lambda: menu_bar(g)[0] != "Files", "another app's menus take over")
        print(f"PASS the Window menu tiles and minimises; the bar now shows {menu_bar(g)[0]}", flush=True)

        # 4. A notification from the terminal.
        g.until(lambda: menu_bar(g)[0] == "Terminal", "the terminal is in front")
        banner = g.region(g_width(g) - 376, BAR_H + 10, 360, 64)
        for ch in "notify":
            g.key(ch)
        g.key("ret")
        g.until(lambda: 'desktop: notification "Hello from the terminal"' in g.log(), "the notification arrives")
        g.until(lambda: g.region(g_width(g) - 376, BAR_H + 10, 360, 64) != banner, "a banner is shown")
        g.screenshot("04-banner")
        g.until(lambda: g.region(g_width(g) - 376, BAR_H + 10, 360, 64) == banner, "the banner leaves by itself", 12)
        g.click(g_width(g) - 246 + 14, 14)
        g.until(lambda: "desktop: notifications open, 1 kept" in g.log(), "the bell opens the list")
        time.sleep(.6)
        g.screenshot("05-notification-list")
        g.click(g_width(g) - 376 + 360 - 18 - 32, BAR_H + 8 + 16 + 13)
        g.until(lambda: "desktop: notifications cleared" in g.log(), "Clear empties the list")
        g.key("esc")
        print("PASS a notification from the terminal: banner, list, Clear", flush=True)
        assert "CPU EXCEPTION" not in g.log() and "[app fault]" not in g.log()
    finally:
        g.close()
    print(f"Menu and notification checks passed; evidence in {g.output}", flush=True)


def g_width(g):
    size = re.search(r"peel: (\d+)x(\d+)", g.log())
    return int(size.group(1)) // g.scale


if __name__ == "__main__":
    main()
