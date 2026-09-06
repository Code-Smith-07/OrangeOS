#!/bin/sh
# Run the already-built Daybreak desktop. On macOS, scale to full screen and
# hide the host cursor: Peel draws the guest cursor itself.
set -eu
cd "$(dirname "$0")/.."
if [ ! -f build/orange.iso ] || [ ! -f build/disk.img ]; then
    echo "Build first: zig build && ./scripts/mkdisk.sh" >&2
    exit 1
fi
if [ "$(uname -s)" = Darwin ]; then
    set -- -display cocoa,show-cursor=off,full-screen=on,zoom-to-fit=on "$@"
fi
exec qemu-system-x86_64 \
    -M q35 -m "${ORANGE_VM_RAM:-3G}" -smp "${ORANGE_VM_CPUS:-2}" \
    -rtc base=utc,clock=host -cdrom build/orange.iso -boot d \
    -drive id=disk0,file=build/disk.img,format=raw,if=none \
    -device ahci,id=ahci -device ide-hd,drive=disk0,bus=ahci.0 \
    -netdev user,id=n0 -device e1000,netdev=n0 \
    -serial stdio -no-reboot -no-shutdown "$@"
