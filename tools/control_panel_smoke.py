#!/usr/bin/env python3
"""Real guest transient-panel presentation; no host connection or mutations."""
import time
from desktop_smoke import Guest


def main():
    g = Guest()
    print(f"Evidence: {g.output}", flush=True)
    try:
        g.until(lambda: "grove: painted" in g.log() and "squeeze: window" in g.log(), "desktop ready", 45)
        g.scale = 2
        g.move(700, 650)
        backdrop = g.region(900, 32, 380, 450)
        menu = g.region(150, 0, 220, 28)
        g.key("f3")
        g.move(700, 650)
        overview = g.region(80, 100, 1120, 540)
        g.key("esc")

        def open_panel():
            offset = len(g.log())
            g.click(1015, 16)
            g.until(lambda: "desktop: control panel opened" in g.log()[offset:], "menu opens anchored panel")
            g.move(700, 650)
            time.sleep(.5)

        def dismissed(action):
            offset = len(g.log())
            action()
            g.until(lambda: "control panel dismissed" in g.log()[offset:], "transient dismissal")
            g.move(700, 650)
            g.until(lambda: g.region(900, 32, 380, 450) == backdrop, "dismissal restores underlying desktop")

        open_panel()
        baseline = g.region(908, 36, 360, 424)
        assert baseline != g.region(20, 36, 360, 424)
        assert g.region(150, 0, 220, 28) == menu, "panel stole active app menu identity"
        g.screenshot("panel-coastal")
        # Former title/button area is now client content, never draggable.
        g.move(920, 45)
        g.monitor("mouse_button 1")
        g.move(940, 65)
        g.monitor("mouse_button 0")
        g.click(925, 388)
        g.move(700, 650)
        assert g.region(908, 36, 360, 424) == baseline, "blank interactions repainted or moved the panel"
        dismissed(lambda: g.key("esc"))
        g.key("f3")
        g.move(700, 650)
        assert g.region(80, 100, 1120, 540) == overview, "hidden panel leaked into window overview"
        g.key("esc")
        open_panel()
        dismissed(lambda: g.click(1015, 16))
        open_panel()
        # Outside click is consumed: Welcome's red close must not fire.
        dismissed(lambda: g.click(776, 131))
        assert 'closed window 2 "Welcome"' not in g.log()
        for index, x, name in ((1, 1080, "atelier"), (2, 1188, "aurora")):
            g.key("f4")
            g.click(x, 183)
            g.key("esc")
            open_panel()
            current = g.region(908, 36, 360, 424)
            assert current != baseline, "panel failed to follow theme"
            g.screenshot(f"panel-{name}")
            g.key("esc")
        assert g.log().count('"Control Center"') == 1, "reopening spawned duplicate panels"
        assert "[app fault]" not in g.log() and "KERNEL PANIC" not in g.log()
        print("PASS anchor, no title/drag, no-op pixels, Escape, outside/toggle dismissal, singleton and three themes", flush=True)
    finally:
        g.close()


if __name__ == "__main__":
    main()
