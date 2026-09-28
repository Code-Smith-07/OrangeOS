#!/usr/bin/env python3
"""Orange Browser (WPE WebKit in a Peel window) on the OrangeOS desktop.

Build: zig build -Ddesktop-profile -Dwpe-probes
       ORANGE_WPE_PROBES=1 scripts/mkdisk.sh

Boots the desktop, opens the browser from its dock icon, then drives it the
way a person would, through QEMU's mouse and keyboard: the start page renders; a link
opens another page; Back returns; an HTTPS address typed into the address
field loads from the host fixture (10.0.2.2:38459, whose certificate the
test image trusts for that address only); keys typed into the page reach
its text input, whose script puts them in the title; the wheel scrolls a
long page. Screenshots are kept.
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import runtime_smoke  # noqa: E402  (the HTTPS fixture)
from desktop_smoke import Guest  # noqa: E402

# Logical screen positions of the browser window's parts (its default
# placement on the 1280x800 desktop).
BACK = (28, 100)
ADDRESS = (500, 100)
ABOUT_CARD = (300, 320)
DOCK_BROWSER = (702, 732)


def loads(guest, uri):
    return guest.log().count(f"orange-browser: loaded {uri} ")


def typed(guest, text):
    names = {".": "dot", ":": "shift-semicolon", "/": "slash", "-": "minus", "_": "shift-minus"}
    for ch in text:
        guest.key(names.get(ch, ch))


def average(guest, x, y, w, h):
    data = guest.region(x, y, w, h)
    n = len(data) // 3
    return tuple(sum(data[i::3]) // n for i in range(3))


def main():
    os.environ["ORANGE_WPE_PROBES"] = "1"
    https = runtime_smoke.https_server()
    g = Guest()
    try:
        start = "file:///share/browser/start.html"
        g.until(lambda: '"Welcome"' in g.log() and "squeeze: window" in g.log(), "boot to desktop", 90)
        time.sleep(1)
        g.click(*DOCK_BROWSER)
        g.until(lambda: "desktop: launched /bin/orange-browser" in g.log(), "the dock launches the browser", 30)
        g.until(lambda: loads(g, start) >= 1 or "orange-browser: failed" in g.log(), "the start page loads", 600)
        assert "orange-browser: test certificate allowed for 10.0.2.2" in g.log(), g.log()[-2000:]
        time.sleep(2)
        if g.screenshot("browser-check").read_bytes()[3:7] == b"2560":
            g.scale = 2
        g.screenshot("11-browser-start")
        header = average(g, 60, 150, 300, 40)
        card = average(g, 80, 300, 300, 30)
        assert header[0] > 220 and 100 < header[1] < 200 and header[2] < 90, f"orange header, got {header}"
        assert min(card) > 215, f"light card (white with link text), got {card}"
        print(f"PASS start page pixels: header {header}, card {card}", flush=True)

        g.click(*ABOUT_CARD)
        g.until(lambda: loads(g, "file:///share/browser/about.html") >= 1, "a link opens the about page", 120)
        time.sleep(1)
        g.screenshot("12-browser-about")

        g.click(*BACK)
        g.until(lambda: loads(g, start) >= 2, "Back returns to the start page", 120)

        g.click(*ADDRESS)
        typed(g, "10.0.2.2:38459/page.html")
        g.key("ret")
        page = "https://10.0.2.2:38459/page.html"
        g.until(lambda: loads(g, page) >= 1 or f"orange-browser: failed {page}" in g.log(),
                "an HTTPS address typed into the address field loads", 180)
        assert loads(g, page) >= 1, g.log()[-2000:]
        g.until(lambda: 'orange-browser: title "Fixture over HTTPS"' in g.log(), "the HTTPS page's title", 60)
        time.sleep(2)
        g.screenshot("13-browser-https")
        blue = average(g, 60, 350, 200, 30)
        assert blue[2] > blue[0] + 10, f"light blue page, got {blue}"

        # The page focuses its text field (autofocus); typed keys go to it.
        typed(g, "orange")
        g.until(lambda: 'orange-browser: title "typed:orange"' in g.log(), "keys reach the page's text input", 60)
        g.screenshot("14-browser-typed")

        # The mouse wheel scrolls the page under the cursor.
        g.click(*ADDRESS)
        typed(g, "10.0.2.2:38459/long.html")
        g.key("ret")
        g.until(lambda: loads(g, "https://10.0.2.2:38459/long.html") >= 1, "the long page loads", 120)
        g.move(480, 400)
        for _ in range(4):
            g.monitor("mouse_move 0 0 -1")
            time.sleep(0.3)
        g.until(lambda: 'orange-browser: title "scrolled:down"' in g.log(), "the wheel scrolls the page", 60)
        g.screenshot("15-browser-scrolled")
        print(f"Browser checks passed; screenshots in {g.output}", flush=True)
    finally:
        g.close()
        https.shutdown()


if __name__ == "__main__":
    main()
