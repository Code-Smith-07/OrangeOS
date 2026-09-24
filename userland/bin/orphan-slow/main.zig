//! Child that remains live briefly after its parent exits.
const pulp = @import("pulp");

export fn _start() callconv(.c) noreturn {
    pulp.sleepMs(100);
    pulp.exit(0);
}
