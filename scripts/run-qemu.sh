#!/bin/sh
# Shared resource profile for Zig's run/debug/trace targets.
set -eu
cd "$(dirname "$0")/.."
. ./scripts/vm-profile.sh
exec qemu-system-x86_64 -m "$ORANGE_VM_RAM" -smp "$ORANGE_VM_CPUS" "$@"
