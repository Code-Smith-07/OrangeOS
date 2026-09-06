#!/usr/bin/env python3
"""Repeatable real-guest render timings. Build with -Ddesktop-profile.

This measures guest composition/presentation work under TCG, not host display
latency or achievable native-hardware FPS. Does not use a user's live disk.
"""
import json
import re
import statistics
import time
from desktop_smoke import Guest

g = Guest()
print(f"Evidence: {g.output}", flush=True)
results = {}
def phase(name, action):
    time.sleep(1)
    start = len(g.log())
    action()
    time.sleep(2)
    values = [(int(a), int(b)) for a,b in re.findall(r"perf: frame (\d+)ms area (\d+)", g.log()[start:])]
    assert values, f"no profile samples for {name}; build with -Ddesktop-profile"
    ms = sorted(a for a,b in values)
    results[name] = dict(samples=len(ms), median_ms=statistics.median(ms),
                         p95_ms=ms[min(len(ms)-1, int(len(ms)*.95))],
                         max_area=max(b for a,b in values))
    print(name, results[name], flush=True)
try:
    g.until(lambda: '"Welcome"' in g.log() and "squeeze: window" in g.log(), "desktop", 45)
    g.scale = 2
    time.sleep(2)
    phase("pointer_client", lambda: [g.move(x, 340) for x in (320,350,380,410,440,470)])
    g.key("f4")
    phase("pointer_glass", lambda: [g.move(x, 365) for x in (1070,1090,1110,1130,1110,1090)])
    g.key("esc")
    phase("dock_hover", lambda: [g.move(x, 732) for x in (430,510,590,670,750,830)])
    g.move(350,131)
    def drag():
        g.monitor("mouse_button 1")
        time.sleep(.3)
        for x,y in ((370,141),(390,151),(410,161),(390,151),(370,141),(350,131)):
            g.move(x,y)
        g.monitor("mouse_button 0")
    phase("window_drag", drag)
    phase("open_clock", lambda: g.click(598,732))
    phase("close_clock", lambda: g.click(481,409))
    (g.output / "performance.json").write_text(json.dumps(results, indent=2)+"\n")
finally:
    g.close()
