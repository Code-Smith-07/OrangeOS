//! Unit tests for the Arm64 code that can run on the build machine:
//!   zig test kernel/arm64_tests.zig
test {
    _ = @import("arch/aarch64/fdt.zig");
    _ = @import("arch/aarch64/pte.zig");
}
