//! Futex-like wait/wake keyed by a user word's physical address. This lets
//! different address spaces synchronize through the same shared-memory frame.
//! A waiter registers before checking the value, closing the lost-wakeup gap.
const sched = @import("../sched/sched.zig");
const vmm = @import("../mm/vmm.zig");
const pmm = @import("../mm/pmm.zig");
const validate = @import("../syscall/validate.zig");
const io = @import("../arch/x86_64/io.zig");
const address_space = @import("../mm/address_space.zig");

pub const Error = error{ Invalid, BadAddress, WouldBlock, Timeout };

const Word = struct {
    ptr: *const u32,
    channel: usize,
};

/// Caller holds an access to the space, which keeps the frame behind `ptr`
/// allocated until it ends.
fn resolve(pml4: u64, address: u64) Error!Word {
    if (address & 3 != 0) return error.Invalid;
    validate.checkInAccess(pml4, address, @sizeOf(u32), false) catch return error.BadAddress;
    const phys = vmm.translate(pml4, address) orelse return error.BadAddress;
    // Physical addresses are below bit 52. This tag avoids collisions with
    // kernel pointer channels, all of which live in the high canonical half.
    const channel: usize = @intCast(phys | (@as(u64, 1) << 62));
    return .{ .ptr = @ptrFromInt(pmm.physToVirt(phys)), .channel = channel };
}

/// A zero timeout waits indefinitely. Return success after a wake (which may
/// be spurious), WouldBlock if the value changed, or Timeout on expiry.
pub fn wait(pml4: u64, address: u64, expected: u32, timeout_ms: u64) Error!void {
    {
        // The word is read through its frame, which another thread could
        // unmap; the access ends before sleeping. A frame reused after that
        // can only cause a spurious wake, which callers already tolerate.
        const access = address_space.beginCurrentAccess(pml4);
        defer if (access) |a| a.end();
        const word = try resolve(pml4, address);
        sched.prepareWait(word.channel);
        if (@atomicLoad(u32, word.ptr, .acquire) != expected) {
            sched.cancelWait();
            return error.WouldBlock;
        }
    }
    // Syscall entry masks interrupts. Timed waits need timer IRQs on this CPU.
    io.sti();
    defer io.cli();
    sched.commitWaitTimeout(timeout_ms);
    if (sched.waitTimedOut()) return error.Timeout;
}

/// Return the number of registered waiters released, at most `count`.
pub fn wake(pml4: u64, address: u64, count: usize) Error!usize {
    const channel = blk: {
        const access = address_space.beginCurrentAccess(pml4);
        defer if (access) |a| a.end();
        break :blk (try resolve(pml4, address)).channel;
    };
    return sched.wakeChannelN(channel, count);
}
