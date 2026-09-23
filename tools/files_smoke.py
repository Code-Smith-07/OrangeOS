#!/usr/bin/env python3
"""Real Files search, directory pagination and text preview regression.

Build with -Ddesktop-profile and scripts/mkdisk.sh first. Fixtures go into a
temporary COPY of the root disk, never the development rootfs or live VM disk.
"""
import pathlib
import shutil
import subprocess
import tempfile
import time
from desktop_smoke import Guest, ROOT


def fixture_disk():
    work = pathlib.Path(tempfile.mkdtemp(prefix="orange-files-fixture-"))
    root = work / "rootfs"
    shutil.copytree(ROOT / "build/rootfs", root)
    fixture = root / "etc" / "files-test"
    fixture.mkdir()
    for i in range(40):
        (fixture / f"entry{i:02d}.txt").write_text(f"Real disk entry {i}\n")
    # Over 4 KiB, more than twelve visual rows, distinct pages for pixel checks.
    (fixture / "entry39.txt").write_text("".join(f"Line {i:04d}: real CitrusFS file preview.\n" for i in range(2200)))
    (fixture / "binary.bin").write_bytes(bytes(range(256)))
    fs = work / "citrus.img"
    disk = work / "disk.img"
    subprocess.run(["python3", str(ROOT / "tools/mkcitrusfs/mkcitrusfs.py"), str(fs), str(root), "32"], check=True)
    shutil.copyfile(ROOT / "build/disk.img", disk)
    with disk.open("r+b") as dst, fs.open("rb") as src:
        dst.seek(22528 * 512)
        shutil.copyfileobj(src, dst)
    return disk


def main():
    g = Guest(disk_path=fixture_disk())
    print(f"Evidence: {g.output}", flush=True)
    def text(value):
        for ch in value:
            g.key("minus" if ch == "-" else ch)
    def search(value):
        g.key("ctrl-f")
        text(value)
    def open_selected():
        g.key("ret")  # Finish search with first result selected.
        g.key("ret")  # Open selected result.
    try:
        g.until(lambda: "grove: painted" in g.log() and "squeeze: window" in g.log(), "desktop", 45)
        g.scale = 2
        g.click(360, 732)
        g.until(lambda: "files: listed /:" in g.log(), "real Files root")
        g.click(330, 300)
        g.until(lambda: "files: listed /etc:" in g.log(), "System folder")
        search("files-test")
        g.until(lambda: "filter 'files-test': 1 matches" in g.log(), "real substring search")
        g.screenshot("search")
        open_selected()
        g.until(lambda: "files: listed /etc/files-test: 41 entries" in g.log(), "directory entries beyond original 32-entry limit")
        g.key("end")
        g.until(lambda: "files: selected entry39.txt" in g.log(), "End selects last entry across pages")
        g.key("home")
        g.until(lambda: "files: selected binary.bin" in g.log(), "Home selects first entry")
        g.key("ret")
        g.until(lambda: "files: preview /etc/files-test/binary.bin, 256 bytes" in g.log(), "binary file read safely")
        g.screenshot("binary")
        g.key("esc")
        search("zzz")
        g.until(lambda: "filter 'zzz': 0 matches" in g.log(), "no-result search")
        g.screenshot("no-results")
        g.key("backspace")
        g.until(lambda: "filter 'zz': 0 matches" in g.log(), "Backspace edits search without navigating")
        g.key("esc")
        g.until(lambda: "filter '': 41 matches" in g.log(), "Escape restores listing")
        search("entry39")
        g.until(lambda: "filter 'entry39': 1 matches" in g.log(), "search finds entry beyond first syscall batch")
        open_selected()
        g.until(lambda: "files: preview /etc/files-test/entry39.txt, 65536 bytes" in g.log(), "bounded 64 KiB preview via repeated reads")
        time.sleep(1)
        g.move(700, 650)
        first = g.region(460, 366, 440, 200)
        g.screenshot("preview-page1")
        offset = len(g.log())
        g.key("pgdn")
        g.until(lambda: "files: preview page 2" in g.log(), "Page Down reaches hidden text")
        assert g.log()[offset:].count("files: preview page") == 1, "extended key release navigates twice"
        g.until(lambda: g.region(460, 366, 440, 200) != first, "page two actually changes visible text")
        g.screenshot("preview-page2")
        g.key("pgup")
        g.until(lambda: "files: preview page 1" in g.log(), "Page Up returns")
        g.until(lambda: g.region(460, 366, 440, 200) == first, "page one restored exactly")
        offset = len(g.log())
        g.click(897, 627)
        g.until(lambda: "files: preview page 2" in g.log()[offset:], "preview forward button")
        g.key("esc")
        g.key("esc")
        g.key("home")
        offset = len(g.log())
        for _ in range(3):
            g.key("home")
        assert "files: painted" not in g.log()[offset:], "redundant selection repaints"
        assert "KERNEL PANIC" not in g.log() and "[app fault]" not in g.log()
        print("PASS Files search, keyboard selection, pagination, preview and no-op redraws", flush=True)
    finally:
        g.close()


if __name__ == "__main__":
    main()
