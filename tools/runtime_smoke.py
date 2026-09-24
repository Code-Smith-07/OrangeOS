#!/usr/bin/env python3
"""Verify native runtime support on two virtual CPUs with a disposable disk.

Build: zig build -Dmm-test -Druntime-test -Ddesktop-profile; scripts/mkdisk.sh
"""
import re
from desktop_smoke import Guest


def main():
    guest = Guest()
    print(f"Evidence: {guest.output}", flush=True)
    try:
        guest.until(lambda: "runtime: PASS repeated VM processes" in guest.log(),
                    "three complete ring-3 VM probes", 90)
        log = guest.log()
        assert log.count("vm-probe: PASS mapping, subranges, sparse reservation, protection, reuse and capacity") == 3
        assert "[FAIL]" not in log and "vm-probe: FAIL" not in log
        for marker in (
            "user VM: 64 cycles return frames AND page tables",
            "user VM: subranges, hole reuse and frame conservation",
            "user VM: sparse reserve, commit, decommit and cleanup",
            "user VM: exit cleanup frees protected and writable memory",
            "user VM: address-space teardown conserves every page",
        ):
            assert f"[pass] {marker}" in log, marker
        print("PASS frame/page-table conservation and cleanup", flush=True)
        guest.until(lambda: "runtime: PASS null, read-only, NX and invalid-opcode containment" in guest.log(),
                    "faulting apps terminate without halting the OS", 30)
        assert guest.log().count("[app fault]") == 4
        guest.until(lambda: "runtime: PASS concurrent SIMD process isolation" in guest.log(),
                    "twelve native SIMD probes in two concurrent waves", 90)
        masks = [int(mask, 16) for mask in re.findall(r"simd-probe: PASS pid=\d+ cpus=([0-9a-f]+)", guest.log())]
        assert len(masks) == 12, masks
        assert all(mask != 0 for mask in masks)
        combined = 0
        for mask in masks:
            combined |= mask
        cores = guest.profile.cpus
        if combined.bit_count() < min(cores, 2):
            raise AssertionError(f"SIMD probes did not cover both virtual CPUs: {masks}")
        if cores > 1:
            assert any(mask.bit_count() > 1 for mask in masks), f"No SIMD process migrated between CPUs: {masks}"
        assert "simd-probe: FAIL" not in guest.log()
        print(f"PASS eager x87, all sixteen XMM registers, MXCSR and migration; CPU masks={masks}", flush=True)
        guest.until(lambda: "runtime: PASS freestanding C floating-point ABI" in guest.log(),
                    "four concurrent compiler-generated C/Zig floating-point probes", 90)
        assert guest.log().count("c-abi-probe: PASS") == 4
        guest.until(lambda: "runtime: PASS 96 child reaps, slot reuse and wait ownership" in guest.log(),
                    "96 child reaps, slot reuse and wait ownership", 90)
        guest.until(lambda: "runtime: PASS full task table rejects spawn and recovers after reaping" in guest.log(),
                    "full task table rejects spawn and recovers after reaping", 90)
        guest.until(lambda: "runtime: PASS orphan children are collected across 96 parent exits" in guest.log(),
                    "orphan cleanup across 96 exiting parents", 90)
        guest.until(lambda: "runtime: PASS private file descriptors and 96 exit cleanups" in guest.log(),
                    "file descriptor isolation and exit cleanup", 90)
        guest.until(lambda: '"Welcome"' in guest.log() and "squeeze: window" in guest.log(),
                    "desktop starts after runtime stress", 60)
        guest.screenshot("runtime-desktop")
    except AssertionError:
        try:
            print(f"QEMU CPUs at failure:\n{guest.monitor('info cpus')}", flush=True)
            print(f"QEMU selected CPU registers:\n{guest.monitor('info registers')[:1200]}", flush=True)
        except (OSError, RuntimeError) as error:
            print(f"QEMU CPU state unavailable: {error}", flush=True)
        raise
    finally:
        guest.close()


if __name__ == "__main__":
    main()
