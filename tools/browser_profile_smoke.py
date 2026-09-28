#!/usr/bin/env python3
"""Orange Browser's cookies and local storage survive a reboot (B11).

Build: zig build -Ddesktop-profile -Dwpe-probes; ORANGE_WPE_PROBES=1 scripts/mkdisk.sh

Boots twice on one fresh data disk. Each time the browser opens from the
dock and loads the HTTPS fixture's /cookie.html, whose title reports whether
it found its cookie and its local-storage item, then sets both. The first
boot must find neither; the second must find both, read back from
/data/orange-browser.
"""
import os
import pathlib
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(__file__))
import runtime_smoke  # noqa: E402  (the HTTPS fixture)
import browser_smoke as b  # noqa: E402
from desktop_smoke import Guest  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[1]


def visit(image, expect, label):
    g = Guest(extra_args=("-drive", f"id=data0,file={image},format=raw,if=none",
                          "-device", "ide-hd,drive=data0,bus=ahci.1"))
    try:
        g.until(lambda: '"Welcome"' in g.log() and "squeeze: window" in g.log(), "boot to desktop", 90)
        time.sleep(1)
        g.click(*b.DOCK_BROWSER)
        g.until(lambda: b.loads(g, "file:///share/browser/start.html") >= 1, "the browser starts", 600)
        assert "orange-browser: website data in /data/orange-browser" in g.log(), g.log()[-2000:]
        g.click(*b.ADDRESS)
        b.typed(g, "10.0.2.2:38459/cookie.html")
        g.key("ret")
        g.until(lambda: 'orange-browser: title "found:' in g.log(), "the cookie page reports", 180)
        assert f'orange-browser: title "{expect}"' in g.log(), g.log()[-2000:]
        # WebKit writes its databases shortly after; /data saves every 2 s.
        time.sleep(10)
        print(f"PASS {label}", flush=True)
    finally:
        g.close()


def main():
    os.environ["ORANGE_WPE_PROBES"] = "1"
    https = runtime_smoke.https_server()
    work = pathlib.Path(tempfile.mkdtemp(prefix="orange-profile-"))
    image = work / "data.img"
    subprocess.run([sys.executable, str(ROOT / "tools/mkdata.py"), str(image), "--size-mib", "128"], check=True)
    try:
        visit(image, "found:none,none", "a fresh profile has no cookie or local storage")
        visit(image, "found:cookie,stored", "after a reboot the cookie and local storage are back")
    finally:
        https.shutdown()
    print(f"Browser profile checks passed; data disk in {work}", flush=True)


if __name__ == "__main__":
    main()
