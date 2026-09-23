#!/usr/bin/env python3
"""Check real rendered dark chrome for bright one-pixel outlines.

Build OrangeOS and its disk first. All guest writes use a disposable overlay.
Compares straight top edges with the adjacent material, away from corners,
icons and labels. Also checks retained hover damage and light-theme highlights.
"""
import time
from desktop_smoke import Guest


def main():
    g = Guest()
    print(f"Evidence: {g.output}", flush=True)
    def contrast(x, y, width):
        top = g.region(x, y, width, 1)
        below = g.region(x, y + 2, width, 1)
        return sum(a - b for a, b in zip(top, below)) / len(top)
    def dark_edges():
        for name, x, y, width in (
            ("Terminal", 160, 112, 250),
            ("Welcome", 800, 112, 250),
            ("Dock", 370, 701, 500),
        ):
            delta = contrast(x, y, width)
            print(f"{name} top-edge excess brightness: {delta:.2f}", flush=True)
            assert delta < 10, f"{name}: bright artificial top highlight"
    try:
        g.until(lambda: "grove: painted" in g.log() and "squeeze: window" in g.log(), "desktop", 45)
        g.scale = 2
        g.key("f4")
        g.click(1188, 183)
        g.until(lambda: "theme 2 Midnight Aurora" in g.log(), "Midnight Aurora")
        g.key("esc")
        g.move(700, 650)
        time.sleep(1)
        g.screenshot("dark-chrome")
        dark_edges()
        g.click(900, 131)  # Change focus; both active and inactive frames checked.
        g.move(700, 650)
        dark_edges()
        before = g.region(370, 701, 500, 1)
        g.move(590, 730)
        g.move(700, 650)
        g.until(lambda: g.region(370, 701, 500, 1) == before, "dock edge stable after hover")
        g.click(1150, 10)
        time.sleep(.5)
        assert contrast(970, 48, 160) < 10, "calendar reintroduces a bright glass outline"
        g.screenshot("dark-calendar")
        g.key("esc")
        for index, x, name in ((0, 970, "Coastal Glass"), (1, 1080, "Citrus Atelier")):
            g.key("f4")
            g.click(x, 183)
            g.until(lambda: f"theme {index} {name}" in g.log(), name)
            g.key("esc")
            g.move(700, 650)
            time.sleep(.5)
            assert contrast(370, 701, 500) > 10, f"{name}: light-theme dock highlight was removed"
        assert "KERNEL PANIC" not in g.log() and "[app fault]" not in g.log()
        print("PASS dark outlines removed; focus, hover and light themes preserved", flush=True)
    finally:
        g.close()


if __name__ == "__main__":
    main()
