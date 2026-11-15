#!/usr/bin/env python3
"""Open real websites in Orange Browser and report what happened.

Build: zig build -Ddesktop-profile -Dwpe-probes
       ORANGE_WPE_PROBES=1 scripts/mkdisk.sh

This is a report, not a pass/fail test: the internet changes. For each
site it types the address, waits for WebKit to finish or fail, and prints
the final address, the page title and how long it took under emulation.
Screenshots are kept. Needs the host to be online (QEMU's NAT).
"""
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
from desktop_smoke import Guest  # noqa: E402
import browser_smoke as b  # noqa: E402

SITES = [
    "example.com",
    "en.wikipedia.org/wiki/Orange_(fruit)",
    "duckduckgo.com",
    "news.ycombinator.com",
    "github.com/Code-Smith-07",
    "developer.mozilla.org",
    "www.bbc.com/news",
]
KEYS = {".": "dot", ":": "shift-semicolon", "/": "slash", "-": "minus", "_": "shift-minus", "(": "shift-9", ")": "shift-0"}


def typed(g, text):
    for ch in text:
        if ch.isupper():
            g.key("shift-" + ch.lower())
        else:
            g.key(KEYS.get(ch, ch))


def main():
    sites = sys.argv[1:] or SITES
    os.environ["ORANGE_WPE_PROBES"] = "1"
    g = Guest()
    rows = []
    try:
        g.until(lambda: '"Welcome"' in g.log() and "squeeze: window" in g.log(), "boot to desktop", 90)
        g.scale = 2
        time.sleep(1)
        g.click(*b.DOCK_BROWSER)
        g.until(lambda: "orange-browser: loaded file:///share/browser/start.html" in g.log(), "the browser starts", 600)
        time.sleep(2)
        for i, site in enumerate(sites):
            mark = len(g.log())
            g.click(*b.ADDRESS)
            typed(g, site)
            started = time.time()
            g.key("ret")
            outcome, where, title = "timed out", "", ""
            while time.time() - started < 240:
                new = g.log()[mark:]
                done = re.findall(r"orange-browser: loaded (\S+)", new)
                failed = re.findall(r"orange-browser: failed (\S+)", new)
                if done:
                    outcome, where = "loaded", done[-1]
                    break
                if failed:
                    outcome, where = "failed", failed[-1]
                    break
                time.sleep(1)
            seconds = int(time.time() - started)
            time.sleep(6)  # late titles and painting
            titles = re.findall(r'orange-browser: title "([^"]*)"', g.log()[mark:])
            title = titles[-1] if titles else ""
            crashed = "[app fault]" in g.log()[mark:] or "WebProcess crashed" in g.log()[mark:]
            g.screenshot(f"site-{i + 1:02d}")
            rows.append((site, outcome + (" (a process crashed)" if crashed else ""), seconds, where, title))
            print(f"{site}: {outcome} in {seconds}s, title \"{title}\"", flush=True)
    finally:
        g.close()
    print()
    print("| Site | Result | Seconds | Title |")
    print("|---|---|---|---|")
    for site, outcome, seconds, where, title in rows:
        print(f"| {site} | {outcome} | {seconds} | {title[:60]} |")
    print(f"Screenshots in {g.output}")


if __name__ == "__main__":
    main()
