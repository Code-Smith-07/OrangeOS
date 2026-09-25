//! A fault in one thread ends the whole program, including a first thread
//! blocked indefinitely. The parent expects the page-fault status (142).
const pulp = @import("pulp");

var word: u32 = 0;

fn crasher(_: *anyopaque) void {
    pulp.sleepMs(10);
    asm volatile ("movq $0, %%rax; movq (%%rax), %%rax" ::: "rax", "memory");
}

export fn _start() callconv(.c) noreturn {
    var context: u8 = 0;
    _ = pulp.Thread.spawn(crasher, &context, 64 * 1024, 0) catch pulp.exit(1);
    while (true) pulp.waitWord(&word, 0, 0) catch {};
}
