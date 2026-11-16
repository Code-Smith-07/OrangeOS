#!/bin/sh
# Boot the Arm64 kernel (stage A0, docs/design/015) in QEMU.
#
#   scripts/run-arm.sh            native speed where the host is Arm
#   ORANGE_ARM_ACCEL=tcg ...      force emulation (any host)
#   ORANGE_ARM_DISPLAY=none ...   no window (tests)
#   ORANGE_VM_CPUS=4 ...          processors (default 4)
#
# On an Apple Silicon Mac the processor is not emulated: Apple's Hypervisor
# runs the guest's Arm instructions directly, the way Parallels runs the Arm
# build of Windows. Extra arguments are passed to QEMU.
set -e
cd "$(dirname "$0")/.."
KERNEL=zig-out/bin/kernel-arm64.elf
[ -f "$KERNEL" ] || { echo "run-arm: build it first: zig build arm" >&2; exit 1; }

ACCEL="${ORANGE_ARM_ACCEL:-}"
if [ -z "$ACCEL" ]; then
    ACCEL=tcg
    if [ "$(uname -m)" = arm64 ] || [ "$(uname -m)" = aarch64 ]; then
        case "$(uname -s)" in
            Darwin) qemu-system-aarch64 -accel help 2>/dev/null | grep -q hvf && ACCEL=hvf ;;
            Linux) [ -w /dev/kvm ] && ACCEL=kvm ;;
        esac
    fi
fi
if [ "$ACCEL" = tcg ]; then CPU=max; else CPU=host; fi

DISPLAY_ARG="${ORANGE_ARM_DISPLAY:-}"
if [ -z "$DISPLAY_ARG" ]; then
    if [ "$(uname -s)" = Darwin ]; then DISPLAY_ARG=cocoa; else DISPLAY_ARG=gtk; fi
fi

echo "run-arm: $ACCEL, $CPU processor model" >&2
exec qemu-system-aarch64 \
    -M virt,gic-version=3 -accel "$ACCEL" -cpu "$CPU" \
    -smp "${ORANGE_VM_CPUS:-4}" -m "${ORANGE_VM_MEMORY:-1024}" \
    -global virtio-mmio.force-legacy=false -device virtio-gpu-device \
    -display "$DISPLAY_ARG" -serial stdio \
    -kernel "$KERNEL" "$@"
