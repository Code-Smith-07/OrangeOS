//! User process creation.
//!
//! A process is an address space plus a thread running in ring 3. Phase 4b
//! creates one directly from an embedded ELF image; Phase 5 will load them
//! from a filesystem and Phase 6 adds fork/exec.

const std = @import("std");
const vmm = @import("../mm/vmm.zig");
const pmm = @import("../mm/pmm.zig");
const elf = @import("../lib/elf.zig");
const user = @import("../arch/x86_64/user.zig");
const gdt = @import("../arch/x86_64/gdt.zig");
const percpu = @import("../arch/x86_64/percpu.zig");
const task_mod = @import("task.zig");
const sched = @import("sched.zig");
const console = @import("../console.zig");

pub const Error = error{OutOfMemory} || elf.Error;

/// User stack: 64 KiB, placed just below the non-canonical boundary.
const USER_STACK_TOP: u64 = 0x0000_7FFF_FFFF_F000;
const USER_STACK_PAGES: usize = 16;

/// Build an address space from an ELF image and drop into ring 3.
/// Runs as the body of a kernel thread; never returns.
pub fn execImage(image: []const u8) Error!noreturn {
    const pml4 = try vmm.createAddressSpace();

    const loaded = try elf.load(pml4, image);

    // User stack, mapped writable and non-executable.
    var i: usize = 0;
    while (i < USER_STACK_PAGES) : (i += 1) {
        const va = USER_STACK_TOP - (i + 1) * vmm.PAGE_SIZE;
        _ = vmm.allocAndMap(
            pml4,
            va,
            vmm.PRESENT | vmm.WRITABLE | vmm.USER | vmm.NO_EXECUTE,
        ) catch return Error.OutOfMemory;
    }

    // Point the CPU at this thread's kernel stack for the transition back.
    // Both matter: the TSS supplies rsp0 on an interrupt from ring 3, and the
    // per-CPU block supplies it on a syscall, which does not switch stacks.
    const t = sched.currentTask() orelse return Error.OutOfMemory;
    const kstack_top = task_mod.kstackTop(t);
    gdt.setKernelStack(kstack_top);
    percpu.setKernelStack(kstack_top);

    console.print("[ ok ] loaded ELF: entry 0x{x}, brk 0x{x}\n", .{ loaded.entry, loaded.brk });
    console.print("[ ok ] user stack: {d} KiB at 0x{x}\n", .{
        USER_STACK_PAGES * vmm.PAGE_SIZE / 1024,
        USER_STACK_TOP - USER_STACK_PAGES * vmm.PAGE_SIZE,
    });
    console.info("entering ring 3...", .{});

    vmm.loadCr3(pml4);
    user.enter(loaded.entry, USER_STACK_TOP);
}

/// Thread body: runs the embedded init image.
pub fn initThread(arg: ?*anyopaque) void {
    _ = arg;
    const image = @embedFile("init_elf");
    execImage(image) catch |e| {
        console.err("failed to start init: {s}", .{@errorName(e)});
        sched.exit(1);
    };
}
