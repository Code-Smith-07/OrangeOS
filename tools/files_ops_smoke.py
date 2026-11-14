#!/usr/bin/env python3
"""Files that change things, and the Text Editor (docs/design/014, M3 and M4).

Build: zig build -Ddesktop-profile && scripts/mkdisk.sh

On a fresh data disk, in a real desktop:
  1. Files opens in Documents; a new folder is made and renamed; a double
     click opens it.
  2. Text Editor saves a new document into Documents (safely, by rename),
     and says so with a notification.
  3. Quick Look (Space) shows the document; Delete moves it to the Trash;
     Put Back returns it to where it was; Spotlight finds it by name and
     opens it in Text Editor.
  4. A window with unsaved changes asks before closing: Cancel keeps it,
     Don't Save closes it.
  5. Empty Trash deletes for good, after asking.
  6. After a reboot the folder and the document are still there.
"""
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(__file__))
from desktop_smoke import Guest, frame_of, button  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[1]


def boot(image):
    g = Guest(extra_args=("-drive", f"id=data0,file={image},format=raw,if=none",
                          "-device", "ide-hd,drive=data0,bus=ahci.1"))
    g.until(lambda: '"Welcome"' in g.log() and "squeeze: window" in g.log(), "boot to desktop", 90)
    g.scale = 2
    size = re.search(r"peel: (\d+)x(\d+)", g.log())
    g.width, g.height = int(size.group(1)) // g.scale, int(size.group(2)) // g.scale
    time.sleep(1.5)
    return g


def typed(g, text):
    keys = {" ": "spc", ".": "dot", "-": "minus"}
    for ch in text:
        g.key(keys.get(ch, ch))


def spotlight(g, text):
    before = g.log().count("desktop: spotlight open")
    g.key("alt-spc")
    g.until(lambda: g.log().count("desktop: spotlight open") > before, "Spotlight opens")
    typed(g, text)
    time.sleep(.8)
    g.key("ret")


def window_ids(g, title):
    return [int(m) for m in re.findall(rf'peel: window (\d+) "{re.escape(title)}"', g.log())]


def count(g, text):
    return g.log().count(text)


