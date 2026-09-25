//! Filesystem verification.
//!
//! Reads real files off a real disk and checks their contents byte for byte
//! against what mkcitrusfs wrote.

const std = @import("std");
const vfs = @import("vfs/vfs.zig");
const fd_mod = @import("fd.zig");
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
        check("read /etc/os-release contains its version string", std.mem.indexOf(u8, buf[0..n], "0.1.0") != null);
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
    var files: fd_mod.FileTable = .{};
    if (fd_mod.open(&files, "/etc/motd", 0)) |fd| {
        const size = (fd_mod.statFd(&files, fd) catch fd_mod.Status{ .size = 0, .kind = .file, .mode = 0 }).size;
        var small: [8]u8 = undefined;
        const n1 = fd_mod.readFd(&files, fd, &small) catch 0;
        const n2 = fd_mod.readFd(&files, fd, &small) catch 0;
        check("open/read advances the file offset", n1 == 8 and n2 > 0 and size > 8);
        fd_mod.close(&files, fd) catch {};
        check("close then use of a stale fd is refused", fd_mod.readFd(&files, fd, &small) == vfs.Error.BadFd);
    } else |_| check("open /etc/motd", false);

    // The init binary must be present and look like an ELF.
    var head: [4]u8 = undefined;
    if (vfs.resolve("/sbin/init")) |node| {
        const n = vfs.readAt(&node, 0, &head) catch 0;
        check("/sbin/init exists and starts with the ELF magic", n == 4 and std.mem.eql(u8, &head, "\x7fELF"));
    } else |_| check("/sbin/init exists", false);

    tmpfsChecks();

    console.print("\n[{s}] filesystem: {d} passed, {d} failed\n", .{
        if (failed == 0) " ok " else "FAIL", passed, failed,
    });

    vfs.listDir("/") catch {};
    vfs.listDir("/etc") catch {};
}

fn tmpfsChecks() void {
    var buffer: [vfs.MAX_PATH]u8 = undefined;
    const canonical = vfs.normalize("//tmp/./a/../b//c/", &buffer) catch "";
    check("paths normalize '.', '..' and repeated slashes", std.mem.eql(u8, canonical, "/tmp/b/c"));
    const above_root = vfs.normalize("/../..", &buffer) catch "";
    check("'..' at the root stays at the root", std.mem.eql(u8, above_root, "/"));

    const before = vfs.usage("/tmp") catch {
        check("/tmp is mounted", false);
        return;
    };
    check("/tmp is writable", !before.read_only and before.free_bytes > 0);
    check("the root filesystem refuses changes", vfs.mkdir("/etc/new") == vfs.Error.ReadOnly);
    check("an existing root path reports EEXIST to mkdir", vfs.mkdir("/etc") == vfs.Error.Exists);

    var files: fd_mod.FileTable = .{};
    check("mkdir /tmp/kernel-test", if (vfs.mkdir("/tmp/kernel-test")) |_| true else |_| false);
    const flags = vfs.OPEN_READ | vfs.OPEN_WRITE | vfs.OPEN_CREATE | vfs.OPEN_EXCLUSIVE;
    const fd = fd_mod.open(&files, "/tmp/kernel-test/data", flags) catch {
        check("create /tmp/kernel-test/data", false);
        return;
    };
    // Three pages plus a tail, written one byte pattern per page.
    var page: [4096]u8 = undefined;
    var ok = true;
    for (0..3) |i| {
        @memset(&page, @intCast('a' + i));
        ok = ok and (fd_mod.writeFd(&files, fd, &page) catch 0) == page.len;
    }
    ok = ok and (fd_mod.writeFd(&files, fd, "tail") catch 0) == 4;
    check("write three pages and a tail", ok and ((fd_mod.statFd(&files, fd) catch fd_mod.Status{ .size = 0, .kind = .file, .mode = 0 }).size) == 3 * 4096 + 4);
    _ = fd_mod.seekFd(&files, fd, 4094, .set) catch 0;
    var across: [4]u8 = undefined;
    const got = fd_mod.readFd(&files, fd, &across) catch 0;
    check("a read across a page boundary", got == 4 and std.mem.eql(u8, &across, "aabb"));
    check("exclusive create of an existing file fails", fd_mod.open(&files, "/tmp/kernel-test/data", flags) == vfs.Error.Exists);
    check("rmdir of a non-empty directory fails", vfs.remove("/tmp/kernel-test", true) == vfs.Error.NotEmpty);
    check("unlink while open", if (vfs.remove("/tmp/kernel-test/data", false)) |_| true else |_| false);
    _ = fd_mod.seekFd(&files, fd, 0, .set) catch 0;
    check("an unlinked open file stays readable", (fd_mod.readFd(&files, fd, &across) catch 0) == 4 and across[0] == 'a');
    fd_mod.close(&files, fd) catch {};
    check("rmdir of the emptied directory", if (vfs.remove("/tmp/kernel-test", true)) |_| true else |_| false);
    const after = vfs.usage("/tmp") catch before;
    check("closing the last handle returns every page", after.free_bytes == before.free_bytes);
}
