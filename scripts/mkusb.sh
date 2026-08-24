#!/bin/sh
# Build a single bootable image suitable for writing to a USB stick.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

[ -f zig-out/bin/kernel.elf ] || { echo "mkusb: run 'zig build' first" >&2; exit 1; }
[ -f build/citrus.img ] || { echo "mkusb: run './scripts/mkdisk.sh' first" >&2; exit 1; }

python3 tools/mkusb/mkusb.py build/orange-usb.img build/citrus.img "${1:-128}"

cat <<'NOTE'

To write it to a USB stick (this ERASES the stick):
  diskutil list                        # find the disk number
  diskutil unmountDisk /dev/diskN
  sudo dd if=build/orange-usb.img of=/dev/rdiskN bs=4m status=progress
  diskutil eject /dev/diskN
NOTE
