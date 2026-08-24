//! greetd — a demonstration IPC service.
//!
//! Creates the port "greet" and answers requests on it forever. Started by
//! Seed at boot; clients reach it by name without knowing its pid or anything
//! else about it.

const pulp = @import("pulp");

const PORT = "greet";
const REPLY_PORT = "greet.reply";

const OP_HELLO: u32 = 1;
const OP_STATS: u32 = 2;

var served: u32 = 0;

export fn _start() callconv(.c) noreturn {
    const port = pulp.portCreate(PORT) catch {
        pulp.print("greetd: cannot create port \"{s}\"\n", .{PORT});
        pulp.exit(1);
    };

    // A reply port, so the client has somewhere to be answered. A real system
    // passes a reply handle inside the request; handle transfer is future work.
    const reply = pulp.portCreate(REPLY_PORT) catch {
        pulp.print("greetd: cannot create reply port\n", .{});
        pulp.exit(1);
    };

    pulp.print("greetd: listening on \"{s}\" (handle {d})\n", .{ PORT, port });

    var buf: [256]u8 = undefined;
    while (true) {
        const n = pulp.portRecv(port, &buf, true) catch continue;
        served += 1;

        var out: [256]u8 = undefined;
        const msg = blk: {
            if (n == 0) break :blk "hello, anonymous client";
            const name = buf[0..n];
            const len = @min(name.len, out.len - 16);
            @memcpy(out[0..7], "hello, ");
            @memcpy(out[7 .. 7 + len], name[0..len]);
            break :blk out[0 .. 7 + len];
        };

        _ = pulp.portSend(reply, OP_HELLO, msg) catch {};
    }
}
