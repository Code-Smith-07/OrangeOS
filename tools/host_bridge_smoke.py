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
import subprocess
import tempfile
import time

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
                "-device", "virtio-serial-pci,id=orangebus,disable-modern=on,max_ports=2",
                "-chardev", f"socket,id=orangechan,path={channel},server=on,wait=off",
                "-device", "virtserialport,bus=orangebus.0,nr=1,chardev=orangechan,name=org.orange.host",
                "-fw_cfg", f"name=opt/orange/session,file={token}",
                "-no-reboot", "-no-shutdown"], stdout=qlog, stderr=subprocess.STDOUT)
        children.append(guest)
        host = launch_host()
        until(lambda: "host-probe: PASS all operations denied" in log(), "ordinary app denied all bridge operations")
        until(lambda: "host-agent: PASS invalid buffers rejected" in log(), "invalid guest buffers rejected")
        until(lambda: "host-agent: pong" in log(), "authenticated round trip and heartbeat")
        snapshot_line = next(line for line in log().splitlines() if line.startswith("host-agent: snapshot "))
        snapshot = json.loads(snapshot_line.removeprefix("host-agent: snapshot "))
        assert snapshot["provider"] == "macos" and abs(snapshot["unix_seconds"] - time.time()) < 15
        assert isinstance(snapshot["timezone"], str) and snapshot["timezone"]
        print(f"PASS real Mac snapshot: timezone={snapshot['timezone']}", flush=True)
        offset = len(log())
        stop(host)
        time.sleep(.5)  # allow port-close generation to reach the guest
        host = launch_host()
        until(lambda: "host-agent: pong" in log()[offset:], "companion restart re-authenticates and resumes heartbeat", 20)
        assert "host-agent: authenticated" in log()[offset:]
        assert "PANIC" not in log()
        assert secret not in log() and secret not in (output / "host.log").read_text()
        print("PASS no credential in logs; no network device attached", flush=True)
    finally:
        for proc in reversed(children):
            stop(proc)
        token.unlink(missing_ok=True)


if __name__ == "__main__":
    run()
