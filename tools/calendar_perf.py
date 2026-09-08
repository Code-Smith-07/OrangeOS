#!/usr/bin/env python3
"""Calendar redraw acceptance under the standard 3 GiB / 2 vCPU QEMU profile.

Build with -Ddesktop-profile and rebuild the disk. Measures compositor work,
not end-to-end host presentation latency. Cold opening is reported separately.
"""
import math
import json
import re
import sys
import time
from desktop_smoke import Guest


def frames(text):
    return [int(ms) for ms, area in re.findall(r"perf: frame (\d+)ms area (\d+)", text) if int(area)]


g = Guest()
print(f"Evidence: {g.output}", flush=True)
try:
    g.until(lambda: "grove: painted" in g.log(), "Welcome ready", 45)
    g.scale = 2
    if "--stress" in sys.argv:
        for x in (360, 588, 664, 916):
            g.click(x, 732)
        g.until(lambda: len(re.findall(r'peel: window \d+ "', g.log())) == 6, "six desktop apps", 20)
        for count in (7, 8):
            g.click(24, 20)
            g.click(100, 148)
            g.until(lambda: len(re.findall(r'peel: window \d+ "', g.log())) == count, f"{count} windows", 20)
        # Bring Clock forward and move it under the calendar. Its live seconds
        # must invalidate the material cache, unlike a frozen screenshot.
        g.click(588, 732)
        g.move(620, 409)
        g.monitor("mouse_button 1")
        g.move(1050, 150)
        g.monitor("mouse_button 0")
        time.sleep(.5)
    g.move(1180, 18)
    time.sleep(.5)
    start = len(g.log())
    g.click(1180, 18)
    g.until(lambda: "desktop: calendar offset 0" in g.log()[start:], "calendar opens")
    time.sleep(.7)
    cold = frames(g.log()[start:])
    print(f"MEASURE cold-open max compositor work: {max(cold)} ms", flush=True)
    results = {"stress": "--stress" in sys.argv, "cold_max_ms": max(cold)}
    if "--stress" in sys.argv:
        backdrop = g.region(915, 240, 325, 45)
        g.until(lambda: g.region(915, 240, 325, 45) != backdrop, "live Clock updates through calendar glass", 5)
    g.move(1120, 155)
    time.sleep(.3)
    start = len(g.log())
    for _ in range(2 if "--quick" in sys.argv else 12):
        for x, y in ((1184, 182), (1222, 182), (1192, 100), (1070, 448), (1120, 155)):
            g.move(x, y)
            time.sleep(.04)
    samples = frames(g.log()[start:])
    assert len(samples) >= (10 if "--quick" in sys.argv else 24), "not enough nonempty frame samples"
    p95 = sorted(samples)[math.ceil(len(samples) * .95) - 1]
    print(f"MEASURE warm calendar: {len(samples)} frames, p95={p95} ms, max={max(samples)} ms", flush=True)
    results.update(samples=len(samples), warm_p95_ms=p95, warm_max_ms=max(samples))
    (g.output / "calendar-performance.json").write_text(json.dumps(results, indent=2) + "\n")
    assert p95 < 50 and max(samples) <= 100, "calendar warm redraw budget exceeded"
    g.move(700, 80)
    baseline = g.region(904, 168, 360, 305)
    start = len(g.log())
    for _ in range(4):
        g.click(1222, 182)
        g.click(1184, 182)
    g.move(700, 80)
    time.sleep(.3)
    if "--stress" not in sys.argv:
        assert g.region(904, 168, 360, 305) == baseline, "navigation/hover corrupted calendar pixels"
    samples = frames(g.log()[start:])
    print(f"MEASURE month navigation max compositor work: {max(samples)} ms", flush=True)
    results["navigation_max_ms"] = max(samples)
    (g.output / "calendar-performance.json").write_text(json.dumps(results, indent=2) + "\n")
    assert max(samples) <= 100, "month navigation rebuilds an expensive scene"
    g.screenshot("calendar-optimized")
    print("PASS calendar performance and restored-pixel regression gates", flush=True)
finally:
    g.close()
