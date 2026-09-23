//! Authenticated readback; only non-identifying hardware state is published.
const pulp = @import("pulp");
const std = @import("std");
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
    if (pulp.syscall3(112, 2, 0, 16) != -14 or pulp.syscall3(112, 2, 0, 17) != -22 or pulp.syscall3(112, 0, 50, 103) != -13) pulp.exit(2);
    pulp.puts("host-agent: PASS sound mailbox bounds and authority\n");
    if (pulp.syscall3(111, 1, 0, 1) != -14 or pulp.syscall3(111, 1, 0, 4097) != -22) pulp.exit(2);
    var parser: wire.Decoder = .{};
    var epoch: i64 = -1;
    var id: u32 = 0;
    var method: u16 = 1;
    var pending = false;
    var failed = false;
    var deadline: u64 = 0;
    var next_send: u64 = 0;
    var snapshot_checked = false;
    var input: [512]u8 = undefined;
    var command: extern struct { id: u32, percent: u32, device: u32, reserved: u32 } = undefined;
    var command_id: u32 = 0;
    var command_payload: [12]u8 = undefined;
    while (true) {
        const status = io(2, &empty);
        if (status < 0) {
            _ = pulp.syscall3(112, 4, 0, 0);
            _ = pulp.syscall3(111, 1, 0, 0);
            pulp.puts("host-agent: transport stopped\n");
            pulp.exit(1);
        }
        if (epoch != status >> 8) {
            _ = pulp.syscall3(112, 4, 0, 0);
            command_id = 0;
            _ = pulp.syscall3(111, 1, 0, 0);
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
            if (!pending and method >= 4 and command_id == 0 and pulp.syscall3(112, 2, @intFromPtr(&command), @sizeOf(@TypeOf(command))) == @sizeOf(@TypeOf(command))) {
                command_id = command.id;
                std.mem.writeInt(u32, command_payload[0..4], 1, .little);
                std.mem.writeInt(u32, command_payload[4..8], command.percent, .little);
                std.mem.writeInt(u32, command_payload[8..12], command.device, .little);
                method = 6;
                next_send = 0;
            }
            if (!pending and now >= next_send) {
                if (send(method, id + 1, if (method == 1) &token else if (method == 6) &command_payload else "")) {
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
                    if (!pending or (h.flags != 1 and !(method == 6 and h.flags == 2)) or h.method != method or h.request != id) {
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
                    if (method == 6) {
                        const outcome: i64 = if (h.flags == 1 and std.mem.eql(u8, payload, "{\"status\":\"applied\"}")) 0 else if (std.mem.indexOf(u8, payload, "permission_denied") != null) -13 else if (std.mem.indexOf(u8, payload, "unsupported") != null) -95 else if (std.mem.indexOf(u8, payload, "route_changed") != null) -116 else -5;
                        _ = pulp.syscall3(112, 3, command_id, @bitCast(outcome));
                        command_id = 0;
                        pulp.print("host-agent: sound command result {d}\n", .{outcome});
                    }
                    if (method == 5) {
                        if (pulp.syscall3(111, 1, @intFromPtr(payload.ptr), payload.len) != payload.len) {
                            failed = true;
                            break;
                        }
                        if (!snapshot_checked) {
                            if (pulp.syscall3(111, 0, 0, 4096) != -14 or pulp.syscall3(111, 0, 0, 0) != -22) pulp.exit(2);
                            snapshot_checked = true;
                            pulp.puts("host-agent: PASS snapshot bounds and pointers rejected\n");
                        }
                    }
                    if (method == 1) pulp.puts("host-agent: authenticated\n");
                    if (method == 2 or method == 3 or method == 5) {
                        pulp.puts(if (method == 2) "host-agent: capabilities " else if (method == 5) "host-agent: hardware " else "host-agent: snapshot ");
                        pulp.puts(payload);
                        pulp.puts("\n");
                    }
                    if (method == 4) pulp.puts("host-agent: pong\n");
                    pending = false;
                    parser.reset();
                    method = if (method < 3) method + 1 else if (method == 3 or method == 4 or method == 6) 5 else 4;
                    next_send = now + (if (method >= 4) @as(u64, 1000) else 0);
                }
            };
            if (pending and now > deadline) failed = true;
            if (failed) {
                _ = pulp.syscall3(112, 4, 0, 0);
                _ = pulp.syscall3(111, 1, 0, 0);
                pulp.puts("host-agent: session failed; waiting for reconnect\n");
            }
        }
        pulp.sleepMs(20);
    }
}
