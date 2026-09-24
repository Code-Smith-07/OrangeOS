//! Quiet, short-lived child for process slot and stack reclamation tests.
const pulp = @import("pulp");

export fn _start() callconv(.c) noreturn {
    pulp.exit(0);
}
