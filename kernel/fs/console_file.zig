//! The console as an open file: what descriptors 0, 1 and 2 refer to.
//!
//! Input and output go to the calling program's terminal (PTY) when it has
//! one, so a shell run in a terminal window writes there without knowing
//! about windows; otherwise to the serial console. Reads block until at
//! least one byte is available and return what is there: a shell wants each
//! keystroke, not a full buffer.

const sched = @import("../sched/sched.zig");
const console = @import("../console.zig");
const serial = @import("../drivers/char/serial.zig");
const pty_mod = @import("../ipc/pty.zig");
const ipc_object = @import("../ipc/object.zig");

pub const Error = error{Interrupted};

fn currentPty() ?*ipc_object.Object {
    const proc = sched.currentProcess() orelse return null;
    return proc.pty;
}

/// Blocks; call with interrupts enabled (the bytes arrive by interrupt).
pub fn read(buf: []u8) Error!usize {
    if (buf.len == 0) return 0;
    const want = @min(buf.len, 256);
    if (currentPty()) |obj| {
        const channel = pty_mod.waitChannel(&obj.data.pty);
        while (true) {
            if (sched.killPending()) return Error.Interrupted;
            // Register before reading, so a write arriving in between
            // cancels the wait instead of being missed.
            sched.prepareWait(channel);
            const n = pty_mod.slaveRead(&obj.data.pty, buf[0..want]);
            if (n != 0) {
                sched.cancelWait();
                return n;
            }
            sched.commitWait();
        }
    }
    const channel = serial.waitChannel();
    while (true) {
        if (sched.killPending()) return Error.Interrupted;
        sched.prepareWait(channel);
        var n: usize = 0;
        while (n < want) {
            buf[n] = serial.readByte() orelse break;
            n += 1;
        }
        if (n != 0) {
            sched.cancelWait();
            return n;
        }
        sched.commitWait();
    }
}

pub fn write(data: []const u8) usize {
    if (currentPty()) |obj| return pty_mod.slaveWrite(&obj.data.pty, data);
    console.write(data);
    return data.len;
}
