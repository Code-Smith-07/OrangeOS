#!/bin/sh
# Make the files other virtual machine programs need, in build/vm/:
#
#   orange.iso   the boot disc (BIOS and UEFI)
#   system.vmdk  the system disk
#   data.vmdk    an empty data disk (/data: documents, settings, password)
#
# VMDK is read by VirtualBox, VMware and UTM alike. See
# docs/running-in-virtual-machines.md for the settings to use.
# Build first: zig build && ./scripts/mkdisk.sh
set -eu
cd "$(dirname "$0")/.."
if [ ! -f build/orange.iso ] || [ ! -f build/disk.img ]; then
    echo "Build first: zig build && ./scripts/mkdisk.sh" >&2
    exit 1
fi
if ! command -v qemu-img >/dev/null 2>&1; then
    echo "qemu-img is needed to convert the disks (it comes with QEMU)." >&2
    exit 1
fi
mkdir -p build/vm
cp build/orange.iso build/vm/orange.iso
qemu-img convert -f raw -O vmdk build/disk.img build/vm/system.vmdk
# A fresh data disk, so nothing personal leaves this machine.
python3 tools/mkdata.py build/vm/data.raw --size-mib 64 >/dev/null
qemu-img convert -f raw -O vmdk build/vm/data.raw build/vm/data.vmdk
rm -f build/vm/data.raw
echo "Ready in build/vm/:"
ls -lh build/vm | awk 'NR > 1 { print "  " $9 "  " $5 }'
echo "Settings: docs/running-in-virtual-machines.md"
