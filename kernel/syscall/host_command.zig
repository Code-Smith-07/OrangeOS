//! Bounded VM-to-host audio/display request mailbox. Only the read-only system
//! hardware app may submit; only the boot-authorized agent may dispatch/ack.
const std = @import("std");
const sched = @import("../sched/sched.zig");
const sync = @import("../sync/spinlock.zig");
const validate = @import("validate.zig");
const time = @import("../time/time.zig");
const Command = extern struct { id: u32, percent: u32, device: u32, kind: u32 = 1 };
var lock: sync.SpinLock = .{};
var command: Command = .{ .id = 0, .percent = 0, .device = 0 };
var serial: u32 = 0;
var owner: u32 = 0;
var active = false;
var taken = false;
var done = false;
var result: i64 = -11;
var deadline: u64 = 0;

pub fn operation(op: u64, arg0: u64, arg1: u64) i64 {
    const task = sched.currentTask() orelse return -13;
    if (((op <= 1 or op == 5) and !task.host_controls) or (op >= 2 and op != 5 and !task.host_bridge)) return -13;
    if (op > 5) return -22;
    if (op == 2) {
        if (arg1 != @sizeOf(Command)) return -22;
        validate.check(task.pageTable(), arg0, @sizeOf(Command), true) catch return -14;
    }
    const now = time.millisSinceBoot();
    const irq = sync.acquireIrqSave(&lock);
    defer sync.releaseIrqRestore(&lock, irq);
    if (active and !done and now >= deadline) {
        done = true;
        result = -110;
    }
    switch (op) {
        0, 5 => {
            if (arg0 > 100 or (op == 5 and arg0 < 5) or arg1 == 0 or arg1 > std.math.maxInt(u32)) return -22;
            if (active and now < deadline + 6000) return -16;
            if (serial == std.math.maxInt(u32)) return -75;
            serial += 1;
            command = .{ .id = serial, .percent = @intCast(arg0), .device = @intCast(arg1), .kind = if (op == 5) 2 else 1 };
            owner = task.tid;
            active = true;
            done = false;
            taken = false;
            result = -11;
            deadline = now + 6000;
            return serial;
        },
        1 => {
            if (!active or owner != task.tid or command.id != arg0 or arg1 != 0) return -2;
            if (!done) return -11;
            active = false;
            return result;
        },
        2 => {
            if (!active or done or taken) return -11;
            validate.copyToUser(task.pageTable(), arg0, std.mem.asBytes(&command), @sizeOf(Command)) catch return -14;
            taken = true;
            return @sizeOf(Command);
        },
        3 => {
            if (!active or done or !taken or command.id != arg0) return -2;
            const status: i64 = @bitCast(arg1);
            if (status != 0 and status != -13 and status != -95 and status != -5 and status != -116) return -22;
            result = status;
            done = true;
            return 0;
        },
        4 => {
            if (active and !done) {
                done = true;
                result = -107;
            }
            return 0;
        },
        else => unreachable,
    }
}
