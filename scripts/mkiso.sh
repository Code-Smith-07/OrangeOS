#!/bin/sh
# Orange OS — assemble the bootable ISO.
#
# Stages the kernel and Limine into an ISO tree, builds a hybrid BIOS+UEFI
# El Torito image, then stamps it with Limine's BIOS boot record.

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BUILD=build
ISO_ROOT="$BUILD/iso_root"
LIMINE=third_party/limine
KERNEL=zig-out/bin/kernel.elf

[ -f "$KERNEL" ] || { echo "mkiso: $KERNEL not found — run 'zig build' first" >&2; exit 1; }
[ -d "$LIMINE" ] || { echo "mkiso: $LIMINE missing — run scripts/fetch-limine.sh" >&2; exit 1; }

rm -rf "$ISO_ROOT"
mkdir -p "$ISO_ROOT/boot" "$ISO_ROOT/EFI/BOOT"

cp "$KERNEL"                      "$ISO_ROOT/boot/kernel.elf"
cp boot/limine.conf               "$ISO_ROOT/boot/limine.conf"
cp "$LIMINE/limine-bios.sys"      "$ISO_ROOT/boot/"
cp "$LIMINE/limine-bios-cd.bin"   "$ISO_ROOT/boot/"
cp "$LIMINE/limine-uefi-cd.bin"   "$ISO_ROOT/boot/"
cp "$LIMINE/BOOTX64.EFI"          "$ISO_ROOT/EFI/BOOT/"
cp "$LIMINE/BOOTIA32.EFI"         "$ISO_ROOT/EFI/BOOT/"

xorriso -as mkisofs -quiet \
    -R -r -J \
    -b boot/limine-bios-cd.bin \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    -hfsplus \
    -apm-block-size 2048 \
    --efi-boot boot/limine-uefi-cd.bin \
    -efi-boot-part --efi-boot-image \
    --protective-msdos-label \
    "$ISO_ROOT" -o "$BUILD/orange.iso"

# Install Limine's BIOS stage into the ISO so legacy boot works too.
if [ -x "$LIMINE/limine" ]; then
    "$LIMINE/limine" bios-install "$BUILD/orange.iso" >/dev/null 2>&1 || true
fi

SIZE=$(du -h "$BUILD/orange.iso" | cut -f1)
echo "mkiso: build/orange.iso ready ($SIZE)"
