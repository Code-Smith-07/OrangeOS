//! bench — measure syscall round-trip cost from userspace.
//!
//! ARCHITECTURE.md §16.2 budgets a syscall at under 200 ns. That number can
//! only be taken honestly from ring 3: measuring the kernel-side handler alone
//! would leave out the `syscall`/`sysret` transition, the swapgs pair and the
//! stack switch, which is most of what a syscall actually costs.
//!
//! `getpid` is the subject because it is the cheapest call in the table - it
//! reads one field and returns. Anything more would be measuring the work
//! rather than the mechanism.

const pulp = @import("pulp");

/// Enough iterations that millisecond-resolution wall time still gives a
/// meaningful per-call figure: at the 200 ns budget this run takes 200 ms, so
/// a single millisecond of clock jitter is a 0.5 % error rather than a 50 % one.
const ITERATIONS: u64 = 1_000_000;

export fn _start() callconv(.c) noreturn {
    // Warm up. The first calls through a cold path are not representative.
    var w: u64 = 0;
    while (w < 10_000) : (w += 1) _ = pulp.getpid();

    const t0 = pulp.uptimeMs();
    var i: u64 = 0;
    while (i < ITERATIONS) : (i += 1) _ = pulp.getpid();
    const t1 = pulp.uptimeMs();

    const elapsed_ms = t1 - t0;

    // ns per call = elapsed_ms * 1e6 / ITERATIONS. With ITERATIONS at exactly
    // one million those cancel, but the arithmetic is written out so that
    // changing the count does not silently change the units.
    const ns_per_call = (elapsed_ms * 1_000_000) / ITERATIONS;

    pulp.print("[budget] bench.syscall_ns {d}\n", .{ns_per_call});
    pulp.print("[budget] bench.syscall_samples {d}\n", .{ITERATIONS});
    pulp.print("[budget] bench.syscall_elapsed_ms {d}\n", .{elapsed_ms});
    pulp.exit(0);
}
