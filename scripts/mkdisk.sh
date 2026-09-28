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
        FS_MIB=48
        DISK_MIB=80
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

# WPE WebKit trial probes (docs/design/012) need their libraries' run-time
# files and a larger filesystem; only when asked, so ordinary images are
# unchanged. Build them first with `zig build -Dwpe-probes`.
if [ "${ORANGE_WPE_PROBES:-0}" = 1 ]; then
    FS_MIB=$((FS_MIB + 900))
    DISK_MIB=$((DISK_MIB + 900))
fi

mkdir -p build

# ── Stage the root filesystem ────────────────────────────────────────────────
rm -rf "$ROOTFS"
mkdir -p "$ROOTFS/etc" "$ROOTFS/sbin" "$ROOTFS/bin"
mkdir -p "$ROOTFS/share/licenses"
mkdir -p "$ROOTFS/share/wallpapers"
mkdir -p "$ROOTFS/Trash"
# Mount point for the in-memory tmpfs, so listings of / show it.
mkdir -p "$ROOTFS/tmp"
# Mount point for the device files (/dev/null, /dev/urandom, ...).
mkdir -p "$ROOTFS/dev"
cp assets/fonts/OFL-Inter.txt "$ROOTFS/share/licenses/OFL-Inter.txt"
cp assets/fonts/OFL-JetBrainsMono.txt "$ROOTFS/share/licenses/OFL-JetBrainsMono.txt"
# C programs link musl (MIT), compiled from the copy bundled with the pinned
# Zig toolchain; its notice ships with them.
ZIG_LIB="$(zig env | python3 -c 'import json, sys; print(json.load(sys.stdin)["lib_dir"])')"
cp "$ZIG_LIB/libc/musl/COPYRIGHT" "$ROOTFS/share/licenses/musl-COPYRIGHT.txt"
# C++ programs link libc++, libc++abi and libunwind (Apache-2.0 WITH
# LLVM-exception), from the same toolchain.
for lib in libcxx libcxxabi libunwind; do
    cp "$ZIG_LIB/$lib/LICENSE.TXT" "$ROOTFS/share/licenses/llvm-$lib-LICENSE.txt"
done
cp userland/servers/peel/assets/coastal-glass-1280.bmp "$ROOTFS/share/wallpapers/coastal-glass.bmp"
cp userland/servers/peel/assets/citrus-atelier-1280.bmp "$ROOTFS/share/wallpapers/citrus-atelier.bmp"
cp userland/servers/peel/assets/midnight-aurora-1280.bmp "$ROOTFS/share/wallpapers/midnight-aurora.bmp"

echo "Welcome to Orange OS." > "$ROOTFS/etc/motd"
printf 'NAME="Orange OS"\nVERSION="0.1.0"\nKERNEL="Zest"\n' > "$ROOTFS/etc/os-release"
# Name lookup for musl programs. The resolver is QEMU user networking's,
# which its DHCP server also announces; the disk is read-only, so a network
# service that writes this from the DHCP lease is future work.
printf '127.0.0.1\tlocalhost\n' > "$ROOTFS/etc/hosts"
printf 'nameserver 10.0.2.3\n' > "$ROOTFS/etc/resolv.conf"
# TLS trust store (B9): Mozilla's roots as the curl project extracts them
# (tools/wpe/sources.json pins the release; the file carries its MPL-2.0
# notice). OpenSSL's default for OrangeOS's /etc/ssl configuration.
if [ -f build/wpe/sources/cacert-2026-09-25.pem ]; then
    mkdir -p "$ROOTFS/etc/ssl"
    cp build/wpe/sources/cacert-2026-09-25.pem "$ROOTFS/etc/ssl/cert.pem"
fi

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
for prog in juice echo uname greetd greet peel clock squeeze grove about files trash ping net fetch bench host-agent host-probe hardware vm-probe simd-probe c-abi-probe cxx-abi-probe reap-probe orphan-probe orphan-slow fd-probe socket-probe ipc-probe tls-probe futex-probe futex-waiter thread-probe thread-exit-probe thread-fault-probe thread-last-probe net-thread-probe net-exit-probe tcp-probe jit-probe fault-wx musl-probe cxx-probe file-probe thread-capacity pipe-probe epoll-probe unix-probe spawn-probe spawn-child mmap-probe shm-probe random-probe signal-probe inet-probe fault-null fault-ro fault-nx fault-opcode; do
    if [ -f "zig-out/bin/$prog" ]; then
        cp "zig-out/bin/$prog" "$ROOTFS/bin/$prog"
    fi
