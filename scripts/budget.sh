#!/bin/sh
# Orange OS — resource budget check (ARCHITECTURE.md §16.2)
#
# Boots the kernel with -Dbudget, collects the [budget] measurements off the
# serial line, and compares them against the documented limits.
#
# Two classes of check, deliberately separated:
#
#   HARD    Size and memory figures. These are properties of the build and of
#           the running system, identical on any host, so a regression is a
#           real regression and fails the script.
#
#   TIMING  Boot time and the two latency benchmarks. Development here happens
#           under QEMU's TCG interpreter on an arm64 Mac, emulating x86_64 -
#           which is a long way from the hardware the budget describes. These
#           are reported and compared, but a miss is a warning, because
#           failing a build on an emulator's speed would train everyone to
#           ignore the check. They become hard once there is a native-speed
#           reference machine to run them on.
set -e
cd "$(dirname "$0")/.."

LOG=build/budget-serial.log
TIMEOUT=${BUDGET_TIMEOUT:-90}

echo "budget: building with -Dbudget"
zig build -Dbudget >/dev/null
./scripts/mkdisk.sh >/dev/null
./scripts/mkusb.sh >/dev/null

echo "budget: booting (${TIMEOUT}s)"
rm -f "$LOG"
cp /opt/homebrew/share/qemu/edk2-i386-vars.fd build/uefi-vars.fd 2>/dev/null || true
qemu-system-x86_64 -M q35 -m 512M -smp 4 \
  -drive if=pflash,format=raw,unit=0,readonly=on,file=/opt/homebrew/share/qemu/edk2-x86_64-code.fd \
  -drive if=pflash,format=raw,unit=1,file=build/uefi-vars.fd \
  -drive id=nvm0,file=build/orange-usb.img,format=raw,if=none \
  -device nvme,serial=orange0,drive=nvm0 \
  -display none -serial file:"$LOG" -no-reboot -no-shutdown &
QEMU_PID=$!
trap 'kill $QEMU_PID 2>/dev/null || true' EXIT

# Wait for the userland benchmark, which is the last thing to report.
i=0
while [ "$i" -lt "$TIMEOUT" ]; do
    if grep -q "bench.syscall_ns" "$LOG" 2>/dev/null; then break; fi
    sleep 1
    i=$((i + 1))
done
kill $QEMU_PID 2>/dev/null || true

if ! grep -q "bench.syscall_ns" "$LOG" 2>/dev/null; then
    echo "budget: FAILED - the guest never reported a full set of measurements."
    echo "        This is a boot or benchmark failure, not a budget regression."
    grep -c "CPU EXCEPTION" "$LOG" >/dev/null 2>&1 && grep -q "CPU EXCEPTION" "$LOG" \
        && echo "        The kernel panicked; see $LOG"
    exit 1
fi

python3 tools/budget/check.py "$LOG"
