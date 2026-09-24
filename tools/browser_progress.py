#!/usr/bin/env python3
"""Read-only terminal progress display for the Chromium Mac reference build.

The percentage is an estimate across incremental build attempts. Siso may
change its action graph, and a repeated action can be counted twice. This
viewer never starts, stops, or qualifies the build.
"""

import argparse
from datetime import datetime
import json
from pathlib import Path
import re
import shutil
import sys
import time

from browser_reference import WORK, live_status


ACTION = re.compile(r"^\[(\d+)/(\d+)\]\s+(.*)$")
LOG_NAME = re.compile(r"\d+-build\.log$")


def last_action(path, max_bytes=65536):
    """Read only the tail of an owned build log, not its potentially huge body."""
    with path.open("rb") as stream:
        stream.seek(max(0, path.stat().st_size - max_bytes))
        lines = stream.read(max_bytes).decode("utf-8", errors="replace").splitlines()
    for line in reversed(lines):
        match = ACTION.match(line)
        if match:
            done, total = int(match[1]), int(match[2])
            if 0 <= done <= total and total > 0:
                return done, total, match[3]
    return None


def snapshot(work=WORK):
    state_path = work / "state.json"
    state = json.loads(state_path.read_text()) if state_path.is_file() else {}
    record = state.get("build", {})
    live = live_status(work, state)
    result = record.get("result", "not started")
    if result == "running" and not live["runner_lock_held"]:
        result = "stale/interrupted"
    logs_dir = (work / "logs").resolve()
    current_path = Path(record["log"]).resolve() if record.get("log") else None
    if current_path and not current_path.is_relative_to(logs_dir):
        return {"result": "invalid log path", "error": "Build record points outside the workspace logs"}

    attempts = []
    if current_path and logs_dir.is_dir():
        for path in sorted(logs_dir.glob("*-build.log")):
            if not LOG_NAME.fullmatch(path.name) or path.name > current_path.name:
                continue
            if not path.resolve().is_relative_to(logs_dir) or not path.is_file():
                continue
            action = last_action(path)
            if action:
                attempts.append((path.resolve(), *action))

    current = next((entry for entry in attempts if entry[0] == current_path), None)
    prior_done = sum(entry[1] for entry in attempts if entry[0] != current_path)
    report = {"result": result, "workers": record.get("local_jobs"),
              "attempts": len(attempts), "running": bool(live["runner_lock_held"]),
              "current": current, "prior_done": prior_done}
    if current:
        _, done, total, action = current
        remaining = 0 if result == "passed" else total - done
        estimated_done = prior_done + (total if result == "passed" else done)
        estimated_total = prior_done + total
        report.update({"pass_done": done, "pass_total": total, "remaining": remaining,
                       "estimated_done": estimated_done, "estimated_total": estimated_total,
                       "percent": 100.0 if result == "passed" else
                       100.0 * estimated_done / estimated_total,
                       "action": action})
    elif result == "passed":
        report["percent"] = 100.0
    return report


def render(report, columns=80):
    width = max(20, min(54, columns - 14))
    lines = ["OrangeOS | Chromium reference build", "=" * min(columns, 65)]
    percent = report.get("percent")
    if percent is None:
        lines.append("Progress: waiting for build actions")
    else:
        filled = round(width * percent / 100)
        lines.append(f"[{('#' * filled).ljust(width, '-')}] {percent:5.1f}% complete")
        lines.append(f"Estimated remaining: {100 - percent:.1f}%")
    lines.append(f"State: {report['result'].upper()}    Workers: {report.get('workers') or '-'}")
    if report.get("current"):
        if report["result"] == "passed":
            lines.append("Build completed successfully; no actions remain.")
        else:
            lines.append(f"Current pass: {report['pass_done']:,} / {report['pass_total']:,} actions")
            lines.append(f"Across {report['attempts']} passes: ~{report['estimated_done']:,} done, "
                         f"~{report['remaining']:,} left")
            action = report["action"]
            lines.append("Latest: " + (action[:max(12, columns - 8)]))
    if report.get("error"):
        lines.append("Warning: " + report["error"])
    lines.extend(["", "Estimate can shift as Chromium changes its action graph.",
                  "This builds a Mac test shell, not an OrangeOS browser.",
                  "Viewer is read-only; Ctrl-C closes it without stopping the build."])
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--watch", action="store_true", help="Refresh the terminal display")
    parser.add_argument("--interval", type=float, default=2.0, help="Refresh seconds (minimum 1)")
    args = parser.parse_args()
    if args.interval < 1:
        parser.error("--interval must be at least 1 second")
    if not args.watch:
        print(render(snapshot(), shutil.get_terminal_size().columns))
        return 0
    interactive = sys.stdout.isatty()
    if interactive:
        sys.stdout.write("\x1b[?1049h\x1b[?25l")
    try:
        while True:
            output = render(snapshot(), shutil.get_terminal_size().columns)
            if interactive:
                sys.stdout.write("\x1b[H" + output + "\x1b[J")
            else:
                sys.stdout.write(f"\n{datetime.now().astimezone():%Y-%m-%d %H:%M:%S %Z}\n{output}\n")
            sys.stdout.flush()
            time.sleep(args.interval)
    except KeyboardInterrupt:
        return 0
    finally:
        if interactive:
            sys.stdout.write("\x1b[?25h\x1b[?1049l")
            sys.stdout.flush()


if __name__ == "__main__":
    raise SystemExit(main())