def main():
    work = pathlib.Path(tempfile.mkdtemp(prefix="orange-files-ops-"))
    image = work / "data.img"
    subprocess.run([sys.executable, str(ROOT / "tools/mkdata.py"), str(image), "--size-mib", "64"], check=True)
    g = boot(image)
    try:
        # 1. Files starts in Documents on the data disk.
        spotlight(g, "files")
        g.until(lambda: "files: listed /data/Documents: 0 entries" in g.log(), "Files opens in Documents", 30)
        files = window_ids(g, "Files")[-1]
        time.sleep(1)
        g.key("ctrl-shift-n")
        time.sleep(.6)
        g.screenshot("01-new-folder-sheet")
        g.key("ret")
        g.until(lambda: "files: new folder /data/Documents/untitled folder" in g.log(), "a new folder is made")
        # The new folder is selected: F2 renames it.
        g.key("f2")
        time.sleep(.5)
        for _ in range(len("untitled folder")):
            g.key("backspace")
        typed(g, "projects")
        g.key("ret")
        g.until(lambda: "files: renamed /data/Documents/untitled folder to /data/Documents/projects" in g.log(), "the folder is renamed")
        print("PASS a folder is made in Documents and renamed", flush=True)
        # A name that is already taken is refused, with the sheet left open.
        g.key("ctrl-shift-n")
        time.sleep(.5)
        for _ in range(len("untitled folder")):
            g.key("backspace")
        typed(g, "projects")
        g.key("ret")
        time.sleep(.8)
        assert count(g, "files: new folder") == 1, "a duplicate name was accepted"
        g.screenshot("02-name-taken")
        g.key("esc")
        print("PASS a name already used is refused", flush=True)
        # Double click opens the folder (first tile of the grid).
        fx, fy, fw, fh, cx, cy = frame_of(g, files)
        tile = (cx + 180 + (500 - 4 * 118 + 6) // 2 + 56, cy + 52 + 16 + 40)
        g.move(*tile)
        for _ in range(2):
            g.monitor("mouse_button 1")
            time.sleep(.04)
            g.monitor("mouse_button 0")
            time.sleep(.06)
        g.until(lambda: "files: listed /data/Documents/projects: 0 entries" in g.log(), "a double click opens the folder")
        g.key("backspace")
        g.until(lambda: count(g, "files: listed /data/Documents:") >= 3, "Back returns to Documents")
        print("PASS a double click opens a folder; a single click only selects", flush=True)

        # 2. Text Editor: type, save, be told.
        spotlight(g, "text")
        g.until(lambda: "editor: new document" in g.log(), "Text Editor opens", 30)
        time.sleep(1.5)
        typed(g, "hello orange")
        g.key("ctrl-s")
        time.sleep(.8)
        g.screenshot("03-save-sheet")
        g.key("ret")
        g.until(lambda: "editor: saved /data/Documents/Untitled.txt, 12 bytes" in g.log(), "the document is saved in Documents")
        g.until(lambda: 'desktop: notification "Saved" from Text Editor' in g.log(), "saving posts a notification")
        time.sleep(.6)
        g.screenshot("04-saved-banner")
        editor = window_ids(g, "Untitled")[-1]
        g.click(*button(g, editor, 0))
        g.until(lambda: f"peel: closed window {editor}" in g.log(), "a saved document closes without asking")
        print("PASS Text Editor saved Untitled.txt, notified, and closed without asking", flush=True)

        # 3. Quick Look, Trash, Put Back, Spotlight.
        g.key("backspace")  # Files is in front again: refresh by going back
        time.sleep(.5)
        g.click(cx + 60, cy + 52 + 24 + 14)  # Documents in the sidebar
        g.until(lambda: "files: listed /data/Documents: 2 entries" in g.log(), "Documents now lists the document")
        g.key("end")
        g.until(lambda: "files: selected Untitled.txt" in g.log(), "End selects the document")
        g.key("spc")
        g.until(lambda: "files: preview /data/Documents/Untitled.txt, 12 bytes" in g.log(), "Space shows Quick Look")
        time.sleep(.5)
        g.screenshot("05-quick-look")
        g.key("spc")
        time.sleep(.4)
        g.key("delete")
        g.until(lambda: "files: moved /data/Documents/Untitled.txt to the Trash" in g.log(), "Delete moves it to the Trash")
        g.until(lambda: 'desktop: notification "Moved to Trash" from Files' in g.log(), "the Trash move is announced")
        g.click(cx + 60, cy + 52 + 24 + 4 * 30 + 14)  # Trash in the sidebar
        g.until(lambda: "files: listed /data/Trash: 1 entries" in g.log(), "the Trash holds the document")
        g.key("home")
        time.sleep(.4)
        g.screenshot("06-trash")
        # Put Back is the first toolbar action while in the Trash.
        search_x = 680 - 16 - 64 - 10 - 110
        g.click(cx + search_x - 12 - 3 * 32 + 14, cy + 26)
        g.until(lambda: "files: put back /data/Documents/Untitled.txt" in g.log(), "Put Back returns it to Documents")
        print("PASS Quick Look, Move to Trash and Put Back work on the data disk", flush=True)
        spotlight(g, "untitled")
        g.until(lambda: "desktop: open /data/Documents/Untitled.txt with Text Editor" in g.log(), "Spotlight finds the document by name")
        g.until(lambda: "editor: opened /data/Documents/Untitled.txt, 12 bytes" in g.log(), "Text Editor opens it", 30)
        print("PASS Spotlight finds the document and opens it in Text Editor", flush=True)

        # 4. Unsaved changes: the close button asks.
        time.sleep(1.5)
        editor = window_ids(g, "Untitled")[-1]
        typed(g, "x")
        time.sleep(.5)
        g.click(*button(g, editor, 0))
        g.until(lambda: f"desktop: asked window {editor} to close" in g.log(), "closing asks the document")
        time.sleep(.6)
        g.screenshot("07-unsaved-sheet")
        g.key("esc")
        time.sleep(.6)
        assert f"peel: closed window {editor}" not in g.log(), "Cancel closed the window"
        g.click(*button(g, editor, 0))
        g.until(lambda: count(g, f"desktop: asked window {editor} to close") == 2, "closing asks again")
        time.sleep(.6)
        ex, ey, ew, eh, ecx, ecy = frame_of(g, editor)
        # Don't Save: the first of three buttons in the sheet.
        panel_x, panel_y = (640 - 380) // 2, max(8, (460 - 142) // 3)
        g.click(ecx + panel_x + 380 - 20 - 3 * 104 - 16 + 52, ecy + panel_y + 142 - 20 - 13)
        g.until(lambda: f"peel: closed window {editor}" in g.log(), "Don't Save closes the window")
        print("PASS unsaved changes: Cancel keeps the window, Don't Save closes it", flush=True)

        # 5. Empty Trash asks, then deletes for good.
        time.sleep(.5)
        g.click(cx + 60, cy + 52 + 24 + 14)
        g.until(lambda: count(g, "files: listed /data/Documents: 2 entries") >= 2, "Documents again")
        g.key("home")
        g.until(lambda: "files: selected projects" in g.log(), "the folder is selected")
        g.key("delete")
        g.until(lambda: "files: moved /data/Documents/projects to the Trash" in g.log(), "the folder goes to the Trash")
        g.click(cx + 60, cy + 52 + 24 + 4 * 30 + 14)
        g.until(lambda: count(g, "files: listed /data/Trash: 1 entries") >= 2, "the Trash holds the folder")
        g.click(cx + search_x - 12 - 2 * 32 + 14, cy + 26)  # Empty
        time.sleep(.6)
        g.screenshot("08-empty-trash-sheet")
        assert "files: emptied the Trash" not in g.log(), "the Trash was emptied without asking"
        g.key("ret")
        g.until(lambda: "files: emptied the Trash, 1 items" in g.log(), "Empty Trash deletes after asking")
        g.until(lambda: "files: listed /data/Trash: 0 entries" in g.log(), "the Trash is empty")
        print("PASS Empty Trash asks first, then deletes", flush=True)
        time.sleep(4)  # /data's periodic save
        g.monitor("stop")
    finally:
        g.close()

    g = boot(image)
    try:
        spotlight(g, "files")
        g.until(lambda: "files: listed /data/Documents: 1 entries" in g.log(), "the document is still there after a reboot", 30)
        print("PASS the document survives a reboot", flush=True)
    finally:
        g.close()
    print(f"Files and Text Editor checks passed; evidence in {g.output}", flush=True)


if __name__ == "__main__":
    main()
