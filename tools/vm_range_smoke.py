#!/usr/bin/env python3
"""Focused QEMU check for anonymous VM subranges and frame conservation.

Build: zig build -Dmm-test -Druntime-test -Ddesktop-profile; scripts/mkdisk.sh
"""
from desktop_smoke import Guest


def main():
    guest = Guest()
    print(f"Evidence: {guest.output}", flush=True)
    try:
        guest.until(lambda: "runtime: PASS repeated VM processes" in guest.log(),
                    "three ring-3 VM probes", 90)
        log = guest.log()
        assert log.count("vm-probe: PASS mapping, subranges, sparse reservation, protection, reuse and capacity") == 3
        assert "[pass] user VM: subranges, hole reuse and frame conservation" in log
        assert "[pass] user VM: sparse reserve, commit, decommit and cleanup" in log
        assert "vm-probe: FAIL" not in log and "[FAIL]" not in log
        print("PASS sparse reserve/commit/decommit, subranges and frame conservation", flush=True)
    finally:
        guest.close()


if __name__ == "__main__":
    main()
