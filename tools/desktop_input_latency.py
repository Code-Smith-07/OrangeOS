#!/usr/bin/env python3
"""60 Hz QMP input-to-guest-pointer-publication probe; not Cocoa scanout latency.

Build with -Ddesktop-profile and rebuild the unused disk first. Movement samples
may be coalesced; report newest-sample age and longest acknowledgement gap, not
just the time spent drawing the tiny cursor. Uses a disposable guest snapshot.
"""
import json
import re
import statistics
import time
from desktop_smoke import Guest


def main():
    g = Guest()
    print(f"Evidence: {g.output}", flush=True)
    results = {}

    def probe(name, x, y, dx, count=40, drag=False):
        g.move(x, y)
        if drag:
            g.monitor("mouse_button 1")
        time.sleep(.6)
        offset = len(g.log())
        issued = {}
        samples = []
        gaps = []
        last_ack = None
        started = time.monotonic()
        sent = 0
        final = (x + dx * count, y)
        acknowledged = None
        while time.monotonic() - started < 6:
            now = time.monotonic()
            if sent < count and now >= started + sent / 60:
                x += dx
                issued[(x, y)] = now
                g.monitor(f"mouse_move {dx} 0")
                sent += 1
            log = g.log()
            # Read complete lines only, so a partially written serial line
            # cannot disappear across iterations.
            end = log.rfind("\n") + 1
            for px, py in re.findall(r"perf: pointer (\d+),(\d+)", log[offset:end]):
                pos = (int(px), int(py))
                if pos in issued:
                    ack = time.monotonic()
                    samples.append((ack - issued[pos]) * 1000)
                    if last_ack is not None:
                        gaps.append((ack - last_ack) * 1000)
                    last_ack = ack
                    acknowledged = pos
            offset = end
            if sent == count and acknowledged == final:
                break
            time.sleep(.002)
        g.x, g.y = final
        if drag:
            g.monitor("mouse_button 0")
        assert acknowledged == final, f"{name}: input lost or timed out: {acknowledged} != {final}"
        ordered = sorted(samples)
        results[name] = dict(sent=count, publications=len(samples),
                             newest_sample_median_ms=round(statistics.median(samples), 1),
                             newest_sample_p95_ms=round(ordered[min(len(ordered)-1, int(len(ordered)*.95))], 1),
                             longest_publication_gap_ms=round(max(gaps, default=0), 1),
                             final_position=list(final))
        print(name, results[name], flush=True)

    try:
        g.until(lambda: '"Welcome"' in g.log() and "squeeze: window" in g.log(), "desktop", 45)
        time.sleep(2)
        probe("client_motion", 300, 340, 3)
        g.key("f4")
        probe("glass_motion", 1040, 365, 3)
        g.key("esc")
        probe("dock_motion", 430, 732, 3)
        probe("drag_motion", 350, 131, 3, drag=True)
        probe("reverse_motion", 700, 550, -3)
        (g.output / "input-latency.json").write_text(json.dumps(results, indent=2) + "\n")
    finally:
        g.close()


if __name__ == "__main__":
    main()
