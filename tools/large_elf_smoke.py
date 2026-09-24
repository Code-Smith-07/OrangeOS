#!/usr/bin/env python3
"""Boot a >8 MiB init ELF to catch whole-file executable buffering."""

import pathlib
import shutil
import subprocess
import tempfile

from desktop_smoke import Guest

ROOT = pathlib.Path(__file__).resolve().parents[1]
MIN_SIZE = 9 * 1024 * 1024


def main():
    with tempfile.TemporaryDirectory(prefix="orange-large-elf-") as temporary:
        workspace = pathlib.Path(temporary)
        rootfs = workspace / "rootfs"
        shutil.copytree(ROOT / "build/rootfs", rootfs)
        init = rootfs / "sbin/init"
        assert init.stat().st_size < MIN_SIZE
        with init.open("r+b") as binary:
            binary.truncate(MIN_SIZE)
        filesystem = workspace / "citrus.img"
        disk = workspace / "disk.img"
        subprocess.run(["python3", str(ROOT / "tools/mkcitrusfs/mkcitrusfs.py"),
                        str(filesystem), str(rootfs), "64"], check=True)
        subprocess.run(["python3", str(ROOT / "tools/mkdisk/mkdisk.py"),
                        str(disk), "96", str(filesystem)], check=True)

        guest = Guest(disk_path=disk)
        print(f"Evidence: {guest.output}", flush=True)
        try:
            guest.until(lambda: f"loading /sbin/init from disk ({MIN_SIZE} bytes)" in guest.log(),
                        "loader accepts an ELF larger than 8 MiB", 45)
            guest.until(lambda: '"Welcome"' in guest.log() and "squeeze: window" in guest.log(),
                        "large ELF reaches desktop", 60)
            assert "exec failed" not in guest.log() and "KERNEL PANIC" not in guest.log()
            guest.screenshot("large-elf-desktop")
        finally:
            guest.close()


if __name__ == "__main__":
    main()
