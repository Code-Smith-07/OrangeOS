//! uname — print system identification.

const pulp = @import("pulp");

export fn _start() callconv(.c) noreturn {
    pulp.puts("Orange OS 0.1.0 Zest x86_64\n");
    pulp.exit(0);
}
