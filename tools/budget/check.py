#!/usr/bin/env python3
"""Compare a boot's [budget] measurements against ARCHITECTURE.md 16.2.

Reads a serial log, extracts the machine-readable measurements the kernel and
the userland bench program emit, and prints a table with a verdict per row.

Exit status is 1 only if a HARD limit is exceeded. Timing limits describe
native hardware; this development setup runs QEMU's TCG interpreter emulating
x86_64 on arm64, so those are reported as warnings rather than treated as
regressions. Marking them hard here would mean a red build on every run, which
is the fastest way to make a budget check worthless.
"""
import re
import sys

MB = 1024 * 1024

# key, label, limit, unit, hard
CHECKS = [
    ("image.total_bytes",   "Kernel image (linked)",    2 * MB,  "bytes", True),
    ("image.bss_bytes",     "  of which .bss",          512 * 1024, "bytes", True),
    ("mem.used_bytes",      "Desktop idle memory",      128 * MB, "bytes", True),
    ("boot.kernel_ready_ms", "Boot to scheduler",       2000,    "ms",    False),
    ("bench.ctx_switch_ns", "Context switch",           500,     "ns",    False),
    ("bench.syscall_ns",    "Syscall round-trip",       200,     "ns",    False),
]

def human(v, unit):
    if unit == "bytes":
        return f"{v/MB:.2f} MB" if v >= MB else f"{v/1024:.1f} KB"
    return f"{v} {unit}"

def main(path):
    vals = {}
    with open(path, errors="replace") as f:
        for line in f:
            m = re.search(r"\[budget\]\s+(\S+)\s+(\d+)\s*$", line)
            if m:
                vals[m.group(1)] = int(m.group(2))

    if not vals:
        print("budget: no measurements found in", path)
        return 1

    print()
    print("  ORANGE OS RESOURCE BUDGET  (ARCHITECTURE.md 16.2)")
    print("  " + "-" * 64)
    print(f"  {'metric':<24} {'measured':>12} {'limit':>12}   status")
    print("  " + "-" * 64)

    failed = []
    warned = []
    for key, label, limit, unit, hard in CHECKS:
        if key not in vals:
            print(f"  {label:<24} {'not reported':>12} {human(limit,unit):>12}   SKIP")
            continue
        v = vals[key]
        ok = v <= limit
        if ok:
            status = "pass"
        elif hard:
            status = "FAIL"
            failed.append(label)
        else:
            status = "over (emulated)"
            warned.append(label)
        print(f"  {label:<24} {human(v,unit):>12} {human(limit,unit):>12}   {status}")

    print("  " + "-" * 64)

    # Context for the numbers that are not themselves budgeted.
    extra = [
        ("image.text_bytes", "kernel .text"),
        ("mem.total_bytes", "RAM present"),
        ("bench.ctx_switch_samples", "ctx switches sampled"),
        ("bench.syscall_samples", "syscalls sampled"),
    ]
    print()
    for key, label in extra:
        if key in vals:
            v = vals[key]
            s = human(v, "bytes") if "bytes" in key else f"{v:,}"
            print(f"    {label:<24} {s}")

    if warned:
        print()
        print("  Timing limits describe native hardware. This run was measured")
        print("  under TCG emulation, so the following are reported, not failed:")
        for w in warned:
            print(f"    - {w}")

    if failed:
        print()
        print("  BUDGET REGRESSION:", ", ".join(failed))
        print("  16.2: a change that regresses these is a failed build.")
        return 1

    print()
    print("  All hard limits met.")
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "build/budget-serial.log"))
