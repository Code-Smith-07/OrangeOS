#!/usr/bin/env python3
"""Exercise the real desktop through QEMU, using disposable disk writes.

Build first with `zig build && ./scripts/mkdisk.sh`, then run this script.
Requires only Python's standard library and qemu-system-x86_64. Screenshots
and serial evidence are retained in a temporary directory printed on exit.
"""
import json
import os
import pathlib
import re
import socket
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]


class Guest:
    def __init__(self):
        self.output = pathlib.Path(tempfile.mkdtemp(prefix="orange-daybreak-"))
        self.serial = self.output / "serial.log"
        self.process = subprocess.Popen([
            "qemu-system-x86_64", "-M", "q35", "-m", os.environ.get("ORANGE_VM_RAM","3G"),
            "-smp", os.environ.get("ORANGE_VM_CPUS","2"),
            "-cdrom", str(ROOT / "build/orange.iso"), "-boot", "d",
            "-drive", f"id=disk0,file={ROOT / 'build/disk.img'},format=raw,if=none,snapshot=on",
            "-device", "ahci,id=ahci", "-device", "ide-hd,drive=disk0,bus=ahci.0",
            "-netdev", "user,id=n0", "-device", "e1000,netdev=n0",
            "-serial", f"file:{self.serial}", "-display", "none",
            "-qmp", f"unix:{self.output / 'qmp.sock'},server=on,wait=off",
            "-no-reboot", "-no-shutdown",
        ], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(15)
        for _ in range(100):
            try:
                self.sock.connect(str(self.output / "qmp.sock"))
                break
            except (FileNotFoundError, ConnectionRefusedError):
                if self.process.poll() is not None:
                    raise RuntimeError(self.process.stderr.read().decode())
                time.sleep(.1)
        else:
            raise TimeoutError("QMP socket unavailable")
        self.stream = self.sock.makefile("rwb", buffering=0)
        self.stream.readline()
        self.command("qmp_capabilities")
        self.x, self.y = 640, 400
        self.scale = 1

    def command(self, execute, arguments=None):
        request = {"execute": execute}
        if arguments is not None:
            request["arguments"] = arguments
        self.stream.write((json.dumps(request) + "\n").encode())
        while True:
            line = self.stream.readline()
            if not line:
                raise RuntimeError("QEMU disconnected")
            reply = json.loads(line)
            if "error" in reply:
                raise RuntimeError(reply["error"])
            if "return" in reply:
                return reply["return"]

    def monitor(self, cmd):
        return self.command("human-monitor-command", {"command-line": cmd})

    def log(self):
        return self.serial.read_text(errors="replace")

    def until(self, predicate, label, seconds=15, allow_panic=False):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if predicate():
                print(f"PASS {label}", flush=True)
                return
            if not allow_panic and ("CPU EXCEPTION" in self.log() or "KERNEL PANIC" in self.log()):
                raise AssertionError(self.log()[-3000:])
            time.sleep(.1)
        raise AssertionError(f"Timed out: {label}\n{self.log()[-1800:]}")

    def move(self, x, y):
        # PS/2 packets carry bounded relative deltas. Let each small movement
        # drain before pressing a button, especially under software emulation.
        while (self.x, self.y) != (x, y):
            step = 96 // self.scale
            dx = max(-step, min(step, x - self.x))
            dy = max(-step, min(step, y - self.y))
            self.monitor(f"mouse_move {dx*self.scale} {dy*self.scale}")
            self.x += dx
            self.y += dy
            time.sleep(.12)
        time.sleep(.3)

    def click(self, x, y):
        self.move(x, y)
        self.monitor("mouse_button 1")
        time.sleep(.12)
        self.monitor("mouse_button 0")
        time.sleep(.4)

    def key(self, key):
        self.monitor(f"sendkey {key}")
        time.sleep(.4)

    def screenshot(self, name):
        path = self.output / f"{name}.ppm"
        self.command("screendump", {"filename": str(path)})
        return path

    def pixel(self, x, y):
        path = self.screenshot("pixel-check")
        with path.open("rb") as f:
            assert f.readline().strip() == b"P6"
            width, height = map(int, f.readline().split())
            assert f.readline().strip() == b"255"
            x *= self.scale
            y *= self.scale
            assert 0 <= x < width and 0 <= y < height
            f.seek((y * width + x) * 3, 1)
            return tuple(f.read(3))

    def region(self,x,y,w,h):
        path = self.screenshot("region-check")
        with path.open("rb") as f:
            assert f.readline().strip() == b"P6"
            width, height = map(int,f.readline().split())
            assert f.readline().strip() == b"255"
            data = f.read()
        x,y,w,h = (v*self.scale for v in (x,y,w,h))
        assert x+w <= width and y+h <= height
        return b"".join(data[(yy*width+x)*3:(yy*width+x+w)*3] for yy in range(y,y+h))

    def close(self):
        try:
            self.command("quit")
        finally:
            self.stream.close()
            self.sock.close()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                self.process.wait(timeout=5)


def main():
    g = Guest()
    print(f"Evidence: {g.output}", flush=True)
    try:
        g.until(lambda: "framebuffer:" in g.log(), "graphical startup", 30)
        g.screenshot("00-startup")
        g.until(lambda: '"Welcome"' in g.log() and "squeeze: window" in g.log(), "boot to desktop", 45)
        g.scale = 2 if "framebuffer: 2560x1600" in g.log() else 1
        g.until(lambda: "wall clock UTC" in g.log(), "hardware wall clock available")
        epoch = int(re.search(r"wall clock UTC (\d+)", g.log())[1])
        assert abs(epoch-time.time()) < 90, "RTC differs from host UTC by more than 90 seconds"
        print(f"PASS wall time matches host; backing scale {g.scale}x", flush=True)
        time.sleep(1)
        g.screenshot("01-desktop")
        if "--panic" not in sys.argv:
            bar = g.region(1050,10,210,18)
            g.until(lambda: g.region(1050,10,210,18) != bar,"menu clock ticks on screen",5)
            if g.scale == 2:
                letters = g.region(42,10,90,18)
                stride = 180*3
                assert any(letters[y*stride+x*3:y*stride+x*3+3] != letters[y*stride+(x+1)*3:y*stride+(x+1)*3+3]
                           for y in range(36) for x in range(0,180,2)), "text is only pixel-doubled"
                print("PASS text contains native 2x detail",flush=True)
        if "--panic" in sys.argv:
            g.until(lambda: "System halted. Reboot required." in g.log(), "deliberate late panic", 45, allow_panic=True)
            assert "Log leading up to the failure" in g.log()
            assert g.pixel(0, 0) == (16, 11, 6), "panic did not reclaim the graphical framebuffer"
            g.screenshot("08-panic-replay")
            return
        terminal_id = int(re.search(r'peel: window (\d+) "Squeeze', g.log())[1])
        # Repeated small cursor damage over real glass must reproduce the
        # same pixels after the pointer leaves, not accumulate blur or trails.
        g.key("f4")
        g.move(870, 610)
        time.sleep(.5)
        glass = g.region(930, 302, 280, 90)
        cursor_backdrop = g.region(1100, 362, 20, 20)
        for _ in range(2):
            g.move(1100, 362)
            g.until(lambda: g.region(1100, 362, 20, 20) != cursor_backdrop,
                    "pointer visibly enters frosted panel")
            g.move(870, 610)
            g.until(lambda: g.region(1100, 362, 20, 20) == cursor_backdrop,
                    "pointer leaves no trail on glass")
        g.until(lambda: g.region(930, 302, 280, 90) == glass,
                "frosted panel remains stable after cursor redraws")
        g.screenshot("12-frosted-panel")
        g.key("esc")
        base = g.pixel(200, 250)
        g.click(113, 131)
        g.until(lambda: f"minimized window {terminal_id}" in g.log(), "yellow button minimizes terminal")
        g.until(lambda: g.pixel(200, 250) != base, "minimize repaint")
        g.click(517, 732)
        g.until(lambda: g.pixel(200, 250) == base, "dock restore repaint")
        print("PASS dock restores existing terminal", flush=True)
        g.click(135, 131)
        g.until(lambda: f"zoom window {terminal_id} = 1" in g.log(), "green button zooms terminal")
        g.screenshot("02-zoom")
        g.click(77, 67)
        g.until(lambda: f"zoom window {terminal_id} = 0" in g.log(), "green button restores geometry")
        g.click(598, 732)
        g.until(lambda: '"clock"' in g.log(), "dock launches Clock")
        g.click(598, 732)
        g.click(598, 732)
        assert len(re.findall(r'peel: window \d+ "clock"', g.log())) == 1
        print("PASS repeated dock clicks keep one Clock", flush=True)
        g.screenshot("03-clock")
        g.click(481, 409)
        g.until(lambda: "clock: closed" in g.log(), "Clock close control")
        g.click(679, 732)
        g.until(lambda: '"About Orange OS"' in g.log(), "dock launches About")
        about_id = int(re.search(r'peel: window (\d+) "About', g.log())[1])
        # Zoom About and exercise a client button in transformed coordinates.
        g.click(505, 239)
        g.until(lambda: f"zoom window {about_id} = 1" in g.log(), "About zoom")
        # Original Done centre=(336,300); client area after zoom=(13,86,1254,591).
        g.click(1016, 611)
        g.until(lambda: f'closed window {about_id} "About Orange OS"' in g.log(), "scaled About Done hit testing")
        g.key("f11")
        g.until(lambda: g.pixel(200,250) != base, "show desktop repaint")
        empty = g.pixel(200, 250)
        assert empty != base
        g.screenshot("04-wallpaper")
        g.key("f11")
        g.until(lambda: g.pixel(200,250) == base, "restore desktop repaint")
        assert g.pixel(200, 250) == base
        print("PASS show/restore desktop", flush=True)
        g.key("f3")
        g.screenshot("05-overview")
        g.key("esc")
        g.key("f4")
        before = g.pixel(30, 500)
        g.click(1080, 183)
        g.until(lambda: "wallpaper 1" in g.log(), "Lagoon wallpaper")
        g.until(lambda: g.pixel(30, 500) != before, "wallpaper repaint")
        g.screenshot("06-appearance")
        g.click(970, 183)
        g.until(lambda: "wallpaper 0" in g.log(), "Daybreak wallpaper")
        g.until(lambda: g.pixel(30, 500) == before, "Daybreak repaint")
        g.key("esc")
        g.screenshot("07-final")
        # Minimized apps remain selectable from window overview.
        g.click(113, 131)
        g.until(lambda: g.pixel(200, 250) != base, "minimized for overview")
        g.key("f3")
        startup_windows = re.findall(r'peel: window \d+ "([^"]+)"', g.log())[:2]
        terminal_index = next(i for i,title in enumerate(startup_windows) if title.startswith("Squeeze"))
        g.click(450+310*terminal_index, 216)
        g.until(lambda: g.pixel(200, 250) == base, "overview restores minimized window")
        # Closing Welcome must not immediately respawn it; its dock icon does.
        welcome_id = int(re.search(r'peel: window (\d+) "Welcome"', g.log())[1])
        g.click(775, 131)
        g.until(lambda: f'closed window {welcome_id} "Welcome"' in g.log(), "Welcome closes")
        time.sleep(1)
        assert len(re.findall(r'peel: window \d+ "Welcome"', g.log())) == 1
        g.click(436, 732)
        g.until(lambda: len(re.findall(r'peel: window \d+ "Welcome"', g.log())) == 2, "Welcome relaunches from dock")
        # A close press followed by dragging off the control cancels the close.
        g.move(91, 131)
        g.monitor("mouse_button 1")
        time.sleep(.15)
        g.move(250, 250)
        g.monitor("mouse_button 0")
        time.sleep(.5)
        assert f'closed window {terminal_id} "Squeeze' not in g.log()
        print("PASS dragging off close cancels it", flush=True)
        # Drag a real window, then restore its original location.
        g.move(360, 131)
        g.monitor("mouse_button 1")
        time.sleep(.15)
        g.move(410, 181)
        g.monitor("mouse_button 0")
        g.until(lambda: g.pixel(200, 160) != (32, 35, 56), "window drag repaints old position")
        g.move(410, 181)
        g.monitor("mouse_button 1")
        time.sleep(.15)
        g.move(360, 131)
        g.monitor("mouse_button 0")
        g.until(lambda: g.pixel(200, 250) == base, "window drag returns content")
        # Files reads the real guest VFS; Trash is an honest read-only folder.
        g.click(360,732)
        g.until(lambda: '"Files"' in g.log() and 'files: listed /:' in g.log(),"Files launches and lists root")
        files_id=int(re.search(r'peel: window (\d+) "Files"',g.log())[1])
        g.click(330,370)
        g.until(lambda: 'files: listed /etc:' in g.log(),"Files browses System")
        g.click(520,333)
        g.until(lambda: 'files: preview /etc/motd' in g.log(),"Files previews real text")
        time.sleep(1)
        g.screenshot("09-files-preview")
        # Back closes preview first; another Back returns to the prior folder.
        g.click(295,238)
        g.click(295,238)
        g.until(lambda: g.log().count('files: listed /:')==2,"Files Back returns to root")
        g.click(281,189)
        g.until(lambda: f'closed window {files_id} "Files"' in g.log(),"Files closes")
        g.click(916,732)
        g.until(lambda: '"Trash"' in g.log() and 'files: listed /Trash: 0 entries' in g.log(),"Trash opens its actual empty folder")
        g.click(916,732)
        assert len(re.findall(r'peel: window \d+ "Trash"',g.log()))==1
        time.sleep(1)
        g.screenshot("10-trash")
        trash_id=int(re.search(r'peel: window (\d+) "Trash"',g.log())[1])
        g.click(281,189)
        g.until(lambda: f'closed window {trash_id} "Trash"' in g.log(),"Trash closes")
        # Welcome uses the shared icon system and opens real Appearance.
        g.click(1000,487)
        g.until(lambda: 'desktop: requested panel 6' in g.log(),"Welcome opens Appearance")
        time.sleep(1)
        g.screenshot("11-welcome-appearance")
        g.key("esc")
        assert "CPU EXCEPTION" not in g.log()
        print("Desktop interaction checks passed.", flush=True)
    finally:
        g.close()


if __name__ == "__main__":
    main()
