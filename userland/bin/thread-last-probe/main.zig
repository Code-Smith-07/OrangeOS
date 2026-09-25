//! The first thread may leave while another continues. The program exits when
//! its last thread does, with that thread's status (9, not the first's 7).
const pulp = @import("pulp");

fn late(_: *anyopaque) void {
    pulp.sleepMs(50);
    pulp.threadExit(9);
}

export fn _start() callconv(.c) noreturn {
    var context: u8 = 0;
    _ = pulp.Thread.spawn(late, &context, 64 * 1024, 0) catch pulp.exit(1);
    pulp.threadExit(7);
}
