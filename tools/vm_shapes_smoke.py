#!/usr/bin/env python3
"""Does OrangeOS boot on the hardware other virtual machines give it?
(docs/design/014, V2 and V3.)

Build: zig build -Ddesktop-profile && scripts/mkdisk.sh

VirtualBox and VMware cannot run an Intel guest on an Apple Silicon Mac, so
QEMU is made to look like them: the same chipset, disk controller, network
card and graphics adapter each one offers. For every shape the test checks
that the kernel finds the disk, mounts the system, gets a network address
and brings up the desktop. What this cannot check is each product's own
firmware and device quirks: that needs the product itself on an Intel or
AMD computer (V4).
"""
import os
import pathlib
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
ISO = ["-cdrom", str(ROOT / "build/orange.iso"), "-boot", "d"]
DISK = f"file={ROOT / 'build/disk.img'},format=raw,snapshot=on"
NET = ["-netdev", "user,id=n0"]

SHAPES = [
    # (name, what it stands for, QEMU arguments, text the log must contain)
    ("virtualbox-default", "VirtualBox: PIIX3 chipset, IDE disk, PRO/1000 MT Desktop",
     ["-M", "pc", "-drive", f"{DISK},if=ide,index=0", *NET, "-device", "e1000,netdev=n0"],
     ["ATA disk on the primary channel", "mounted CitrusFS on ata0p2"]),
    ("virtualbox-sata", "VirtualBox with a SATA (AHCI) controller",
     ["-M", "pc", "-drive", f"{DISK},if=none,id=d0", "-device", "ahci,id=ahci", "-device", "ide-hd,drive=d0,bus=ahci.0",
      *NET, "-device", "e1000,netdev=n0"],
     ["AHCI", "mounted CitrusFS on sata0p2"]),
    ("vmware", "VMware: SVGA II graphics, IDE disk, e1000 (82545EM)",
     ["-M", "pc", "-vga", "vmware", "-drive", f"{DISK},if=ide,index=0", *NET, "-device", "e1000-82545em,netdev=n0"],
     ["ATA disk", "mounted CitrusFS"]),
    ("vmware-e1000e", "VMware or QEMU with the e1000e card and a SATA disk",
     ["-M", "q35", "-drive", f"{DISK},if=none,id=d0", "-device", "ahci,id=ahci", "-device", "ide-hd,drive=d0,bus=ahci.0",
      *NET, "-device", "e1000e,netdev=n0"],
     ["mounted CitrusFS on sata0p2"]),
    ("nvme", "A recent machine: NVMe disk, e1000e",
     ["-M", "q35", "-drive", f"{DISK},if=none,id=d0", "-device", "nvme,drive=d0,serial=orange1", *NET, "-device", "e1000e,netdev=n0"],
     ["mounted CitrusFS on nvme0"]),
    ("data-disk-on-ide", "Both disks on the IDE controller: /data is still found",
     ["-M", "pc", "-drive", f"{DISK},if=ide,index=0", "-drive", "file={data},format=raw,if=ide,index=1",
      *NET, "-device", "e1000,netdev=n0"],
     ["mounted CitrusFS on ata0p2", "data volume on ata1"]),
    ("data-disk-mixed", "System disk on IDE, data disk on SATA",
     ["-M", "pc", "-drive", f"{DISK},if=ide,index=0", "-drive", "file={data},format=raw,if=none,id=d1",
      "-device", "ahci,id=ahci", "-device", "ide-hd,drive=d1,bus=ahci.0", *NET, "-device", "e1000,netdev=n0"],
     ["mounted CitrusFS on ata0p2", "data volume on sata0"]),
    ("small-video-memory", "8 MB of video memory: no 2560x1600 mode, so 1024x768",
     ["-M", "pc", "-vga", "std", "-global", "VGA.vgamem_mb=8", "-drive", f"{DISK},if=ide,index=0", *NET, "-device", "e1000,netdev=n0"],
     ["framebuffer: 1024x768", "peel: 1024x768"]),
]


def run(name, args, needs, out):
    log = out / f"{name}.log"
    # A fresh data disk for the shapes that attach one.
    if any("{data}" in a for a in args):
        data = out / f"{name}-data.img"
        subprocess.run([sys.executable, str(ROOT / "tools/mkdata.py"), str(data), "--size-mib", "64"], check=True, stdout=subprocess.DEVNULL)
        args = [a.replace("{data}", str(data)) for a in args]
    proc = subprocess.Popen(["qemu-system-x86_64", "-m", "3G", "-smp", "2", "-rtc", "base=utc,clock=host",
                             "-display", "none", "-serial", f"file:{log}", "-no-reboot", "-no-shutdown", *ISO, *args],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    wanted = [*needs, "dhcp: leased", 'peel: window', '"Welcome"', "squeeze: window"]
    try:
        deadline = time.time() + 120
        while time.time() < deadline:
            text = log.read_text(errors="replace") if log.exists() else ""
            if all(w in text for w in wanted):
                return None
            if "KERNEL PANIC" in text or "CPU EXCEPTION" in text or "no filesystem mounted" in text:
                break
            if proc.poll() is not None:
                break
            time.sleep(1)
        text = log.read_text(errors="replace") if log.exists() else ""
        return [w for w in wanted if w not in text] or ["(stopped early)"]
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()


def main():
    out = pathlib.Path(tempfile.mkdtemp(prefix="orange-vm-shapes-"))
    failed = 0
    for name, what, args, needs in SHAPES:
        missing = run(name, args, needs, out)
        if missing:
            failed += 1
            print(f"FAIL {name} ({what}): missing {missing}; see {out / (name + '.log')}", flush=True)
        else:
            print(f"PASS {name}: {what}", flush=True)
    if failed:
        sys.exit(1)
    print(f"All {len(SHAPES)} machine shapes boot to the desktop with a disk and a network address; logs in {out}", flush=True)


if __name__ == "__main__":
    main()
