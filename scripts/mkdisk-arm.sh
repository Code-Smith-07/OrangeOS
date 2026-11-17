#!/bin/sh
# Build the Arm64 disk image (docs/design/015, stage A2): the same GPT and
# CitrusFS layout as scripts/mkdisk.sh, with the programs from
# zig-out/arm64/bin. scripts/run-arm.sh loads it into the virtual
# machine's memory, where the kernel finds it as its first disk.
#
#   zig build arm && scripts/mkdisk-arm.sh
#   ORANGE_ARM_RUNTIME=1 ...   start the runtime checks instead of the shell
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BIN=zig-out/arm64/bin
ROOTFS=build/arm64-rootfs
FSIMG=build/arm64-citrus.img
DISK=build/arm64-disk.img
FS_MIB=32
DISK_MIB=48

[ -f "$BIN/init" ] || { echo "mkdisk-arm: $BIN/init not found; run 'zig build arm' first" >&2; exit 1; }

rm -rf "$ROOTFS"
mkdir -p "$ROOTFS/etc" "$ROOTFS/sbin" "$ROOTFS/bin" "$ROOTFS/tmp" "$ROOTFS/data" "$ROOTFS/dev"
echo "Welcome to Orange OS." > "$ROOTFS/etc/motd"
printf 'NAME="Orange OS"\nVERSION="0.1.0"\nKERNEL="Zest"\nARCH="arm64"\n' > "$ROOTFS/etc/os-release"
cp "$BIN/init" "$ROOTFS/sbin/init"
for prog in "$BIN"/*; do
    name="$(basename "$prog")"
    [ "$name" = init ] || cp "$prog" "$ROOTFS/bin/$name"
done

# No desktop yet on Arm (stage A4): the shell on the serial console.
cat > "$ROOTFS/etc/seed.conf" <<'CONF'
# Orange OS service configuration (Arm64)
# <name> <path> <policy>   policy: once | respawn | essential
juice   /bin/juice   essential
CONF

python3 tools/mkcitrusfs/mkcitrusfs.py "$FSIMG" "$ROOTFS" "$FS_MIB"
python3 tools/mkdisk/mkdisk.py "$DISK" "$DISK_MIB" "$FSIMG"
echo "mkdisk-arm: $DISK ready ($(ls "$BIN" | wc -l | tr -d ' ') programs)"
