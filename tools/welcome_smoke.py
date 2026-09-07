#!/usr/bin/env python3
"""Welcome blank-click and publication regressions; build -Ddesktop-profile."""
import time
from desktop_smoke import Guest

g = Guest()
print(f"Evidence: {g.output}", flush=True)
try:
    g.until(lambda: 'grove: painted' in g.log() and 'squeeze: window' in g.log(), 'Welcome ready', 45)
    g.scale = 2
    g.click(900, 295)  # empty gap below hero; focus once
    time.sleep(.6)
    baseline = g.region(754,150,430,382)
    offset = len(g.log())
    for _ in range(8):
        g.monitor('mouse_button 1')
        time.sleep(.06)
        g.monitor('mouse_button 0')
        time.sleep(.06)
    time.sleep(.6)
    assert 'grove: painted' not in g.log()[offset:], 'blank click repainted Welcome'
    assert g.region(754,150,430,382) == baseline, 'blank clicks changed client pixels'
    print('PASS eight blank clicks do not repaint or change Welcome', flush=True)
    g.move(820,395)
    time.sleep(.3)
    assert 'grove: painted' in g.log()[offset:], 'button hover failed to repaint'
    g.move(900,295)
    time.sleep(.3)
    assert g.region(754,150,430,382) == baseline, 'hover does not restore original pixels'
    print('PASS hover restores original client frame', flush=True)
    g.screenshot('welcome')
finally:
    g.close()
