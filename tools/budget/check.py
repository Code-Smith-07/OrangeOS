#!/usr/bin/env python3
"""Compare a boot's [budget] measurements against ARCHITECTURE.md 16.2.

Reads a serial log, extracts the machine-readable measurements the kernel and
the userland bench program emit, and prints a table with a verdict per row.

Exit status is 1 if the configured RAM ceiling is exceeded or required data
is missing. Kernel size, idle CPU, and timing remain advisory goals. Larger
profiles are allowed with documented justification (ARCHITECTURE.md 16.2).
"""
import os
import re
import sys

MB = 1024 * 1024
RAM_BUDGET_MIB = int(os.environ.get("ORANGE_RAM_BUDGET_MIB", "3072"))
if RAM_BUDGET_MIB <= 0:
    raise ValueError("ORANGE_RAM_BUDGET_MIB must be positive")

# key, label, limit, unit, hard
CHECKS = [
    ("image.total_bytes",   "Kernel image (linked)",    2 * MB,  "bytes", False),
    ("image.bss_bytes",     "  of which .bss",          512 * 1024, "bytes", False),
    ("mem.used_bytes",      "Desktop idle memory",      RAM_BUDGET_MIB * MB, "bytes", True),
    ("idle.busy_pct_x100",  "Desktop idle CPU",         100,      "pct_x100", False),
    ("boot.kernel_ready_ms", "Boot to scheduler",       2000,    "ms",    False),
    ("bench.ctx_switch_ns", "Context switch",           500,     "ns",    False),
    ("bench.syscall_ns",    "Syscall round-trip",       200,     "ns",    False),
]

def human(v, unit):
    if unit == "bytes":
        return f"{v/MB:.2f} MB" if v >= MB else f"{v/1024:.1f} KB"
    if unit == "pct_x100":
        return f"{v/100:.2f}%"
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
            print(f"  {label:<24} {'not reported':>12} {human(limit,unit):>12}   FAIL (missing)")
            failed.append(label + " missing")
            continue
        v = vals[key]
        ok = v <= limit
        if ok:
            status = "pass"
        elif hard:
            status = "FAIL"
            failed.append(label)
        else:
            status = "over (advisory)"
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
        print("  Advisory goals exceeded (not build failures):")
        for w in warned:
            print(f"    - {w}")

    if failed:
        print()
        print("  BUDGET REGRESSION:", ", ".join(failed))
        print("  See ARCHITECTURE.md 16.2; document justified profile increases.")
        return 1

    print()
    print("  All hard limits met.")
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "build/budget-serial.log"))
