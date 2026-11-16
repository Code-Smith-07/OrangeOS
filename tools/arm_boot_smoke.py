#!/usr/bin/env python3
"""The Arm64 kernel, stage A0 (docs/design/015).

Build: zig build arm

Boots zig-out/bin/kernel-arm64.elf on QEMU's Arm "virt" machine and checks
what the kernel reports and what is on the screen:

  * it reads the device tree (memory size and processor count match what
    QEMU was given);
  * a synchronous exception is taken and returned from;
  * the timer counts 200 ticks in 200 ms;
  * every processor starts and takes timer ticks;
  * the virtual GPU shows the boot picture (a screenshot is taken through
    QEMU and its colours are checked);
  * the same boot started at hypervisor level (EL2), as on real hardware.

Run emulated everywhere. On an Arm host with a hypervisor (Apple Silicon,
or Arm Linux with KVM) it also runs native, and prints how much faster the
kernel's speed test is: that number is the reason for the port.
"""
import os
import pathlib
import platform
import re
import socket
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
KERNEL = ROOT / "zig-out/bin/kernel-arm64.elf"
CANVAS = (0x14, 0x16, 0x1C)
ORANGE = (0xFF, 0x8A, 0x1F)


def native_accel():
    if platform.machine() not in ("arm64", "aarch64"):
        return None
    if sys.platform == "darwin":
        out = subprocess.run(["qemu-system-aarch64", "-accel", "help"], capture_output=True, text=True).stdout
        return "hvf" if "hvf" in out else None
    return "kvm" if os.access("/dev/kvm", os.W_OK) else None


def boot(accel, cpus=4, memory=1024, machine="virt,gic-version=3", timeout=90):
    """Returns (serial log, screenshot path or None)."""
    work = pathlib.Path(tempfile.mkdtemp(prefix="orange-arm-"))
    log, monitor, shot = work / "serial.log", work / "monitor.sock", work / "screen.ppm"
    proc = subprocess.Popen([
        "qemu-system-aarch64", "-M", machine, "-accel", accel, "-cpu", "max" if accel == "tcg" else "host",
        "-smp", str(cpus), "-m", str(memory), "-display", "none",
        "-global", "virtio-mmio.force-legacy=false", "-device", "virtio-gpu-device",
        "-serial", f"file:{log}", "-monitor", f"unix:{monitor},server,nowait",
        "-kernel", str(KERNEL),
    ], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        deadline = time.time() + timeout
        text = ""
        while time.time() < deadline:
            text = log.read_text(errors="replace") if log.exists() else ""
            if "stage A0 complete" in text or "KERNEL PANIC" in text or proc.poll() is not None:
                break
            time.sleep(0.2)
        if proc.poll() is None and "stage A0 complete" in text:
            with socket.socket(socket.AF_UNIX) as s:
                s.connect(str(monitor))
                s.sendall(f"screendump {shot}\n".encode())
                time.sleep(1.0)
        if proc.poll() is not None:
            text += "\n[QEMU exited: " + proc.stderr.read().decode(errors="replace").strip() + "]"
        return text, (shot if shot.exists() else None)
    finally:
        if proc.poll() is None:
            proc.kill()
        proc.wait()


def pixels(ppm):
    data = ppm.read_bytes()
    parts = data.split(b"\n", 3)
    assert parts[0] == b"P6", "screenshot is not a PPM"
    width, height = (int(n) for n in parts[1].split())
    return width, height, parts[3]


def check(label, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + label + (f": {detail}" if detail and not ok else ""), flush=True)
    if not ok:
        raise SystemExit(1)


def number(pattern, text):
    m = re.search(pattern, text)
    return int(m.group(1)) if m else None


def run(name, accel, cpus=4, memory=1024, machine="virt,gic-version=3"):
    text, shot = boot(accel, cpus, memory, machine)
    tail = text[-600:]
    check(f"{name}: the kernel boots to the end of stage A0", "stage A0 complete" in text and "KERNEL PANIC" not in text, tail)
    check(f"{name}: the device tree gives {memory} MB and {cpus} processors",
          f"{memory} MB of memory, {cpus} processors" in text, tail)
    check(f"{name}: an exception is taken and returned from", "exceptions ok" in text, tail)
    check(f"{name}: the timer counts 200 ticks in 200 ms", re.search(r"timer \d+ ticks in 200 ms from \d+ interrupts \(ok\)", text), tail)
    check(f"{name}: all {cpus} processors start and take ticks",
          f"{cpus} of {cpus} processors online, {cpus} taking timer ticks (ok)" in text, tail)
    check(f"{name}: the virtual GPU accepts every frame", re.search(r"display 1280x800, .*\(ok\)", text), tail)
    check(f"{name}: a screenshot could be taken", shot is not None)
    width, height, data = pixels(shot)

    def at(x, y):
        i = (y * width + x) * 3
        return tuple(data[i:i + 3])
    check(f"{name}: the screen is 1280x800 with the dark canvas in the corner", (width, height) == (1280, 800) and at(8, 8) == CANVAS, f"{width}x{height} {at(8, 8)}")
    check(f"{name}: the orange is drawn in the middle", at(660, 350) == ORANGE, str(at(660, 350)))
    white = sum(1 for x in range(480, 800) for y in range(450, 482) if at(x, y) == (0xF4, 0xF4, 0xF6))
    check(f"{name}: the name is written under it", white > 1500, f"{white} text pixels")
    return {
        "speed_ms": number(r"speed test counted \d+ primes in (\d+) ms", text),
        "frames": number(r"\((\d+) a second\)", text),
        "interrupts": number(r"from (\d+) interrupts", text),
    }


def main():
    if not KERNEL.exists():
        raise SystemExit("build first: zig build arm")
    emulated = run("emulated", "tcg")
    run("emulated, 1 processor, 512 MB", "tcg", cpus=1, memory=512)
    run("emulated, started at hypervisor level", "tcg", cpus=2, machine="virt,gic-version=3,virtualization=on")
    accel = native_accel()
    if accel is None:
        print("SKIP native: this host has no Arm hypervisor (not an Arm computer)")
        print(f"Emulated: speed test {emulated['speed_ms']} ms, {emulated['frames']} frames a second")
        return
    native = run(f"native ({accel})", accel)
    run(f"native ({accel}), 8 processors", accel, cpus=8, memory=2048)
    check("native: every timer interrupt arrives on time (200 of 200)", 198 <= native["interrupts"] <= 202, str(native["interrupts"]))
    check("native is at least 3 times faster than emulated", native["speed_ms"] * 3 <= emulated["speed_ms"],
          f"{native['speed_ms']} ms against {emulated['speed_ms']} ms")
    print()
    print(f"Speed test: {emulated['speed_ms']} ms emulated, {native['speed_ms']} ms native "
          f"({emulated['speed_ms'] / max(native['speed_ms'], 1):.1f} times faster)")
    print(f"Full-screen frames drawn and shown: {emulated['frames']} a second emulated, {native['frames']} a second native")
    print("Arm64 stage A0 checks passed.")


if __name__ == "__main__":
    main()
