#!/usr/bin/env python3
"""Verify native runtime support on two virtual CPUs with a disposable disk.

Build: zig build -Dmm-test -Druntime-test -Ddesktop-profile; scripts/mkdisk.sh
"""
from desktop_smoke import Guest


def main():
    guest = Guest()
    print(f"Evidence: {guest.output}", flush=True)
    try:
        guest.until(lambda: "runtime: PASS repeated VM processes" in guest.log(),
                    "three complete ring-3 VM probes", 90)
        log = guest.log()
        assert log.count("vm-probe: PASS mapping, protection, rejection, reuse and capacity") == 3
        assert "[FAIL]" not in log and "vm-probe: FAIL" not in log
        for marker in (
            "user VM: 64 cycles return frames AND page tables",
            "user VM: exit cleanup frees protected and writable memory",
            "user VM: address-space teardown conserves every page",
        ):
            assert f"[pass] {marker}" in log, marker
        print("PASS frame/page-table conservation and cleanup", flush=True)
        guest.until(lambda: '"Welcome"' in guest.log() and "squeeze: window" in guest.log(),
                    "desktop starts after runtime stress", 60)
        guest.screenshot("runtime-desktop")
    finally:
        guest.close()


if __name__ == "__main__":
    main()
