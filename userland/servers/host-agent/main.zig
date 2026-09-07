//! Read-only transport proof. No host state is applied to guest UI yet.
const pulp = @import("pulp");
const wire = @import("host_protocol");
fn io(op: u64, bytes: []u8) i64 {
    return pulp.syscall3(110, op, @intFromPtr(bytes.ptr), bytes.len);
}
fn send(method: u16, id: u32, payload: []const u8) bool {
    var packet: [80]u8 = undefined;
    wire.header(packet[0..16], 0, method, id, payload.len) catch return false;
    @memcpy(packet[16..][0..payload.len], payload);
    return io(1, packet[0 .. 16 + payload.len]) == 16 + payload.len;
}
export fn _start() callconv(.c) noreturn {
    var empty: [0]u8 = .{};
    if (io(2, &empty) < 0) {
        pulp.puts("host-agent: disabled (no opt-in bridge)\n");
        pulp.exit(0);
    }
    var token: [64]u8 = undefined;
    if (io(3, &token) != 64) pulp.exit(1);
    // Pointer and length checks must fail before consuming transport data.
    if (pulp.syscall3(110, 3, 0, 64) != -14 or pulp.syscall3(110, 0, 0, 513) != -22) pulp.exit(2);
    pulp.puts("host-agent: PASS invalid buffers rejected\n");
    var parser: wire.Decoder = .{};
    var epoch: i64 = -1;
    var id: u32 = 0;
    var method: u16 = 1;
    var pending = false;
    var failed = false;
    var deadline: u64 = 0;
    var next_send: u64 = 0;
    var input: [512]u8 = undefined;
    while (true) {
        const status = io(2, &empty);
        if (status < 0) {
            pulp.puts("host-agent: transport stopped\n");
            pulp.exit(1);
        }
        if (epoch != status >> 8) {
            epoch = status >> 8;
            parser.reset();
            id = 0;
            method = 1;
            pending = false;
            failed = false;
            next_send = 0;
            // Discard late data from the previous companion connection.
            while (io(0, &input) > 0) {}
        }
        const now = pulp.uptimeMs();
        if (status & 2 != 0 and !failed) {
            if (!pending and now >= next_send) {
                if (send(method, id + 1, if (method == 1) &token else "")) {
                    id += 1;
                    pending = true;
                    deadline = now + 5000;
                }
            }
            const n = io(0, &input);
            if (n > 0) for (input[0..@intCast(n)]) |byte| {
                const complete = parser.feed(byte) catch {
                    failed = true;
                    break;
                };
                if (complete) {
                    const h = wire.decode(parser.buffer[0..16]) catch unreachable;
                    if (!pending or h.flags != 1 or h.method != method or h.request != id) {
                        failed = true;
                        break;
                    }
                    const payload = parser.buffer[16..parser.count];
                    for (payload) |c| {
                        if (c < 32 or c > 126) {
                            failed = true;
                            break;
                        }
                    }
                    if (failed) break;
                    if (method == 1) pulp.puts("host-agent: authenticated\n");
                    if (method == 2 or method == 3) {
                        pulp.puts(if (method == 2) "host-agent: capabilities " else "host-agent: snapshot ");
                        pulp.puts(payload);
                        pulp.puts("\n");
                    }
                    if (method == 4) pulp.puts("host-agent: pong\n");
                    pending = false;
                    parser.reset();
                    method = if (method < 4) method + 1 else 4;
                    next_send = now + (if (method == 4) @as(u64, 1000) else 0);
                }
            };
            if (pending and now > deadline) failed = true;
            if (failed) pulp.puts("host-agent: session failed; waiting for reconnect\n");
        }
        pulp.sleepMs(20);
    }
}
