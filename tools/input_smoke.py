#!/usr/bin/env python3
"""Peel delivers every key change, even to a program that falls behind.

Build: zig build -Ddesktop-profile -Dwpe-probes
       ORANGE_WPE_PROBES=1 ORANGE_INPUT_PROBE=1 scripts/mkdisk.sh

input-probe opens a large window and stops reading input for three seconds.
Meanwhile this floods pointer motion over it (far more than its 16-message
port holds) and presses Ctrl+T. The probe must then receive every press
with its release. Before Peel kept a backlog, the releases could be dropped
with the motion, which left Ctrl held in Orange Browser.
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
from desktop_smoke import Guest  # noqa: E402


def main():
    os.environ["ORANGE_WPE_PROBES"] = "1"
    g = Guest()
    try:
        g.until(lambda: "input-probe: ready" in g.log(), "the probe's window is up", 180)
        time.sleep(0.3)
        for i in range(60):
            g.monitor(f"mouse_move {5 if i % 2 else -5} {3 if i % 4 < 2 else -3}")
        g.key("ctrl-t")
        for i in range(60):
            g.monitor(f"mouse_move {5 if i % 2 else -5} 0")
        g.until(lambda: "input-probe: PASS" in g.log() or "input-probe: FAIL" in g.log(), "the probe reports", 60)
        line = g.log().split("input-probe: ")[-1].splitlines()[0]
        assert line.startswith("PASS"), line
        print(f"PASS every key change arrived after a full queue: {line[5:]}", flush=True)
    finally:
        g.close()


if __name__ == "__main__":
    main()
