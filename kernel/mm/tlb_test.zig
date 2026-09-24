//! Live two-CPU shootdown probe. Run with -Druntime-test in QEMU.
const tlb = @import("tlb.zig");
const vmm = @import("vmm.zig");
const pmm = @import("pmm.zig");
const smp = @import("../arch/x86_64/smp.zig");
const percpu = @import("../arch/x86_64/percpu.zig");
const console = @import("../console.zig");

const TEST_VA: u64 = 0xffff_ffff_4000_0000;

pub fn run(_: ?*anyopaque) void {
    @import("residency_test.zig").testPreemptGuard();
    legacyProbe();
    @import("residency_test.zig").run() catch |err| {
        console.print("[FAIL] address-space residency: {s}\n", .{@errorName(err)});
    };
}

fn legacyProbe() void {
    // CPU selection and delivery-count comparisons must not migrate halfway.
    const pin = @import("../sched/preempt.zig").acquire();
    defer pin.release();
    if (vmm.translate(vmm.kernelPml4(), TEST_VA) != null) {
        console.err("TLB probe address is already mapped", .{});
        return;
    }
    const a = pmm.allocPage() catch return;
    const b = pmm.allocPage() catch {
        pmm.freePage(a);
        return;
    };
    defer pmm.freePage(a);
    defer pmm.freePage(b);
    const flags = vmm.PRESENT | vmm.WRITABLE | vmm.NO_EXECUTE;
    const ptr: *const volatile u64 = @ptrFromInt(TEST_VA);
    var ok = true;
    var observed: u64 = 0;
    for (0..32) |round| {
        const first: u64 = 0x516c_00a0_0000_0000 | @as(u64, @intCast(round));
        const second: u64 = 0x516c_00b0_0000_0000 | @as(u64, @intCast(round));
        @as(*u64, @ptrFromInt(pmm.physToVirt(a))).* = first;
        @as(*u64, @ptrFromInt(pmm.physToVirt(b))).* = second;
        vmm.mapPage(vmm.kernelPml4(), TEST_VA, a, flags) catch {
            ok = false;
            break;
        };
        const r1 = tlb.sampleKernelPage(TEST_VA);
        observed |= r1.remote_mask;
        if (ptr.* != first or !samplesMatch(r1, first)) ok = false;
        vmm.mapPage(vmm.kernelPml4(), TEST_VA, b, flags) catch unreachable;
        const r2 = tlb.sampleKernelPage(TEST_VA);
        observed |= r2.remote_mask;
        if (ptr.* != second or !samplesMatch(r2, second)) ok = false;
        if (!ok) break;
    }
    const online = smp.onlineMask();
    const eligible = online & ~(@as(u64, 1) << @intCast(percpu.cpuIndex()));
    if (ok and eligible != 0) {
        const target: usize = @intCast(@ctz(eligible));
        var before: [percpu.MAX_CPUS]u64 = undefined;
        for (0..percpu.MAX_CPUS) |cpu| before[cpu] = tlb.deliveryCount(cpu);
        const targeted = tlb.sampleKernelCpu(TEST_VA, target);
        if (targeted.remote_mask != (@as(u64, 1) << @intCast(target)) or
            targeted.samples[target] != (0x516c_00b0_0000_0000 | @as(u64, 31))) ok = false;
        for (0..percpu.MAX_CPUS) |cpu| {
            const expected = before[cpu] + @as(u64, if (cpu == target) 1 else 0);
            if (tlb.deliveryCount(cpu) != expected) ok = false;
        }
        if (ok) console.print("[pass] TLB targeted IPI: CPU {d} only\n", .{target});
    }
    if (vmm.translate(vmm.kernelPml4(), TEST_VA) != null) {
        _ = vmm.clearKernelPage(TEST_VA) orelse unreachable;
        tlb.invalidate(0, TEST_VA);
    }
    if (vmm.translate(vmm.kernelPml4(), TEST_VA) != null) ok = false;
    if (smp.cpusOnline() > 1 and @popCount(observed) < smp.cpusOnline() - 1) ok = false;
    if (ok) {
        console.print("[pass] TLB IPI: 32 remaps acknowledged across {d} CPUs\n", .{smp.cpusOnline()});
    } else {
        console.err("TLB IPI remap/readback probe failed", .{});
    }
}

fn samplesMatch(result: tlb.Result, expected: u64) bool {
    if (@popCount(result.remote_mask) != smp.cpusOnline() - 1) return false;
    if (result.remote_mask & (@as(u64, 1) << @intCast(percpu.cpuIndex())) != 0) return false;
    for (0..percpu.MAX_CPUS) |cpu| {
        if (result.remote_mask & (@as(u64, 1) << @intCast(cpu)) != 0 and
            result.samples[cpu] != expected) return false;
    }
    return true;
}
