//! Seed — PID 1.
//!
//! Reads /etc/seed.conf, starts services in the order listed, then supervises
//! them: a service that exits is restarted, with a cap so a service that
//! crashes immediately on every start does not spin forever.
//!
//! Config format, one service per line:
//!
//!     <name> <path> <policy>
//!
//! where policy is `respawn` (restart forever), `once` (start and forget), or
//! `essential` (restart, and treat repeated failure as fatal).

const std = @import("std");
const pulp = @import("pulp");

const CONF = "/etc/seed.conf";
const MAX_SERVICES = 8;
const MAX_RESTARTS = 5;

const Policy = enum { once, respawn, essential };

const Service = struct {
    name: [32]u8 = undefined,
    name_len: usize = 0,
    path: [64]u8 = undefined,
    path_len: usize = 0,
    policy: Policy = .once,
    pid: i64 = -1,
    restarts: u32 = 0,
    dead: bool = false,

    fn nameSlice(self: *const Service) []const u8 {
        return self.name[0..self.name_len];
    }
    fn pathSlice(self: *const Service) []const u8 {
        return self.path[0..self.path_len];
    }
};

var services: [MAX_SERVICES]Service = undefined;
var service_count: usize = 0;

fn banner() void {
    pulp.puts("\n");
    pulp.puts("  \x1b[38;5;208mSeed\x1b[0m - init, pid ");
    pulp.print("{d}\n", .{pulp.getpid()});
}

fn parsePolicy(s: []const u8) Policy {
    if (pulp.eql(s, "respawn")) return .respawn;
    if (pulp.eql(s, "essential")) return .essential;
    return .once;
}

fn loadConfig() void {
    const fd = pulp.open(CONF) catch {
        pulp.print("  {s} not found; starting the shell only\n", .{CONF});
        addService("juice", "/bin/juice", .essential);
        return;
    };
    defer pulp.close(fd);

    var buf: [1024]u8 = undefined;
    const n = pulp.read(@intCast(fd), &buf) catch 0;
    if (n == 0) return;

    var start: usize = 0;
    var i: usize = 0;
    while (i <= n) : (i += 1) {
        if (i < n and buf[i] != '\n') continue;
        const line = buf[start..i];
        start = i + 1;
        if (line.len == 0 or line[0] == '#') continue;

        var fields: [4][]const u8 = undefined;
        const count = pulp.tokenize(line, &fields);
        if (count < 2) continue;

        addService(
            fields[0],
            fields[1],
            if (count > 2) parsePolicy(fields[2]) else .once,
        );
    }
}

fn addService(name: []const u8, path: []const u8, policy: Policy) void {
    if (service_count >= MAX_SERVICES) return;
    var s = &services[service_count];
    s.* = .{};
    s.name_len = @min(name.len, s.name.len);
    @memcpy(s.name[0..s.name_len], name[0..s.name_len]);
    s.path_len = @min(path.len, s.path.len);
    @memcpy(s.path[0..s.path_len], path[0..s.path_len]);
    s.policy = policy;
    service_count += 1;
}

fn startService(s: *Service) void {
    s.pid = pulp.spawn(s.pathSlice()) catch {
        pulp.print("  \x1b[38;5;208m[fail]\x1b[0m {s} - cannot exec {s}\n", .{
            s.nameSlice(), s.pathSlice(),
        });
        s.dead = true;
        return;
    };
    pulp.print("  [ ok ] {s} started (pid {d})\n", .{ s.nameSlice(), s.pid });
}

