#!/usr/bin/env python3
"""Settings, hardware control, notifications and the lock screen
(docs/design/014: M5, M6 and M8), in a real desktop.

Build: zig build -Ddesktop-profile && scripts/mkdisk.sh

The Mac companion is replaced here by a stand-in that speaks the same wire
protocol (ORHB v1) and keeps its own pretend hardware. So the switches and
sliders in Settings are driven all the way down (Settings, the kernel's
mailbox, the guest agent, the wire) and every command is checked, without
ever touching this Mac's real Wi-Fi, Bluetooth, sound or screen. The real
companion's side is covered by `swift test --package-path host/macos` and
its `--verify-*-write` checks.

  1. Wi-Fi and Bluetooth switches send power commands and follow the
     answer; a refused command is reported, not hidden.
  2. Sound and Display sliders send the level chosen.
  3. A low battery reported by the companion raises a real notification.
  4. Appearance changes the theme and Reduce motion (and they are saved).
  5. A password is set; Lock Screen locks; a wrong password is refused and
     the right one unlocks; after a reboot the system starts locked.
"""
import json
import os
import pathlib
import re
import secrets
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

sys.path.insert(0, os.path.dirname(__file__))
from desktop_smoke import Guest, frame_of  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[1]


class StandInCompanion(threading.Thread):
    """Answers the guest agent like the Mac companion, from pretend state."""

    def __init__(self, path, token):
        super().__init__(daemon=True)
        self.path, self.token = path, token
        self.state = {"wifi": True, "bluetooth": True, "volume": 25, "brightness": 50, "battery": 15}
        self.commands = []
        self.refuse_next = False
        self.stop = False

    def hardware(self):
        s = self.state
        return {
            "schema": 1, "provider": "macos", "observed_unix_seconds": int(time.time()), "freshness": "fresh",
            "wifi": {"source": "CoreWLAN.powerOn", "status": "available", "permission": "not_required_for_probe",
                     "power": s["wifi"], "control": True, "note": "stand-in"},
            "bluetooth": {"source": "IOBluetooth.powerState", "status": "available", "permission": "allowed",
                          "power": s["bluetooth"], "connected": 2, "control": True, "note": "stand-in"},
            "brightness": {"source": "DisplayServices", "status": "available", "permission": "allowed",
                           "level": s["brightness"] / 100, "device": 1, "control": True, "note": "stand-in"},
            "audio": {"source": "CoreAudio", "status": "available", "permission": "allowed",
                      "level": s["volume"] / 100, "device": 124, "muted": False, "control": True, "note": "stand-in"},
            "battery": {"source": "IOPowerSources", "status": "available", "permission": "not_required_for_probe",
                        "level": s["battery"] / 100, "power": False, "note": "stand-in"},
        }

    def reply(self, method, request, payload):
        if method == 1:
            assert payload == self.token, "the guest sent the wrong session key"
            return 1, {"status": "ready", "protocol": 1, "mode": "host_consent"}
        if method == 2:
            return 1, {"provider": "macos", "mode": "host_consent", "operations": ["host.hardware"]}
        if method == 3:
            return 1, {"provider": "macos", "unix_seconds": int(time.time()), "timezone": "UTC", "utc_offset_seconds": 0, "os_version": "stand-in"}
        if method == 4:
            return 1, {"status": "pong"}
        if method == 5:
            return 1, self.hardware()
        if 6 <= method <= 9 and len(payload) == 12:
            operation, value, device = struct.unpack("<III", payload)
            self.commands.append((method, value, device))
            if self.refuse_next:
                self.refuse_next = False
                return 2, {"error": "permission_denied"}
            key = {6: "volume", 7: "brightness", 8: "wifi", 9: "bluetooth"}[method]
            self.state[key] = bool(value) if method >= 8 else value
            return 1, {"status": "applied"}
        return 2, {"error": "method_denied"}

    def run(self):
        while not self.stop:
            try:
                sock = socket.socket(socket.AF_UNIX)
                sock.connect(self.path)
            except OSError:
                time.sleep(.2)
                continue
            buf = b""
            try:
                while not self.stop:
                    data = sock.recv(4096)
                    if not data:
                        break
                    buf += data
                    while len(buf) >= 16:
                        magic, version, flags, method, request, length = struct.unpack("<4sBBHII", buf[:16])
                        assert magic == b"ORHB" and version == 1 and flags == 0
                        if len(buf) < 16 + length:
                            break
                        payload, buf = buf[16:16 + length], buf[16 + length:]
                        out_flags, body = self.reply(method, request, payload)
                        text = json.dumps(body, separators=(",", ":"), sort_keys=True).encode()
                        sock.sendall(struct.pack("<4sBBHII", b"ORHB", 1, out_flags, method, request, len(text)) + text)
            except OSError:
                pass
            finally:
                sock.close()


KEYS = {" ": "spc", "-": "minus"}


