//! Filesystem verification.
//!
//! Reads real files off a real disk and checks their contents byte for byte
//! against what mkcitrusfs wrote.

const std = @import("std");
const vfs = @import("vfs/vfs.zig");
const console = @import("../console.zig");

var passed: usize = 0;
var failed: usize = 0;

fn check(name: []const u8, ok: bool) void {
    if (ok) {
        passed += 1;
        console.print("  [pass] {s}\n", .{name});
    } else {
        failed += 1;
        console.print("  [FAIL] {s}\n", .{name});
    }
}

pub fn run() void {
    if (!vfs.isMounted()) {
        console.warn("filesystem tests skipped: nothing mounted", .{});
        return;
    }

    console.write("\n");
    console.info("filesystem tests:", .{});
    passed = 0;
    failed = 0;

    // Root must resolve and be a directory.
    if (vfs.resolve("/")) |root| {
        check("resolve \"/\" returns a directory", root.isDir());
    } else |_| check("resolve \"/\"", false);

    // Nested path resolution.
    if (vfs.resolve("/etc")) |etc| {
        check("resolve \"/etc\" returns a directory", etc.isDir());
    } else |_| check("resolve \"/etc\"", false);

    // Read a file and compare its exact contents.
    var buf: [512]u8 = undefined;
    if (vfs.readFileInto("/etc/motd", &buf)) |n| {
        const expected = "Welcome to Orange OS.\n";
        const got = buf[0..n];
        check("read /etc/motd returns the exact expected bytes", std.mem.eql(u8, got, expected));
        if (!std.mem.eql(u8, got, expected)) {
            console.print("         got {d} bytes: \"{s}\"\n", .{ n, got });
        }
    } else |e| {
        console.print("  [FAIL] read /etc/motd: {s}\n", .{@errorName(e)});
        failed += 1;
    }

    // A multi-line file, to prove offsets past the first read work.
    if (vfs.readFileInto("/etc/os-release", &buf)) |n| {
        check("read /etc/os-release contains its version string",
            std.mem.indexOf(u8, buf[0..n], "0.1.0") != null);
    } else |_| check("read /etc/os-release", false);

    // A missing path must be an error, not an empty success.
    const missing = vfs.resolve("/etc/does-not-exist");
    check("missing path returns NotFound", missing == vfs.Error.NotFound);

    // Reading a directory as a file must be refused.
    if (vfs.resolve("/etc")) |etc| {
        const bad = vfs.readAt(&etc, 0, &buf);
        check("reading a directory as a file is refused", bad == vfs.Error.NotFile);
    } else |_| {}

    // The file descriptor path.
    if (vfs.open("/etc/motd")) |fd| {
        const size = vfs.statSize(fd) catch 0;
        var small: [8]u8 = undefined;
        const n1 = vfs.read(fd, &small) catch 0;
        const n2 = vfs.read(fd, &small) catch 0;
        check("open/read advances the file offset", n1 == 8 and n2 > 0 and size > 8);
        vfs.close(fd) catch {};
        check("close then use of a stale fd is refused", vfs.read(fd, &small) == vfs.Error.BadFd);
    } else |_| check("open /etc/motd", false);

    // The init binary must be present and look like an ELF.
    var head: [4]u8 = undefined;
    if (vfs.resolve("/sbin/init")) |node| {
        const n = vfs.readAt(&node, 0, &head) catch 0;
        check("/sbin/init exists and starts with the ELF magic",
            n == 4 and std.mem.eql(u8, &head, "\x7fELF"));
    } else |_| check("/sbin/init exists", false);

    console.print("\n[{s}] filesystem: {d} passed, {d} failed\n", .{
        if (failed == 0) " ok " else "FAIL", passed, failed,
    });

    vfs.listDir("/") catch {};
    vfs.listDir("/etc") catch {};
}
