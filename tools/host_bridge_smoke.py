#!/usr/bin/env python3
"""Mac companion ↔ real OrangeOS guest, no network or physical-device changes.

Build: swift build --package-path host/macos; zig build; scripts/mkdisk.sh
Every QEMU disk write goes to a disposable overlay. Token is deleted on exit;
logs remain in a private temporary directory. Only owned child PIDs are stopped.
"""
import json
import os
import pathlib
import secrets
import signal
import socket
import subprocess
import tempfile
import time
from desktop_smoke import Guest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def run():
    output = pathlib.Path(tempfile.mkdtemp(prefix="orange-host-", dir="/tmp"))
    token = output / "key"
    secret = secrets.token_hex(32)
    fd = os.open(token, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as stream:
        stream.write(secret)
    serial = output / "serial.log"
    channel = output / "agent.sock"
    children = []
    ui = None
    print(f"Evidence: {output}", flush=True)

    def launch_host():
        with (output / "host.log").open("ab") as log:
            proc = subprocess.Popen([str(ROOT / "host/macos/.build/debug/orange-host"),
                                     "--socket", str(channel), "--token-file", str(token)],
                                    stdout=log, stderr=subprocess.STDOUT)
        children.append(proc)
        return proc

    def stop(proc):
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5)

    def log():
        return serial.read_text(errors="replace") if serial.exists() else ""

    def until(predicate, label, timeout=60):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                print(f"PASS {label}", flush=True)
                return
            if guest.poll() is not None:
                raise RuntimeError((output / "qemu.log").read_text())
            if "CPU EXCEPTION" in log() or "kernel panic" in log():
                raise AssertionError(f"Guest fault during {label}; see {serial}")
            time.sleep(.1)
        raise AssertionError(f"Timeout: {label}; see {output}")

    try:
        with (output / "qemu.log").open("wb") as qlog:
            guest = subprocess.Popen([
                "qemu-system-x86_64", "-M", "q35", "-m", "3G", "-smp", "2",
                "-cdrom", str(ROOT / "build/orange.iso"), "-boot", "d",
                "-drive", f"id=disk0,file={ROOT / 'build/disk.img'},format=raw,if=none,snapshot=on",
                "-device", "ahci,id=ahci", "-device", "ide-hd,drive=disk0,bus=ahci.0",
                "-nic", "none", "-display", "none", "-serial", f"file:{serial}",
                "-qmp", f"unix:{output / 'qmp.sock'},server=on,wait=off",
                "-device", "virtio-serial-pci,id=orangebus,disable-modern=on,max_ports=2",
                "-chardev", f"socket,id=orangechan,path={channel},server=on,wait=off",
                "-device", "virtserialport,bus=orangebus.0,nr=1,chardev=orangechan,name=org.orange.host",
                "-fw_cfg", f"name=opt/orange/session,file={token}",
                "-no-reboot", "-no-shutdown"], stdout=qlog, stderr=subprocess.STDOUT)
        children.append(guest)
        host = launch_host()
        until(lambda: "host-probe: PASS all operations denied" in log(), "ordinary app denied all bridge operations")
        until(lambda: "host-agent: PASS invalid buffers rejected" in log(), "invalid guest buffers rejected")
        until(lambda: "host-agent: PASS sound mailbox bounds and authority" in log(), "sound mailbox validates buffers and separates sender/agent roles")
        until(lambda: "host-agent: pong" in log(), "authenticated round trip and heartbeat")
        until(lambda: "host-probe: PASS snapshot publication denied" in log(), "ordinary apps cannot forge hardware state")
        until(lambda: "host-probe: PASS sound command access denied" in log(), "ordinary apps cannot submit or acknowledge sound commands")
        until(lambda: "host-probe: PASS C entry frame sentinel" in log(), "C entry stack has a readable return sentinel")
        until(lambda: "host-agent: PASS snapshot bounds and pointers rejected" in log(), "snapshot user pointers and bounds validated")
        snapshot_line = next(line for line in log().splitlines() if line.startswith("host-agent: snapshot "))
        snapshot = json.loads(snapshot_line.removeprefix("host-agent: snapshot "))
        assert snapshot["provider"] == "macos" and abs(snapshot["unix_seconds"] - time.time()) < 15
        assert isinstance(snapshot["timezone"], str) and snapshot["timezone"]
        print(f"PASS real Mac snapshot: timezone={snapshot['timezone']}", flush=True)
        def hardware():
            return [json.loads(line.removeprefix("host-agent: hardware ")) for line in log().splitlines() if line.startswith("host-agent: hardware ")]
        until(lambda: any(x["freshness"] == "fresh" for x in hardware()), "fresh host hardware snapshot reaches guest")
        observed = hardware()[-1]
        assert abs(observed["observed_unix_seconds"] - time.time()) < 8
        for name in ("wifi", "bluetooth", "brightness", "audio", "battery"):
            assert observed[name]["source"] and observed[name]["status"] and observed[name]["permission"]
        direct = json.loads(subprocess.check_output([str(ROOT / "host/macos/.build/debug/orange-host"), "--probe-hardware"]))
        for name in ("wifi", "bluetooth", "brightness", "audio", "battery"):
            assert observed[name]["status"] == direct[name]["status"], f"{name} status mismatch"
            assert observed[name].get("power") == direct[name].get("power"), f"{name} power mismatch"
            if "level" in observed[name]:
                assert abs(observed[name]["level"] - direct[name]["level"]) < .03, f"{name} level mismatch"
        assert observed["audio"]["control"] is False
        print("PASS guest hardware matches direct host probe (no fabricated off/zero values)", flush=True)
        # Reuse the desktop corpus's QMP interactions on this network-disabled,
        # bridge-enabled guest, without creating a second VM.
        ui = Guest.__new__(Guest)
        ui.output, ui.serial, ui.process = output, serial, guest
        ui.sock = socket.socket(socket.AF_UNIX)
        ui.sock.settimeout(15)
        ui.sock.connect(str(output / "qmp.sock"))
        ui.stream = ui.sock.makefile("rwb", buffering=0)
        ui.stream.readline()
        ui.command("qmp_capabilities")
        ui.x, ui.y, ui.scale = 640, 400, 2
        until(lambda: '"Welcome"' in log() and "squeeze: window" in log(), "desktop ready")
        time.sleep(1)
        ui.key("f4")
        ui.click(1050, 458)
        until(lambda: "hardware: view snapshot" in log(), "native hardware window displays live snapshot")
        ui.move(750, 80)
        time.sleep(.5)
        baseline = ui.region(390, 181, 480, 330)
        offset = len(log())
        for _ in range(3):
            ui.click(825, 292)
        ui.move(750, 80)
        time.sleep(2.5)
        assert "hardware: view" not in log()[offset:], "no-op clicks or snapshot timestamps caused repaint"
        assert ui.region(390, 181, 480, 330) == baseline, "hardware view changed on no-op interactions"
        print("PASS hardware no-op clicks, hover and timestamp-only refresh do not repaint", flush=True)
        ui.screenshot("hardware-connected")
        ui.key("f4")
        ui.click(1050, 458)
        assert log().count('"Control Center"') == 1, "hardware launcher opened duplicate window"
        print("PASS hardware launcher focuses existing window", flush=True)
        offset = len(log())
        stop(host)
        until(lambda: "hardware: view unavailable" in log()[offset:], "disconnect clears guest UI state", 12)
        ui.screenshot("hardware-disconnected")
        assert ui.region(390, 181, 480, 330) != baseline
        offset = len(log())
        host = launch_host()
        until(lambda: "host-agent: pong" in log()[offset:], "companion restart re-authenticates and resumes heartbeat", 20)
        assert "host-agent: authenticated" in log()[offset:]
        assert "host-agent: hardware " in log()[offset:]
        until(lambda: "hardware: view snapshot" in log()[offset:], "reconnect restores guest hardware view", 12)
        ui.move(750, 80)
        until(lambda: ui.region(390, 181, 480, 330) == baseline, "restored hardware pixels match original")
        offset = len(log())
        host.send_signal(signal.SIGSTOP)
        try:
            until(lambda: "hardware: view unavailable" in log()[offset:], "unresponsive companion cannot leave live-looking readings", 12)
            # Kernel publication expiry can clear the UI before the currently
            # outstanding RPC reaches its separate five-second deadline.
            until(lambda: "host-agent: session failed" in log()[offset:], "stalled RPC reaches its response deadline", 8)
        finally:
            if host.poll() is None: host.send_signal(signal.SIGCONT)
        stop(host)
        offset = len(log())
        host = launch_host()
        until(lambda: "hardware: view snapshot" in log()[offset:], "timed-out session recovers after fresh authentication", 20)
        assert "host-agent: authenticated" in log()[offset:]
        ui.click(410, 161)
        until(lambda: "hardware: closed" in log(), "hardware close button exits application")
        assert "PANIC" not in log()
        assert secret not in log() and secret not in (output / "host.log").read_text()
        print("PASS no credential in logs; no network device attached", flush=True)
    finally:
        if ui is not None:
            if hasattr(ui, "stream"): ui.stream.close()
            ui.sock.close()
        for proc in reversed(children):
            stop(proc)
        token.unlink(missing_ok=True)


if __name__ == "__main__":
    run()
