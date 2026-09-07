#!/bin/sh
# Build a bootable-layout development disk:
#   1. GPT with an ESP and a data partition
#   2. a CitrusFS image populated from build/rootfs
#   3. the filesystem spliced into the data partition
#
# Run after `zig build`, so init.elf exists to be placed on the disk.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DISK=build/disk.img
FSIMG=build/citrus.img
ROOTFS=build/rootfs
DATA_LBA=22528          # matches tools/mkdisk/mkdisk.py

mkdir -p build

# ── Stage the root filesystem ────────────────────────────────────────────────
rm -rf "$ROOTFS"
mkdir -p "$ROOTFS/etc" "$ROOTFS/sbin" "$ROOTFS/bin"
mkdir -p "$ROOTFS/share/licenses"
mkdir -p "$ROOTFS/Trash"
cp assets/fonts/OFL-Inter.txt "$ROOTFS/share/licenses/OFL-Inter.txt"
cp assets/fonts/OFL-JetBrainsMono.txt "$ROOTFS/share/licenses/OFL-JetBrainsMono.txt"

echo "Welcome to Orange OS." > "$ROOTFS/etc/motd"
printf 'NAME="Orange OS"\nVERSION="0.1.0"\nKERNEL="Zest"\n' > "$ROOTFS/etc/os-release"

cat > "$ROOTFS/etc/seed.conf" <<'CONF'
# Orange OS service configuration
# <name> <path> <policy>   policy: once | respawn | essential
peel    /bin/peel    essential
host-agent /bin/host-agent once
host-probe /bin/host-probe once
greetd  /bin/greetd  respawn
squeeze /bin/squeeze once
grove   /bin/grove   once
juice   /bin/juice   essential
CONF

if [ ! -f zig-out/bin/init ]; then
    echo "mkdisk: ERROR - zig-out/bin/init not found; run 'zig build' first" >&2
    exit 1
fi

cp zig-out/bin/init "$ROOTFS/sbin/init"
for prog in juice echo uname greetd greet peel clock squeeze grove about files trash ping net fetch bench host-agent host-probe; do
    if [ -f "zig-out/bin/$prog" ]; then
        cp "zig-out/bin/$prog" "$ROOTFS/bin/$prog"
    fi
done
echo "mkdisk: staged /sbin/init and $(ls "$ROOTFS/bin" | tr '\n' ' ')"

# ── Build the filesystem and the partitioned disk ────────────────────────────
python3 tools/mkcitrusfs/mkcitrusfs.py "$FSIMG" "$ROOTFS" 32
python3 tools/mkdisk/mkdisk.py "$DISK"

# ── Splice the filesystem into the data partition ────────────────────────────
dd if="$FSIMG" of="$DISK" bs=512 seek="$DATA_LBA" conv=notrunc status=none
echo "mkdisk: CitrusFS written at LBA $DATA_LBA"
