#!/usr/bin/env python3
"""Eight-window overview probe on a disposable guest; -Ddesktop-profile.

Reports guest frame work, not host display latency. Also verifies switching,
live Clock thumbnails, hover restoration and close/reopen cache invalidation.
"""
import json
import re
import statistics
import time
from desktop_smoke import Guest


def main():
    g = Guest()
    print(f"Evidence: {g.output}", flush=True)
    try:
        g.until(lambda: '"Welcome"' in g.log() and "squeeze: window" in g.log(), "desktop", 45)
        g.scale = 2
        for x in (360, 588, 664, 916):
            g.click(x, 732)
        g.until(lambda: len(re.findall(r'peel: window \d+ "', g.log())) == 6, "six desktop apps", 20)
        for count in (7, 8):
            g.click(24, 20)
            g.click(100, 148)
            g.until(lambda: len(re.findall(r'peel: window \d+ "', g.log())) == count, f"{count} windows", 20)
        g.click(752, 732)
        time.sleep(1)
        g.screenshot("eight-window-overview")
        # Clock was the fourth-created window: right-hand card, second row.
        before_clock = g.region(657, 277, 72, 37)
        g.until(lambda: g.region(657, 277, 72, 37) != before_clock, "live Clock thumbnail", 5)
        g.move(440, 210)
        time.sleep(.4)
        offset = len(g.log())
        for x, y in [(750,210), (440,286), (750,362), (440,438)] * 3:
            # One QMP motion per target; QEMU splits PS/2 packets as needed.
            g.monitor(f"mouse_move {x-g.x} {y-g.y}")
            g.x, g.y = x, y
            time.sleep(.08)
        time.sleep(1)
        values = [(int(a), int(b)) for a, b in re.findall(r"perf: frame (\d+)ms area (\d+)", g.log()[offset:])]
        assert values, "Build with -Ddesktop-profile"
        ms = sorted(a for a,b in values)
        result = dict(samples=len(ms), median_ms=statistics.median(ms), p95_ms=ms[min(len(ms)-1, int(len(ms)*.95))], max_area=max(b for a,b in values))
        print("overview hover", result, flush=True)
        (g.output / "overview-performance.json").write_text(json.dumps(result, indent=2)+"\n")
        g.move(1050, 560)
        time.sleep(1)
        # Static Welcome thumbnail/card must survive repeated hover changes.
        stable = g.region(335,186,298,64)
        g.move(440,210)
        g.move(1050,560)
        time.sleep(1)
        assert stable == g.region(335,186,298,64), "hover leaves stale pixels"
        g.click(750,438)  # last terminal
        g.until(lambda: g.pixel(200,250) == (32,35,56), "overview switches to terminal")
        g.click(752,732)
        time.sleep(1)
        reopened = g.region(335,186,298,64)
        g.move(440,210)
        g.move(1050,560)
        time.sleep(1)
        assert reopened == g.region(335,186,298,64), "reopened overview did not restore its new base"
        g.click(750,286)  # Clock
        g.click(513,409)  # minimize it
        g.click(752,732)
        time.sleep(1)
        minimized_clock = g.region(657,277,72,37)
        g.until(lambda: g.region(657,277,72,37) != minimized_clock, "minimized Clock preview remains live", 5)
        g.click(750,286)  # restore Clock from its card
        g.click(481,409)  # close it; indices compact
        g.until(lambda: 'clock: closed' in g.log(), "Clock closes after overview restore")
        g.click(752,732)
        time.sleep(1)
        g.screenshot("after-close-compacted-cards")
        g.key("esc")
        g.click(588,732)  # new Clock ID; overview returns to eight cards
        g.until(lambda: g.log().count('clock: got window') == 2, "Clock relaunches with new identity")
        g.click(752,732)
        time.sleep(1)
        new_clock = g.region(657,429,72,37)
        g.until(lambda: g.region(657,429,72,37) != new_clock, "new Clock preview invalidates compacted cache slot", 5)
        g.key("esc")
        print("Overview checks passed.", flush=True)
    finally:
        g.close()


if __name__ == "__main__":
    main()
