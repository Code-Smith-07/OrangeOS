#!/usr/bin/env python3
"""Orange OS on Arm64 (docs/design/015, stages A0 to A2).

Builds what it needs itself (zig build arm, scripts/mkdisk-arm.sh), boots it
on QEMU's Arm "virt" machine and checks:

  1. The system: the kernel boots on several machine shapes (4 and 1
     processors, started at hypervisor level as real hardware does, and 8
     processors where the host can run Arm natively), mounts its disk,
     starts init and the shell; the virtual GPU shows the boot picture
     (checked in a screenshot); commands typed on the serial console run
     programs from the disk, Zig and C alike.
  2. The runtime checks: an image built with -Druntime-test runs the
     kernel's own memory and scheduler tests, then init runs every program
     check (faults, threads, vector registers, signals, musl, ...). Run
     natively and emulated, and the times compared: that ratio is the
     reason for the port.

Leaves the ordinary (shell) image built, so scripts/run-arm.sh works after.
"""
import os
import pathlib
import platform
import re
import select
import socket
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
KERNEL = ROOT / "zig-out/bin/kernel-arm64.elf"
DISK = ROOT / "build/arm64-disk.img"
DISK_ADDR = 0x48000000
CANVAS = (0x14, 0x16, 0x1C)
ORANGE = (0xFF, 0x8A, 0x1F)


def native_accel():
    if platform.machine() not in ("arm64", "aarch64"):
        return None
    if sys.platform == "darwin":
        out = subprocess.run(["qemu-system-aarch64", "-accel", "help"], capture_output=True, text=True).stdout
        return "hvf" if "hvf" in out else None
    return "kvm" if os.access("/dev/kvm", os.W_OK) else None


def build(runtime_test):
    args = ["zig", "build", "arm"] + (["-Druntime-test"] if runtime_test else [])
    subprocess.run(args, cwd=ROOT, check=True)
    subprocess.run(["sh", "scripts/mkdisk-arm.sh"], cwd=ROOT, check=True, stdout=subprocess.DEVNULL)


