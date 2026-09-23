#!/usr/bin/env python3
"""Full-screen OrangeOS preview with readback and separately consented controls.

Build both components and the disk first. Closing QEMU stops the companion
and deletes its per-run credential. All guest disk writes are disposable.
"""
import os
import pathlib
import secrets
import signal
import shutil
import subprocess
import tempfile
import time
from vm_profile import resolve

ROOT = pathlib.Path(__file__).resolve().parents[1]


def main():
    profile = resolve()
    preview = ROOT / "build/OrangeOS Preview.app/Contents/MacOS/orange-qemu"
    if not preview.exists():
        subprocess.run(["sh", str(ROOT / "host/macos/bundle-preview.sh")], check=True)
    installed_qemu = shutil.which("qemu-system-x86_64")
    if installed_qemu is None:
        raise RuntimeError("Install QEMU before launching the preview")
    firmware = pathlib.Path(installed_qemu).resolve().parents[1] / "share/qemu"
    if not (firmware / "bios-256k.bin").exists():
        raise RuntimeError(f"QEMU firmware not found: {firmware}")
    output = pathlib.Path(tempfile.mkdtemp(prefix="orange-preview-", dir="/tmp"))
    token = output / "key"
    fd = os.open(token, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as stream:
        stream.write(secrets.token_hex(32))
    children = []

    def interrupted(signum, frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        channel = output / "agent.sock"
        with (output / "qemu.log").open("wb") as log:
            guest = subprocess.Popen([
                str(preview), "-L", str(firmware), "-M", "q35", *profile.qemu_args(),
                "-cdrom", str(ROOT / "build/orange.iso"), "-boot", "d",
                "-drive", f"id=disk0,file={ROOT / 'build/disk.img'},format=raw,if=none,snapshot=on",
                "-device", "ahci,id=ahci", "-device", "ide-hd,drive=disk0,bus=ahci.0",
                "-netdev", "user,id=n0", "-device", "e1000,netdev=n0",
                "-display", "cocoa,show-cursor=off,zoom-to-fit=on,zoom-interpolation=on,full-screen=on",
                "-serial", f"file:{output / 'serial.log'}",
                "-qmp", f"unix:{output / 'qmp.sock'},server=on,wait=off",
                "-device", "virtio-serial-pci,id=orangebus,disable-modern=on,max_ports=2",
                "-chardev", f"socket,id=orangechan,path={channel},server=on,wait=off",
                "-device", "virtserialport,bus=orangebus.0,nr=1,chardev=orangechan,name=org.orange.host",
                "-fw_cfg", f"name=opt/orange/session,file={token}",
                "-no-reboot"], stdout=log, stderr=subprocess.STDOUT)
        children.append(guest)
        with (output / "host.log").open("wb") as log:
            host = subprocess.Popen([
                str(ROOT / "build/OrangeOS Companion.app/Contents/MacOS/orange-host"),
                "--socket", str(channel), "--token-file", str(token), "--controls"],
                stdout=log, stderr=subprocess.STDOUT)
        children.append(host)
        print(f"Preview profile: {profile}", flush=True)
        print(f"Preview evidence: {output}; QEMU PID {guest.pid}", flush=True)
        disconnect_reported = False
        while guest.poll() is None:
            if host.poll() is not None and not disconnect_reported:
                print("Mac companion disconnected; the VM remains available.", flush=True)
                disconnect_reported = True
            time.sleep(.5)
        if guest.returncode:
            raise RuntimeError(f"QEMU exited with {guest.returncode}; see {output / 'qemu.log'}")
    except KeyboardInterrupt:
        pass
    finally:
        for proc in reversed(children):
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=5)
        token.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
