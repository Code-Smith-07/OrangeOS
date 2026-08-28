//! Resource budget accounting.
//!
//! ARCHITECTURE.md §16.2 fixes hard limits on how much of the machine Orange
//! OS is allowed to consume, and states that a change which regresses any of
//! them is a failed build rather than a discussion. That claim is the entire
//! product thesis: an OS that is merely *nice* has plenty of competition, and
//! one that is measurably small does not.
//!
//! It was also, until now, completely unmeasured. This module makes the
//! numbers real. It prints them in a fixed `[budget] key value` form so that
//! scripts/budget.sh can diff them against the thresholds and fail a build,
//! rather than leaving it to somebody to notice.
//!
//! Everything here is measurement only. Nothing in this file may change how
//! the kernel behaves, because then the numbers would be describing a
//! different system than the one that ships.

const std = @import("std");
const console = @import("../console.zig");
const pmm = @import("../mm/pmm.zig");
const heap = @import("../mm/heap.zig");
const sched = @import("../sched/sched.zig");
const tsc = @import("../time/tsc.zig");
const context = @import("../arch/x86_64/context.zig");
const percpu = @import("../arch/x86_64/percpu.zig");
const io = @import("../arch/x86_64/io.zig");

extern var __kernel_start: u8;
extern var __text_start: u8;
extern var __text_end: u8;
extern var __rodata_start: u8;
extern var __rodata_end: u8;
extern var __data_start: u8;
extern var __data_end: u8;
extern var __bss_start: u8;
extern var __bss_end: u8;
extern var __kernel_end: u8;

fn span(a: *u8, b: *u8) usize {
    return @intFromPtr(b) - @intFromPtr(a);
}

/// One machine-readable measurement. The format is deliberately rigid: a
/// human-friendly table is easy to write and impossible to diff.
fn emit(key: []const u8, value: u64) void {
    console.print("[budget] {s} {d}\n", .{ key, value });
}

/// Static size of the kernel as linked. Reported separately per section
/// because the interesting regressions are sectional - a jump in .bss means
/// somebody added a large static array, which is a different mistake from
/// .text growing because the kernel genuinely does more.
pub fn reportImage() void {
    emit("image.text_bytes", span(&__text_start, &__text_end));
    emit("image.rodata_bytes", span(&__rodata_start, &__rodata_end));
    emit("image.data_bytes", span(&__data_start, &__data_end));
    emit("image.bss_bytes", span(&__bss_start, &__bss_end));
    emit("image.total_bytes", span(&__kernel_start, &__kernel_end));
}

/// Live memory use. `used` counts every page the allocator has handed out,
/// which includes the kernel image itself, page tables, slabs and every
/// userland process - i.e. the number a user would see, not a flattering
/// subset of it.
pub fn reportMemory() void {
    const p = pmm.stats();
    const h = heap.stats();
    emit("mem.total_bytes", p.total_pages * pmm.PAGE_SIZE);
    emit("mem.used_bytes", p.used_pages * pmm.PAGE_SIZE);
    emit("mem.free_bytes", p.free_pages * pmm.PAGE_SIZE);
    // Object counts, not bytes. heap.stats() reports how many slab objects are
    // live and how many slots exist; naming these "bytes" would be a lie that
    // happens to look plausible.
    emit("mem.heap_live_objects", h.slab_allocated);
    emit("mem.heap_total_slots", h.slab_total);
}

/// Microseconds from kmain to the scheduler taking over. Recorded at the
/// moment of handoff rather than read here, because this function runs from a
/// thread that deliberately waits for the desktop to settle - reporting the
/// clock at that point would measure the wait, not the boot.
var kernel_ready_us: u64 = 0;

pub fn markKernelReady() void {
    kernel_ready_us = tsc.microsSinceBoot();
}

pub fn reportBoot() void {
    emit("boot.kernel_ready_ms", kernel_ready_us / 1000);
}

/// Ping-pong partner for the context-switch benchmark. Does nothing but hand
/// control straight back, so what gets timed is the switch and not the work.
var bench_main_rsp: u64 = 0;
var bench_partner_rsp: u64 = 0;

fn benchPartner() callconv(.c) noreturn {
    while (true) context.contextSwitch(&bench_partner_rsp, bench_main_rsp);
}

