#!/bin/sh
# Run the already-built Daybreak desktop. On macOS, scale to full screen and
# hide the host cursor: Peel draws the guest cursor itself.
#
# On a Mac the OrangeOS Companion starts with it, so the menu bar and Control
# Center show the Mac's real Wi-Fi, Bluetooth, battery, brightness and sound
# (host/macos/README.md). It talks to the guest over a private virtio-serial
# channel with a fresh per-run key; nothing is opened to the network.
# ORANGE_BRIDGE=0 runs without it (the indicators then show "?").
set -eu
cd "$(dirname "$0")/.."
. ./scripts/vm-profile.sh
if [ ! -f build/orange.iso ] || [ ! -f build/disk.img ] || [ ! -f build/data.img ]; then
    echo "Build first: zig build && ./scripts/mkdisk.sh" >&2
    exit 1
fi

companion_pid=""
bridge_dir=""
cleanup() {
    [ -n "$companion_pid" ] && kill "$companion_pid" 2>/dev/null || true
    [ -n "$bridge_dir" ] && rm -rf "$bridge_dir"
}
trap cleanup EXIT INT TERM

QEMU=qemu-system-x86_64
if [ "$(uname -s)" = Darwin ]; then
    # A sharp picture on a Retina screen: QEMU runs from a small app bundle
    # that tells macOS it draws at full resolution (host/macos), and the
    # guest's 2560x1600 picture is scaled smoothly when it has to be scaled
    # at all (on a 13-inch MacBook Air it maps one to one).
    if [ ! -x "build/OrangeOS Preview.app/Contents/MacOS/orange-qemu" ]; then
        sh host/macos/bundle-preview.sh >/dev/null
    fi
    firmware="$(dirname "$(dirname "$(readlink -f "$(command -v qemu-system-x86_64)" 2>/dev/null || command -v qemu-system-x86_64)")")/share/qemu"
    if [ -f "$firmware/bios-256k.bin" ]; then
        QEMU="build/OrangeOS Preview.app/Contents/MacOS/orange-qemu"
        set -- -L "$firmware" "$@"
    fi
    # Sound through the Mac's output (the guest's /dev/audio).
    set -- -display cocoa,show-cursor=off,full-screen=on,zoom-to-fit=on,zoom-interpolation=on \
        -audiodev coreaudio,id=snd0 -device intel-hda -device hda-output,audiodev=snd0 "$@"
    companion="build/OrangeOS Companion.app/Contents/MacOS/orange-host"
    if [ "${ORANGE_BRIDGE:-1}" != 0 ]; then
        if [ ! -x "$companion" ]; then
            sh host/macos/bundle.sh >/dev/null
        fi
        bridge_dir="$(mktemp -d /tmp/orange-run-XXXXXX)"
        chmod 700 "$bridge_dir"
        (umask 077 && head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$bridge_dir/key")
        set -- "$@" \
            -device virtio-serial-pci,id=orangebus,disable-modern=on,max_ports=2 \
            -chardev "socket,id=orangechan,path=$bridge_dir/agent.sock,server=on,wait=off" \
            -device virtserialport,bus=orangebus.0,nr=1,chardev=orangechan,name=org.orange.host \
            -fw_cfg "name=opt/orange/session,file=$bridge_dir/key"
    fi
fi

"$QEMU" \
    -M q35 -m "${ORANGE_VM_RAM:-3G}" -smp "${ORANGE_VM_CPUS:-2}" \
    -rtc base=utc,clock=host -cdrom build/orange.iso -boot d \
    -drive id=disk0,file=build/disk.img,format=raw,if=none \
    -device ahci,id=ahci -device ide-hd,drive=disk0,bus=ahci.0 \
    -drive id=data0,file=build/data.img,format=raw,if=none \
    -device ide-hd,drive=data0,bus=ahci.1 \
    -netdev user,id=n0 -device e1000,netdev=n0 \
    -serial stdio -no-reboot -no-shutdown "$@" &
qemu_pid=$!

if [ -n "$bridge_dir" ]; then
    # QEMU creates the socket; the companion connects once it exists.
    tries=0
    while [ ! -S "$bridge_dir/agent.sock" ] && [ "$tries" -lt 100 ]; do
        sleep 0.1
        tries=$((tries + 1))
    done
    "$companion" --socket "$bridge_dir/agent.sock" --token-file "$bridge_dir/key" --controls \
        > "$bridge_dir/companion.log" 2>&1 &
    companion_pid=$!
fi

wait "$qemu_pid"