done
if [ "${ORANGE_WPE_PROBES:-0}" = 1 ]; then
    for prog in glib-probe wpe-libs-probe jsc jsc-probe https-probe wpe-render orange-browser; do
        if [ ! -f "zig-out/bin/$prog" ]; then
            echo "mkdisk: ERROR - zig-out/bin/$prog not found; run 'zig build -Dwpe-probes' first" >&2
            exit 1
        fi
        cp "zig-out/bin/$prog" "$ROOTFS/bin/$prog"
    done
    # fontconfig's configuration and other data installed by the trial
    # libraries (tools/wpe/build_deps.py), and the fonts it should find.
    cp -R build/wpe/rootfs/. "$ROOTFS/"
    mkdir -p "$ROOTFS/share/wpe-tests"
    cp userland/bin/jsc-probe/probe.js "$ROOTFS/share/wpe-tests/jsc-probe.js"
    cp userland/bin/wpe-render/hello.html "$ROOTFS/share/wpe-tests/hello.html"
    # Orange Browser's own pages.
    mkdir -p "$ROOTFS/share/browser"
    cp userland/share/browser/*.html "$ROOTFS/share/browser/"
    if [ "${ORANGE_BROWSER_AUTOSTART:-0}" = 1 ]; then
        printf 'browser /bin/orange-browser once\n' >> "$ROOTFS/etc/seed.conf"
    fi
    # Content types by file name, for file:// URLs (GIO's xdgmime).
    mkdir -p "$ROOTFS/usr/share/mime"
    cp userland/share/mime/globs2 "$ROOTFS/usr/share/mime/globs2"
    # WebKit starts its helper processes from the libexec directory compiled
    # into it (GNUInstallDirs makes it /usr/libexec for the prefix /).
    mkdir -p "$ROOTFS/usr/libexec/wpe-webkit-2.0"
    for prog in WPEWebProcess WPENetworkProcess; do
        cp "zig-out/bin/$prog" "$ROOTFS/usr/libexec/wpe-webkit-2.0/$prog"
    done
    tools/wpe/test_certs.sh
    cp build/wpe/test-certs/ca.pem "$ROOTFS/share/wpe-tests/test-ca.pem"
    # The HTTPS fixture's certificate, which the browser trusts for
    # 10.0.2.2 only in these test images (tools/browser_smoke.py).
    cp build/wpe/test-certs/server.pem "$ROOTFS/share/wpe-tests/allow-tls.pem"
    # OrangeOS's default fonts for the generic families (B10).
    cp userland/share/fontconfig/56-orangeos-defaults.conf "$ROOTFS/etc/fonts/conf.d/"
    mkdir -p "$ROOTFS/share/fonts"
    cp assets/fonts/Inter.ttf assets/fonts/JetBrainsMono.ttf "$ROOTFS/share/fonts/"
    # Each library's licence travels with the binaries linking it.
    for src in build/wpe/src/*/; do
        name=$(basename "$src")
        case "$name" in bison-*) continue ;; esac # a build tool, not shipped
        for notice in "$src"COPYING* "$src"LICENSE* "$src"LICENCE* "$src"COPYRIGHT* "$src"NOTICE*; do
            [ -f "$notice" ] && cp "$notice" "$ROOTFS/share/licenses/$name-$(basename "$notice")"
        done
    done
fi
echo "mkdisk: staged /sbin/init and $(ls "$ROOTFS/bin" | tr '\n' ' ')"

# ── Build the filesystem and the partitioned disk ────────────────────────────
python3 tools/mkcitrusfs/mkcitrusfs.py "$FSIMG" "$ROOTFS" "$FS_MIB"
python3 tools/mkdisk/mkdisk.py "$DISK" "$DISK_MIB" "$FSIMG"
