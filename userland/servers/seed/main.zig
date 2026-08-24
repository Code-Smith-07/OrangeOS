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
