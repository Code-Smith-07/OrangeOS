#!/usr/bin/env python3
"""Observe blank-click/hover redraws in real apps; does not certify scanout.

Build with -Ddesktop-profile and rebuild disk first. No app code changes.
Reports guest frame work and transient sampled pixels. Clock's time text is
excluded from its stable probe. QMP sampling can miss shorter-lived flicker.
"""
import json
import re
import time
from desktop_smoke import Guest

g = Guest()
print(f'Evidence: {g.output}', flush=True)
results = []

def audit(name, blank, probe, hover=None):
    g.click(*blank)
    time.sleep(1)
    baseline = g.region(*probe)
    offset = len(g.log())
    changed = 0
    samples = 0
    for _ in range(4):
        for buttons in (1, 0):
            g.monitor(f'mouse_button {buttons}')
            for _ in range(3):
                time.sleep(.04)
                samples += 1
                changed += g.region(*probe) != baseline
    time.sleep(1)
    frames = [(int(a), int(b)) for a, b in re.findall(r'perf: frame (\d+)ms area (\d+)', g.log()[offset:])]
    result = dict(app=name, blank_clicks=4, sampled_frames=samples,
                  transient_changed_samples=changed,
                  settled_pixels_restored=g.region(*probe) == baseline,
                  scene_frames=sum(area > 50000 for _, area in frames),
                  max_guest_frame_ms=max((ms for ms, _ in frames), default=0))
    if hover:
        offset = len(g.log())
        for _ in range(3):
            g.move(*hover)
            g.move(*blank)
        time.sleep(1)
        result['hover_pixels_restored'] = g.region(*probe) == baseline
        result['hover_max_guest_frame_ms'] = max((int(ms) for ms in re.findall(r'perf: frame (\d+)ms', g.log()[offset:])), default=0)
    g.screenshot(name.lower())
    results.append(result)
    print(json.dumps(result), flush=True)

try:
    g.until(lambda: 'grove: painted' in g.log() and 'squeeze: window' in g.log(), 'desktop', 45)
    g.scale = 2
    audit('Welcome', (900,295), (760,155,420,372), (820,395))
    audit('Terminal', (350,340), (80,160,600,340))
    g.click(664,732)
    g.until(lambda: '"About Orange OS"' in g.log(), 'About')
    audit('About', (650,500), (450,270,395,310), (770,555))
    g.click(461,239)
    g.click(360,732)
    g.until(lambda: 'files: listed /:' in g.log(), 'Files')
    audit('Files', (700,610), (270,220,660,430), (600,330))
    g.click(281,189)
    g.click(916,732)
    g.until(lambda: 'files: listed /Trash:' in g.log(), 'Trash')
    audit('Trash', (700,610), (270,220,660,430), (310,403))
    g.click(281,189)
    g.click(588,732)
    g.until(lambda: '"clock"' in g.log(), 'Clock')
    audit('Clock', (600,620), (485,570,310,50))
    (g.output/'audit.json').write_text(json.dumps(results, indent=2)+'\n')
finally:
    g.close()