class Machine:
    """One QEMU run: serial on pipes, monitor on a socket."""

    def __init__(self, accel, cpus=4, memory=1024, machine="virt,gic-version=3"):
        self.work = pathlib.Path(tempfile.mkdtemp(prefix="orange-arm-"))
        self.monitor_path = self.work / "monitor.sock"
        self.text = ""
        self.started = time.time()
        self.proc = subprocess.Popen([
            "qemu-system-aarch64", "-M", machine, "-accel", accel, "-cpu", "max" if accel == "tcg" else "host",
            "-smp", str(cpus), "-m", str(memory), "-display", "none",
            "-global", "virtio-mmio.force-legacy=false", "-device", "virtio-gpu-device",
            "-device", f"loader,file={DISK},addr={DISK_ADDR:#x},force-raw=on",
            "-append", f"ramdisk={DISK_ADDR:#x},{DISK.stat().st_size}",
            "-serial", "stdio", "-monitor", f"unix:{self.monitor_path},server,nowait",
            "-kernel", str(KERNEL),
        ], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    def pump(self, seconds):
        end = time.time() + seconds
        while time.time() < end and self.proc.poll() is None:
            ready, _, _ = select.select([self.proc.stdout], [], [], 0.1)
            if ready:
                self.text += os.read(self.proc.stdout.fileno(), 65536).decode(errors="replace")

    def until(self, test, seconds):
        end = time.time() + seconds
        while time.time() < end and self.proc.poll() is None:
            if test(self.text):
                return True
            self.pump(0.2)
        return test(self.text)

    def type(self, line, wait_for, seconds=20):
        mark = len(self.text)
        for c in (line + "\n").encode():
            self.proc.stdin.write(bytes([c]))
            self.proc.stdin.flush()
            time.sleep(0.01)
        self.until(lambda t: wait_for in t[mark:], seconds)
        return self.text[mark:]

    def screenshot(self):
        shot = self.work / "screen.ppm"
        with socket.socket(socket.AF_UNIX) as s:
            s.connect(str(self.monitor_path))
            s.sendall(f"screendump {shot}\n".encode())
            time.sleep(1.0)
        return shot if shot.exists() else None

    def close(self):
        if self.proc.poll() is None:
            self.proc.kill()
        self.proc.wait()


def check(label, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + label + (f": {detail}" if detail and not ok else ""), flush=True)
    if not ok:
        raise SystemExit(1)


PROMPT = "orange\x1b[0m:/$ "


def system_checks(name, accel, cpus=4, memory=1024, machine="virt,gic-version=3", commands=True):
    m = Machine(accel, cpus, memory, machine)
    try:
        booted = m.until(lambda t: PROMPT in t or "KERNEL PANIC" in t, 300)
        tail = m.text[-800:]
        check(f"{name}: boots to the shell", booted and "KERNEL PANIC" not in m.text, tail)
        check(f"{name}: the device tree gives {memory} MB and {cpus} processors",
              f"{memory} MB of memory, {cpus} processors" in m.text, tail)
        check(f"{name}: all {cpus} processors start", f"SMP: {cpus} of {cpus} processors online" in m.text, tail)
        check(f"{name}: the disk is mounted from memory", "mounted CitrusFS on ram0p2" in m.text, tail)
        check(f"{name}: init starts the shell", "Seed" in m.text and "juice started" in m.text, tail)
        if not commands:
            return
        shot = m.screenshot()
        check(f"{name}: a screenshot could be taken", shot is not None)
        data = shot.read_bytes()
        header, width_height, _, pixels = data.split(b"\n", 3)
        width, height = (int(n) for n in width_height.split())

        def at(x, y):
            i = (y * width + x) * 3
            return tuple(pixels[i:i + 3])
        check(f"{name}: the screen is 1280x800 with the dark canvas", (width, height) == (1280, 800) and at(8, 8) == CANVAS, f"{width}x{height} {at(8, 8)}")
        check(f"{name}: the orange is drawn", at(660, 350) == ORANGE, str(at(660, 350)))
        out = m.type("uname", PROMPT)
        check(f"{name}: uname reports arm64", "Orange OS 0.1.0 Zest arm64" in out, out)
        out = m.type("echo typed on the serial console", PROMPT)
        check(f"{name}: keys reach the shell and a program runs", "typed on the serial console" in out, out)
        out = m.type("ls /bin", PROMPT)
        programs = len(re.findall(r"^  \S+", out, re.M))
        check(f"{name}: the disk holds the Arm programs", programs >= 30, f"{programs} listed")
        out = m.type("thread-probe", PROMPT, 60)
        check(f"{name}: a threaded Zig program runs across processors", "thread-probe: PASS" in out, out)
        out = m.type("signal-probe", PROMPT, 60)
        check(f"{name}: a C program on musl handles signals", "signal-probe: PASS" in out, out)
    finally:
        m.close()


def runtime_checks(name, accel):
    m = Machine(accel)
    try:
        done = m.until(lambda t: "all Arm64 checks" in t or "runtime: FAIL" in t or "KERNEL PANIC" in t or "[FAIL]" in t, 1800)
        seconds = time.time() - m.started
        failures = re.findall(r"(?:runtime: FAIL|\[FAIL\]).*", m.text)
        check(f"{name}: kernel tests and every program check pass", done and "runtime: PASS all Arm64 checks" in m.text and not failures,
              "; ".join(failures) or m.text[-800:])
        kernel = len(re.findall(r"^\[pass\]", m.text, re.M))
        programs = len(re.findall(r"^runtime: PASS", m.text, re.M)) - 1
        print(f"     {kernel} kernel tests and {programs} program checks in {seconds:.0f} s", flush=True)
        return seconds
    finally:
        m.close()


def main():
    native = native_accel()
    build(runtime_test=True)
    timings = {}
    if native:
        timings["native"] = runtime_checks(f"native ({native})", native)
    timings["emulated"] = runtime_checks("emulated", "tcg")

    build(runtime_test=False)
    if native:
        system_checks(f"native ({native})", native)
        system_checks(f"native ({native}), 8 processors", native, cpus=8, memory=2048, commands=False)
    system_checks("emulated", "tcg")
    system_checks("emulated, 1 processor, 512 MB", "tcg", cpus=1, memory=512, commands=False)
    system_checks("emulated, started at hypervisor level", "tcg", cpus=2, machine="virt,gic-version=3,virtualization=on", commands=False)

    print()
    if native:
        print(f"Runtime checks: {timings['emulated']:.0f} s emulated, {timings['native']:.0f} s native "
              f"({timings['emulated'] / max(timings['native'], 1):.1f} times faster)")
    print("Arm64 checks passed.")


if __name__ == "__main__":
    main()
