#!/usr/bin/env python3
"""Real Welcome shortcuts and calendar navigation; build -Ddesktop-profile."""
import re
import time
from desktop_smoke import Guest

g = Guest()
print(f"Evidence: {g.output}", flush=True)
try:
    g.until(lambda: 'grove: painted' in g.log() and 'squeeze: window' in g.log(), 'Welcome ready', 45)
    g.scale = 2
    g.click(820, 320)
    g.until(lambda: 'desktop: requested panel 5' in g.log(), 'Welcome opens Windows')
    g.key('esc')
    g.click(950, 320)
    g.until(lambda: 'files: listed /Trash: 0 entries' in g.log(), 'Welcome opens real Trash folder')
    g.click(281, 189)
    g.until(lambda: re.search(r'closed window \d+ "Trash"', g.log()), 'Trash closed')
    g.click(1100, 320)
    g.until(lambda: '"About Orange OS"' in g.log(), 'Welcome opens About')
    g.click(461, 239)
    g.until(lambda: re.search(r'closed window \d+ "About Orange OS"', g.log()), 'About closed')
    g.click(1180, 18)
    g.until(lambda: 'desktop: calendar offset 0' in g.log(), 'Date opens current calendar')
    g.move(700, 80)
    time.sleep(.5)
    baseline = g.region(904, 168, 360, 305)
    g.screenshot('calendar')
    g.click(1222, 182)
    g.until(lambda: 'desktop: calendar offset 1' in g.log(), 'Next month')
    g.move(700, 80)
    assert g.region(904, 168, 360, 305) != baseline, 'month view did not change'
    offset = len(g.log())
    g.click(1184, 182)
    g.until(lambda: 'desktop: calendar offset 0' in g.log()[offset:], 'Previous month returns')
    g.move(700, 80)
    assert g.region(904, 168, 360, 305) == baseline, 'current month did not restore exactly'
    g.click(1184, 182)
    g.until(lambda: 'desktop: calendar offset -1' in g.log(), 'Previous month')
    offset = len(g.log())
    g.click(1192, 100)
    g.until(lambda: 'desktop: calendar offset 0' in g.log()[offset:], 'Today resets month')
    g.click(1120, 155)  # blank panel area must not dismiss it
    g.move(700, 80)
    assert g.region(904, 168, 360, 305) == baseline, 'blank click dismissed or changed calendar'
    print('PASS calendar hover and blank-click pixel stability', flush=True)
    g.click(1070, 448)
    g.until(lambda: '"clock"' in g.log(), 'Calendar opens real Clock')
    g.click(1180, 18)
    g.click(1180, 18)
    g.move(700, 80)
    assert g.region(904, 168, 360, 305) != baseline, 'date toggle failed to dismiss calendar'
    print('PASS date toggles panel closed', flush=True)
finally:
    g.close()