def typed(g, text):
    for ch in text:
        g.key(KEYS.get(ch, ch))


def spotlight(g, text):
    before = g.log().count("desktop: spotlight open")
    g.key("alt-spc")
    g.until(lambda: g.log().count("desktop: spotlight open") > before, "Spotlight opens")
    typed(g, text)
    time.sleep(.8)
    g.key("ret")


def boot(work, image, token_file):
    channel = work / "agent.sock"
    channel.unlink(missing_ok=True)
    g = Guest(extra_args=(
        "-drive", f"id=data0,file={image},format=raw,if=none", "-device", "ide-hd,drive=data0,bus=ahci.1",
        "-device", "virtio-serial-pci,id=orangebus,disable-modern=on,max_ports=2",
        "-chardev", f"socket,id=orangechan,path={channel},server=on,wait=off",
        "-device", "virtserialport,bus=orangebus.0,nr=1,chardev=orangechan,name=org.orange.host",
        "-fw_cfg", f"name=opt/orange/session,file={token_file}"))
    g.scale = 2
    return g, channel


def main():
    work = pathlib.Path(tempfile.mkdtemp(prefix="orange-settings-", dir="/tmp"))
    image = work / "data.img"
    subprocess.run([sys.executable, str(ROOT / "tools/mkdata.py"), str(image), "--size-mib", "64"], check=True)
    token = secrets.token_hex(32).encode()
    token_file = work / "key"
    token_file.write_bytes(token)
    token_file.chmod(0o600)

    g, channel = boot(work, image, token_file)
    mac = StandInCompanion(str(channel), token)
    mac.start()
    try:
        g.until(lambda: '"Welcome"' in g.log() and "squeeze: window" in g.log(), "boot to desktop", 90)
        g.until(lambda: "desktop: host indicators fresh" in g.log(), "the companion's readings reach the menu bar", 40)
        # 3. The stand-in reports 15% on battery: OrangeOS warns, once.
        g.until(lambda: 'desktop: notification "Battery Low" from Control Center' in g.log(), "a low battery raises a notification", 20)
        time.sleep(.6)
        g.screenshot("01-battery-low-banner")
        print("PASS a low battery on the Mac raises a real notification", flush=True)

        spotlight(g, "settings")
        g.until(lambda: "settings: painted Wi-Fi" in g.log(), "Settings opens", 30)
        wid = int(re.search(r'peel: window (\d+) "Settings"', g.log())[1])
        time.sleep(1.5)
        fx, fy, fw, fh, cx, cy = frame_of(g, wid)

        def pane(i):
            g.click(cx + 107, cy + 71 + 32 * i)
            time.sleep(.8)

        toggle = (cx + 739, cy + 90)

        def results():
            return re.findall(r"settings: device command (\d+) result (-?\d+)", g.log())

        # 1. Wi-Fi off and on again, through every layer.
        g.screenshot("02-settings-wifi")
        g.click(*toggle)
        g.until(lambda: results() == [("1", "0")], "the Wi-Fi switch reaches the companion")
        assert mac.commands[-1] == (8, 0, 1) and mac.state["wifi"] is False, mac.commands
        time.sleep(3)  # the next reading shows it off
        g.click(*toggle)
        g.until(lambda: len(results()) == 2 and mac.state["wifi"] is True, "the switch turns it back on")
        assert mac.commands[-1] == (8, 1, 1)
        # A refusal by the companion is shown, and nothing is switched.
        time.sleep(3)
        mac.refuse_next = True
        g.click(*toggle)
        g.until(lambda: results()[-1] == ("1", "-13"), "a refused command is reported")
        assert mac.state["wifi"] is True
        time.sleep(.5)
        g.screenshot("03-wifi-refused")
        print("PASS the Wi-Fi switch sends off, then on; a refusal is reported", flush=True)

        pane(1)
        g.until(lambda: "settings: painted Bluetooth" in g.log(), "the Bluetooth pane")
        time.sleep(1.5)
        g.click(*toggle)
        g.until(lambda: results()[-1] == ("2", "0") and mac.state["bluetooth"] is False, "the Bluetooth switch reaches the companion", 20)
        assert mac.commands[-1] == (9, 0, 1)
        print("PASS the Bluetooth switch sends its own command", flush=True)

        # 2. Sliders: click the track at 70% and at 30%.
        def slider_at(level):
            return cx + 520 + 184 * level // 100, cy + 90

        pane(3)
        g.until(lambda: "settings: painted Sound" in g.log(), "the Sound pane")
        time.sleep(1)
        g.click(*slider_at(70))
        g.until(lambda: results()[-1] == ("3", "0"), "the volume slider reaches the companion")
        assert mac.commands[-1][0] == 6 and abs(mac.commands[-1][1] - 70) <= 2 and mac.commands[-1][2] == 124, mac.commands[-1]
        time.sleep(2.5)
        g.screenshot("04-settings-sound")
        pane(4)
        g.until(lambda: "settings: painted Display" in g.log(), "the Display pane")
        time.sleep(1)
        g.click(*slider_at(30))
        g.until(lambda: results()[-1] == ("4", "0"), "the brightness slider reaches the companion")
        assert mac.commands[-1][0] == 7 and abs(mac.commands[-1][1] - 30) <= 2 and mac.commands[-1][2] == 1, mac.commands[-1]
        print(f"PASS sliders set volume to {mac.state['volume']}% and brightness to {mac.state['brightness']}%", flush=True)

        # 4. Appearance.
        pane(6)
        g.until(lambda: "settings: painted Appearance" in g.log(), "the Appearance pane")
        g.click(cx + 724, cy + 90)
        g.until(lambda: "desktop: theme 2 Midnight Aurora" in g.log(), "Settings changes the theme")
        g.click(cx + 739, cy + 134)
        g.until(lambda: "desktop: reduce motion on" in g.log(), "Settings turns Reduce motion on")
        g.until(lambda: "preferences saved, theme 2, reduce motion 1" in g.log(), "both are saved")
        time.sleep(.6)
        g.screenshot("05-settings-appearance")
        g.click(cx + 580, cy + 90)
        g.until(lambda: "desktop: theme 0 Coastal Glass" in g.log(), "and back to Coastal")
        print("PASS Appearance in Settings changes and saves the theme and Reduce motion", flush=True)

        # 5. A password, then the lock screen.
        pane(7)
        g.until(lambda: "settings: painted Lock Screen" in g.log(), "the Lock Screen pane")
        g.click(cx + 645, cy + 90)  # the name field
        typed(g, "vishwa")
        g.key("tab")
        typed(g, "orange1")
        g.key("tab")
        typed(g, "orange2")
        g.key("ret")
        time.sleep(1.5)
        assert "settings: password set" not in g.log(), "two different passwords were accepted"
        g.screenshot("06-passwords-differ")
        g.key("backspace")
        typed(g, "1")
        g.key("ret")
        g.until(lambda: "settings: password set" in g.log(), "the password is set", 30)
        g.until(lambda: "desktop: account found" in g.log(), "Peel reads the new account")
        print("PASS a password is set only when both entries match", flush=True)
        # Lock after one minute without input: choose it, then wait.
        time.sleep(1)
        g.click(cx + 580, cy + 322)
        g.until(lambda: "desktop: lock after 1 minutes" in g.log(), "Lock after 1 minute is chosen")
        g.until(lambda: "desktop: locked (no input)" in g.log(), "the screen locks itself after a minute", 80)
        typed(g, "orange1")
        g.key("ret")
        g.until(lambda: "desktop: unlocked" in g.log(), "the password unlocks it", 30)
        print("PASS the screen locks by itself after a minute without input", flush=True)
        spotlight(g, "lock")
        g.until(lambda: "desktop: locked (the Orange menu)" in g.log(), "Lock Screen locks")
        time.sleep(1)
        g.screenshot("07-locked")
        # Nothing behind the lock reacts: a click where Settings' sidebar was.
        painted = g.log().count("settings: painted")
        g.click(cx + 107, cy + 71)
        typed(g, "wrong")
        g.key("ret")
        g.until(lambda: "desktop: wrong password (1)" in g.log(), "a wrong password is refused", 30)
        assert g.log().count("settings: painted") == painted, "a locked screen passed input to an app"
        time.sleep(.5)
        g.screenshot("08-wrong-password")
        typed(g, "orange1")
        g.key("ret")
        g.until(lambda: g.log().count("desktop: unlocked") == 2, "the right password unlocks", 30)
        print("PASS the lock screen refuses a wrong password and opens for the right one", flush=True)
        assert "orange1" not in g.log() and "orange2" not in g.log(), "a password reached the log"
        time.sleep(4)  # /data's periodic save
        g.monitor("stop")
    finally:
        mac.stop = True
        g.close()

    g, channel = boot(work, image, token_file)
    try:
        g.until(lambda: "desktop: locked (start-up)" in g.log(), "the system starts locked after a reboot", 90)
        g.until(lambda: "squeeze: window" in g.log(), "the desktop is running behind the lock", 60)
        time.sleep(2)
        g.screenshot("09-login")
        typed(g, "orange1")
        g.key("ret")
        g.until(lambda: "desktop: unlocked" in g.log(), "the password signs in", 30)
        print("PASS after a reboot OrangeOS starts at the lock screen and the password signs in", flush=True)
        saved = (work / "data.img").read_bytes()
        assert b"orange1" not in saved, "the password itself is on the data disk"
        assert b"name=vishwa" in saved and b"hash=" in saved
        print("PASS the data disk holds the name and a salted hash, never the password", flush=True)
    finally:
        g.close()
    print(f"Settings, hardware control and lock checks passed; evidence in {work} and the guest output folders", flush=True)


if __name__ == "__main__":
    main()