/// Cost of one context switch, in nanoseconds.
///
/// This drives `contextSwitch` directly against a private stack instead of
/// going through sched.yield(). The first version of this benchmark did use
/// yield, divided elapsed time by the scheduler's switch counter, and reported
/// 3950 ns - a number that meant nothing. That counter is global across every
/// core, so it was dividing one core's wall-clock time by four cores' worth of
/// switches, while also counting every unrelated thread's switches as though
/// this benchmark had caused them.
///
/// What 16.2 budgets is the cost of the switch itself, so that is what is
/// measured here: interrupts off, one core, two contexts, nothing else moving.
pub fn benchContextSwitch() void {
    const rounds = 100_000;

    const pages = 4;
    const phys = pmm.allocOrderZeroed(pmm.orderFor(pages)) catch {
        emit("bench.ctx_switch_ns", 0);
        return;
    };
    defer pmm.freeOrder(phys, pmm.orderFor(pages));

    const stack_top = pmm.physToVirt(phys) + pages * pmm.PAGE_SIZE;
    bench_partner_rsp = context.prepareStack(stack_top, @intFromPtr(&benchPartner));

    // Interrupts off for the duration. A timer tick landing mid-measurement
    // would be counted as switch cost, and preemption would hand the core to
    // somebody else in the middle of the loop. This runs from a kernel thread
    // with interrupts on, so re-enabling unconditionally at the end is correct.
    io.cli();
    defer io.sti();

    // Warm up: the first switches fault in cold cache lines.
    var w: usize = 0;
    while (w < 1_000) : (w += 1) context.contextSwitch(&bench_main_rsp, bench_partner_rsp);

    const t0 = tsc.readSerialized();
    var i: usize = 0;
    while (i < rounds) : (i += 1) context.contextSwitch(&bench_main_rsp, bench_partner_rsp);
    const ticks = tsc.readSerialized() - t0;

    // Two switches per iteration: out to the partner and back again.
    const switches = rounds * 2;
    const per_hz = tsc.frequencyHz();
    if (per_hz == 0) return;
    emit("bench.ctx_switch_ns", (ticks * 1_000_000_000) / (per_hz * switches));
    emit("bench.ctx_switch_samples", switches);
}

/// Fraction of a window each core spent idle, in hundredths of a percent.
///
/// 16.2 budgets idle CPU with a desktop on screen at under 1 %. Taken as a
/// difference across a window rather than as a lifetime average, because a
/// lifetime average is dominated by boot - when the machine is legitimately
/// busy - and would flatter any amount of steady-state spinning.
var task_before: [64]u64 = @splat(0);

pub fn benchIdleCpu(cpu_count: usize, window_ms: u64) void {
    var tb: usize = 0;
    while (tb < sched.taskSlotCount() and tb < task_before.len) : (tb += 1) {
        task_before[tb] = if (sched.taskAt(tb)) |t| t.ticks_used else 0;
    }

    var before: [percpu.MAX_CPUS]struct { idle: u64, busy: u64 } = undefined;
    var i: usize = 0;
    while (i < cpu_count and i < before.len) : (i += 1) {
        const s = sched.cpuIdleSamples(i);
        before[i] = .{ .idle = s.idle, .busy = s.busy };
    }

    // Must block, not busy-wait: a measuring thread that holds a core makes
    // that core read as busy and understates how idle the machine really is.
    sched.sleepMs(window_ms);

    var tot_idle: u64 = 0;
    var tot_busy: u64 = 0;
    i = 0;
    while (i < cpu_count and i < before.len) : (i += 1) {
        const s = sched.cpuIdleSamples(i);
        const d_idle = s.idle - before[i].idle;
        const d_busy = s.busy - before[i].busy;
        tot_idle += d_idle;
        tot_busy += d_busy;

        const total = d_idle + d_busy;
        const busy_pct_x100: u64 = if (total == 0) 0 else (d_busy * 10_000) / total;
        console.print("[budget] cpu{d}.busy_pct_x100 {d} (idle_ticks={d} busy_ticks={d})\n", .{ i, busy_pct_x100, d_idle, d_busy });
    }

    const total = tot_idle + tot_busy;
    const busy_x100: u64 = if (total == 0) 0 else (tot_busy * 10_000) / total;
    emit("idle.busy_pct_x100", busy_x100);
    emit("idle.samples", total);

    // Attribute the busy time. A percentage on its own says the machine is
    // awake; this says who woke it.
    var n: usize = 0;
    while (n < sched.taskSlotCount() and n < task_before.len) : (n += 1) {
        const t = sched.taskAt(n) orelse continue;
        const used = t.ticks_used - task_before[n];
        if (used == 0) continue;
        console.print("[budget] task.{s} {d}\n", .{ t.nameSlice(), used });
    }
}

/// Print everything. Called from a kernel thread once the desktop is up, so
/// the memory figures describe a running system rather than a half-booted one.
pub fn reportAll(cpu_count: usize) void {
    const tid: u32 = if (sched.currentTask()) |t| t.tid else 0;
    console.print("\n[budget] reporter cpu={d} tid={d}\n", .{ percpu.this().cpu_index, tid });
    reportImage();
    reportMemory();
    reportBoot();
    benchContextSwitch();
    // Memory again: the benchmark itself allocates nothing, so a difference
    // here would mean something else moved while we were measuring.
    emit("mem.used_bytes_after_bench", pmm.stats().used_pages * pmm.PAGE_SIZE);
    benchIdleCpu(cpu_count, 10000);
    console.write("[budget] ---- end ----\n");
}
