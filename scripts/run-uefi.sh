#!/bin/sh
# Boot the USB image under UEFI firmware, the way a physical machine would.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

FW=/opt/homebrew/share/qemu/edk2-x86_64-code.fd
VARS_TEMPLATE=/opt/homebrew/share/qemu/edk2-i386-vars.fd

[ -f "$FW" ] || { echo "run-uefi: UEFI firmware not found at $FW" >&2; exit 1; }
[ -f build/orange-usb.img ] || ./scripts/mkusb.sh >/dev/null

# Fresh NVRAM every boot: a cached boot entry naming a device path that no longer
# exists sends the firmware to its shell instead of the fallback loader.
cp "$VARS_TEMPLATE" build/uefi-vars.fd

exec qemu-system-x86_64 \
    -M q35 -m 512M -smp 4 \
    -drive if=pflash,format=raw,unit=0,readonly=on,file="$FW" \
    -drive if=pflash,format=raw,unit=1,file=build/uefi-vars.fd \
    -drive id=usb0,file=build/orange-usb.img,format=raw,if=none \
    -device ahci,id=ahci -device ide-hd,drive=usb0,bus=ahci.0 \
    -netdev user,id=n0 -device e1000,netdev=n0 \
    -device qemu-xhci,id=xhci -device usb-kbd,bus=xhci.0 -device usb-mouse,bus=xhci.0 \
    -serial stdio -no-reboot -no-shutdown "$@"
