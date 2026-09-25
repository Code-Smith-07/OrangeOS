//! Program entry for C programs linked against musl on OrangeOS.
//!
//! The kernel enters `_start` with rsp at a zero return slot, directly above
//! which sits the SysV initial stack (argc, argv, envp, auxiliary vector).
//! musl's __libc_start_main takes it from there: TLS, stdio, constructors,
//! then main, then exit.
//!
//! SPDX-License-Identifier: MIT OR Apache-2.0

comptime {
    asm (
        \\.text
        \\.global _start
        \\.type _start,@function
        \\_start:
        \\    xor %ebp,%ebp
        \\    lea 8(%rsp),%rdi
        \\    and $-16,%rsp
        \\    call __orange_start_c
        \\    ud2
    );
}

const Argv = [*]?[*:0]u8;
extern fn __libc_start_main(
    main: *const fn (c_int, Argv, Argv) callconv(.c) c_int,
    argc: c_int,
    argv: Argv,
    init: *const fn () callconv(.c) void,
    fini: *const fn () callconv(.c) void,
    ldso_dummy: ?*const anyopaque,
) c_int;
extern fn main(argc: c_int, argv: Argv, envp: Argv) c_int;
extern fn _init() callconv(.c) void;
extern fn _fini() callconv(.c) void;

export fn __orange_start_c(stack: [*]usize) callconv(.c) noreturn {
    const argc: c_int = @intCast(stack[0]);
    const argv: Argv = @ptrFromInt(@intFromPtr(stack) + @sizeOf(usize));
    _ = __libc_start_main(&main, argc, argv, &_init, &_fini, null);
    unreachable;
}
