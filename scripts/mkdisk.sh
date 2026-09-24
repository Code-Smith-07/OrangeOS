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

case "${ORANGE_DISK_PROFILE:-desktop}" in
    desktop)
        DISK=build/disk.img
        FSIMG=build/citrus.img
        ROOTFS=build/rootfs
        FS_MIB=32
        DISK_MIB=64
        ;;
    browser)
        DISK=build/browser-disk.img
        FSIMG=build/browser-citrus.img
        ROOTFS=build/browser-rootfs
        FS_MIB=2048
        DISK_MIB=2112
        ;;
    *)
        echo "mkdisk: unknown ORANGE_DISK_PROFILE (expected desktop or browser)" >&2
        exit 1
        ;;
esac

mkdir -p build

# ── Stage the root filesystem ────────────────────────────────────────────────
rm -rf "$ROOTFS"
mkdir -p "$ROOTFS/etc" "$ROOTFS/sbin" "$ROOTFS/bin"
mkdir -p "$ROOTFS/share/licenses"
mkdir -p "$ROOTFS/share/wallpapers"
mkdir -p "$ROOTFS/Trash"
cp assets/fonts/OFL-Inter.txt "$ROOTFS/share/licenses/OFL-Inter.txt"
cp assets/fonts/OFL-JetBrainsMono.txt "$ROOTFS/share/licenses/OFL-JetBrainsMono.txt"
cp userland/servers/peel/assets/coastal-glass-1280.bmp "$ROOTFS/share/wallpapers/coastal-glass.bmp"
cp userland/servers/peel/assets/citrus-atelier-1280.bmp "$ROOTFS/share/wallpapers/citrus-atelier.bmp"
cp userland/servers/peel/assets/midnight-aurora-1280.bmp "$ROOTFS/share/wallpapers/midnight-aurora.bmp"

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
for prog in juice echo uname greetd greet peel clock squeeze grove about files trash ping net fetch bench host-agent host-probe hardware vm-probe simd-probe c-abi-probe cxx-abi-probe reap-probe orphan-probe orphan-slow fd-probe socket-probe ipc-probe tls-probe futex-probe futex-waiter fault-null fault-ro fault-nx fault-opcode; do
    if [ -f "zig-out/bin/$prog" ]; then
        cp "zig-out/bin/$prog" "$ROOTFS/bin/$prog"
    fi
done
echo "mkdisk: staged /sbin/init and $(ls "$ROOTFS/bin" | tr '\n' ' ')"

# ── Build the filesystem and the partitioned disk ────────────────────────────
python3 tools/mkcitrusfs/mkcitrusfs.py "$FSIMG" "$ROOTFS" "$FS_MIB"
python3 tools/mkdisk/mkdisk.py "$DISK" "$DISK_MIB" "$FSIMG"
