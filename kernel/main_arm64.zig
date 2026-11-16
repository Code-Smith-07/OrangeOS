//! Root of the Arm64 kernel build (`zig build arm`). The x86 kernel's root
//! is main.zig; the two share the code under lib/ and drivers/ and will
//! share more as the port advances (docs/design/015).
const start = @import("arch/aarch64/start.zig");

pub const panic = start.panic;

comptime {
    _ = start;
}
