//! W^X negative probe: once code is read/execute, writing to it faults.
//! The parent expects the page-fault status (142).
const pulp = @import("pulp");

export fn _start() callconv(.c) noreturn {
    const page = pulp.mapMemory(4096, .read_write) catch pulp.exit(1);
    page[0] = 0xC3; // ret
    pulp.protectMemory(page, .read_execute) catch pulp.exit(2);
    const function: *const fn () callconv(.c) void = @ptrCast(page.ptr);
    function();
    const code: *volatile u8 = @ptrCast(page.ptr);
    code.* = 0x90;
    pulp.exit(3);
}