export fn _start() callconv(.c) noreturn {
    banner();
    if (pulp.runtime_test) {
        for (0..3) |_| {
            const probe = pulp.spawn("/bin/vm-probe") catch pulp.exit(90);
            const result = pulp.wait(probe) catch pulp.exit(91);
            if (result != 0) {
                pulp.puts("runtime: FAIL VM probe\n");
                pulp.exit(92);
            }
        }
        pulp.puts("runtime: PASS repeated VM processes\n");
        const faults = [_]struct { path: []const u8, code: i64 }{
            .{ .path = "/bin/fault-null", .code = 142 },
            .{ .path = "/bin/fault-ro", .code = 142 },
            .{ .path = "/bin/fault-nx", .code = 142 },
            .{ .path = "/bin/fault-opcode", .code = 134 },
        };
        for (faults) |fault| {
            const child = pulp.spawn(fault.path) catch pulp.exit(93);
            const code = pulp.wait(child) catch pulp.exit(94);
            if (code != fault.code) {
                pulp.print("runtime: FAIL {s} exit {d}\n", .{ fault.path, code });
                pulp.exit(95);
            }
        }
        pulp.puts("runtime: PASS null, read-only, NX and invalid-opcode containment\n");
        // Distinct live processes compete for two CPUs; a second wave checks
        // that later processes never inherit the previous users' register data.
        for (0..2) |_| {
            var pids: [6]i64 = undefined;
            for (&pids) |*pid| pid.* = pulp.spawn("/bin/simd-probe") catch pulp.exit(96);
            for (pids) |pid| {
                const code = pulp.wait(pid) catch pulp.exit(97);
                if (code != 0) {
                    pulp.print("runtime: FAIL SIMD process {d} exit {d}\n", .{ pid, code });
                    pulp.exit(98);
                }
            }
        }
        pulp.puts("runtime: PASS concurrent SIMD process isolation\n");
        for (0..2) |_| {
            var pids: [6]i64 = undefined;
            for (&pids) |*pid| pid.* = pulp.spawn("/bin/tls-probe") catch pulp.exit(139);
            for (pids) |pid| {
                const code = pulp.wait(pid) catch pulp.exit(140);
                if (code != 0) {
                    pulp.print("runtime: FAIL TLS process {d} exit {d}\n", .{ pid, code });
                    pulp.exit(141);
                }
            }
        }
        pulp.puts("runtime: PASS per-task FS TLS across two CPUs\n");
        var c_probes: [4]i64 = undefined;
        for (&c_probes) |*pid| pid.* = pulp.spawn("/bin/c-abi-probe") catch pulp.exit(99);
        for (c_probes) |pid| {
            const code = pulp.wait(pid) catch pulp.exit(100);
            if (code != 0) pulp.exit(101);
        }
        pulp.puts("runtime: PASS freestanding C floating-point ABI\n");
        // More than the registry's 64 concurrent slots must be possible over
        // the machine's lifetime once each child has been waited/reaped.
        for (0..96) |_| {
            const child = pulp.spawn("/bin/reap-probe") catch pulp.exit(102);
            if ((pulp.wait(child) catch pulp.exit(103)) != 0) pulp.exit(104);
            if (pulp.syscall2(pulp.NR.wait, @bitCast(child), 1) != -10) pulp.exit(105);
        }
        if (pulp.syscall2(pulp.NR.wait, 1, 1) != -10) pulp.exit(106);
        pulp.puts("runtime: PASS 96 child reaps, slot reuse and wait ownership\n");
        var children: [64]i64 = undefined;
        var child_count: usize = 0;
        while (child_count < children.len) {
            const child = pulp.spawn("/bin/reap-probe") catch |err| {
                if (err != error.NoMemory) pulp.exit(107);
                break;
            };
            children[child_count] = child;
            child_count += 1;
        }
        if (child_count < 32 or child_count == children.len) pulp.exit(108);
        for (children[0..child_count]) |child| {
            if ((pulp.wait(child) catch pulp.exit(109)) != 0) pulp.exit(110);
        }
        const reused = pulp.spawn("/bin/reap-probe") catch pulp.exit(111);
        if ((pulp.wait(reused) catch pulp.exit(112)) != 0) pulp.exit(113);
        pulp.puts("runtime: PASS full task table rejects spawn and recovers after reaping\n");
        // Eight waves exceed the registry's lifetime capacity. Each parent
        // abandons two children, one short-lived and one still running.
        for (0..8) |_| {
            var parents: [12]i64 = undefined;
            for (&parents) |*pid| pid.* = pulp.spawn("/bin/orphan-probe") catch |err| {
                pulp.print("runtime: orphan spawn failed {s}\n", .{@errorName(err)});
                pulp.exit(114);
            };
            for (parents) |pid| {
                const code = pulp.wait(pid) catch pulp.exit(115);
                if (code != 0) {
                    pulp.print("runtime: orphan parent {d} exit {d}\n", .{ pid, code });
                    pulp.exit(116);
                }
            }
            pulp.sleepMs(250);
        }
        const after_orphans = pulp.spawn("/bin/reap-probe") catch pulp.exit(117);
        if ((pulp.wait(after_orphans) catch pulp.exit(118)) != 0) pulp.exit(119);
        pulp.puts("runtime: PASS orphan children are collected across 96 parent exits\n");
        const parent_fd = pulp.open("/etc/motd") catch pulp.exit(120);
        var text: [4]u8 = undefined;
        if ((pulp.read(@intCast(parent_fd), &text) catch pulp.exit(121)) != 4 or
            !std.mem.eql(u8, &text, "Welc")) pulp.exit(122);
        for (0..96) |_| {
            const child = pulp.spawn("/bin/fd-probe") catch pulp.exit(123);
            if ((pulp.wait(child) catch pulp.exit(124)) != 0) pulp.exit(125);
        }
        if ((pulp.read(@intCast(parent_fd), &text) catch pulp.exit(126)) != 4 or
            !std.mem.eql(u8, &text, "ome ")) pulp.exit(127);
        pulp.close(parent_fd);
        pulp.puts("runtime: PASS private file descriptors and 96 exit cleanups\n");
        const parent_udp = pulp.udpOpen(0) catch pulp.exit(128);
        if (parent_udp != 0) pulp.exit(129);
        for (0..48) |_| {
            const child = pulp.spawn("/bin/socket-probe") catch pulp.exit(130);
            if ((pulp.wait(child) catch pulp.exit(131)) != 0) pulp.exit(132);
        }
        var datagram: [1]u8 = undefined;
        if (pulp.syscall3(pulp.NR.udp_recv, @bitCast(parent_udp), @intFromPtr(&datagram), 1) != -11) pulp.exit(133);
        pulp.udpClose(parent_udp);
        const reopened_udp = pulp.udpOpen(0) catch pulp.exit(134);
        if (reopened_udp != 0) pulp.exit(135);
        pulp.udpClose(reopened_udp);
        pulp.puts("runtime: PASS private UDP sockets and 48 exit cleanups\n");
        for (0..96) |_| {
            const child = pulp.spawn("/bin/ipc-probe") catch pulp.exit(136);
            const code = pulp.wait(child) catch pulp.exit(137);
            if (code != 0) {
                pulp.print("runtime: FAIL IPC probe exit {d}\n", .{code});
                pulp.exit(138);
            }
        }
        pulp.puts("runtime: PASS 96 IPC registry reuse, mappings and exit cleanups\n");
    }
    loadConfig();

    pulp.print("  {d} service(s) configured\n\n", .{service_count});

    var i: usize = 0;
    while (i < service_count) : (i += 1) startService(&services[i]);

    pulp.puts("\n");

    // Supervise by polling every service without blocking, then sleeping.
    // Waiting on each in turn does not work: greetd never exits, so a blocking
    // wait on it would mean never noticing that the shell had died.
    while (true) {
        var alive: usize = 0;

        i = 0;
        while (i < service_count) : (i += 1) {
            const s = &services[i];
            if (s.dead or s.pid < 0) continue;

            const result = pulp.waitNoHang(s.pid) catch {
                s.dead = true;
                continue;
            };

            const code = result orelse {
                alive += 1; // still running
                continue;
            };

            switch (s.policy) {
                .once => {
                    pulp.print("  {s} finished ({d})\n", .{ s.nameSlice(), code });
                    s.dead = true;
                },
                .respawn, .essential => {
                    s.restarts += 1;
                    if (s.restarts > MAX_RESTARTS) {
                        pulp.print("  {s} failed {d} times; giving up\n", .{
                            s.nameSlice(), s.restarts,
                        });
                        s.dead = true;
                        continue;
                    }
                    pulp.print("\n  seed: {s} exited ({d}); restarting\n", .{
                        s.nameSlice(), code,
                    });
                    startService(s);
                    alive += 1;
                },
            }
        }

        if (alive == 0) {
            pulp.puts("\n  seed: no services left to supervise.\n");
            pulp.exit(0);
        }

        pulp.sleepMs(200);
    }
}
