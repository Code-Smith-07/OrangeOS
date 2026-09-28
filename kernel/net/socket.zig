//! Internet sockets: TCP and UDP endpoints behind file descriptors.
//!
//! A socket is the object of one open file description (fd.zig). Stream
//! sockets own a TCP connection (tcp.zig) once they connect; datagram
//! sockets are bound to a local port and queue the datagrams that arrive
//! for it. All socket state is network state, guarded by the network lock
//! (net.zig); blocking calls register on the socket's channel before they
//! check, as pipes do, and the network thread's changes wake them and
//! notify the socket's readiness source for poll and epoll.
//!
//! Addresses are IPv4. What is not offered says so: IPv6 and named local
//! sockets fail at socket() with EAFNOSUPPORT (syscall layer), listening
//! with EOPNOTSUPP, and stream connections to 127.0.0.0/8 with ENETUNREACH.
//! Datagrams to 127.0.0.0/8 are delivered to this machine's own sockets,
//! which is also how musl's getaddrinfo (AI_ADDRCONFIG) learns that IPv4 is
//! configured: it connects a UDP socket to 127.0.0.1.

const std = @import("std");
const net = @import("net.zig");
const tcp = @import("tcp.zig");
const heap = @import("../mm/heap.zig");
const sched = @import("../sched/sched.zig");
const readiness = @import("../ipc/readiness.zig");
const tsc = @import("../time/tsc.zig");

pub const Kind = enum { stream, datagram };

pub const Error = error{
    WouldBlock,
    Interrupted,
    OutOfMemory,
    InvalidArgument,
    NotConnected,
    AlreadyConnected,
    InProgress,
    AlreadyInProgress,
    Refused,
    Reset,
    TimedOut,
    Unreachable,
    BrokenPipe,
    AddressInUse,
    AddressUnavailable,
    MessageTooLong,
    DestinationRequired,
    NotPermitted,
    NoProtocolOption,
    NotSupported,
};

pub const Endpoint = struct { ip: net.Ipv4Addr = .{ 0, 0, 0, 0 }, port: u16 = 0 };

/// Queued datagrams per socket, as bytes of payload.
const UDP_QUEUE_LIMIT: usize = 256 * 1024;
/// The largest UDP payload one unfragmented frame carries.
pub const MAX_UDP_PAYLOAD: usize = 1500 - 20 - 8;

const Datagram = struct {
    next: ?*Datagram = null,
    from: Endpoint,
    len: usize,
    data: [MAX_UDP_PAYLOAD]u8 = undefined,
};

pub const Socket = struct {
    kind: Kind,
    source: readiness.Source = .{},

    local: Endpoint = .{},
    bound: bool = false,
    remote: Endpoint = .{},
    connected: bool = false,
    /// A stream socket's connection; created by connect().
    tcb: ?*tcp.Tcb = null,
    /// A failed non-blocking connect's reason, for SO_ERROR.
    pending_error: ?Error = null,
    read_shut: bool = false,
    write_shut: bool = false,

    // Datagram sockets: an entry in the delivery list and a queue.
    next_udp: ?*Socket = null,
    queue_head: ?*Datagram = null,
    queue_tail: ?*Datagram = null,
    queued: usize = 0,

    // Options.
    reuse_address: bool = false,
    broadcast: bool = false,
    keepalive: bool = false,
    no_delay: bool = false,
    receive_timeout_ms: u64 = 0,
    send_timeout_ms: u64 = 0,
    /// SO_LINGER with a zero timeout: close with a reset.
    abortive_close: bool = false,

    fn channel(self: *const Socket) usize {
        return @intFromPtr(self);
    }
};

var udp_sockets: ?*Socket = null;
var next_udp_port: u16 = 32768;

pub fn create(kind: Kind) Error!*Socket {
    const s = heap.create(Socket) catch return Error.OutOfMemory;
    s.* = .{ .kind = kind };
    return s;
}

pub fn source(s: *Socket) *readiness.Source {
    return &s.source;
}

fn changedLocked(s: *Socket) void {
    sched.wakeChannel(s.channel());
    readiness.notify(&s.source);
}

// ── Waiting ─────────────────────────────────────────────────────────────────

/// Register, then check `ready` under the network lock; sleep until woken,
/// the timeout passes (0: none), or the program is interrupted. `ready`
/// returns null to keep waiting. Needs interrupts enabled.
fn waitFor(s: *Socket, nonblock: bool, timeout_ms: u64, context: anytype, comptime ready: fn (*Socket, @TypeOf(context)) ?Error!usize) Error!usize {
    const deadline = if (timeout_ms != 0) tsc.microsSinceBoot() + timeout_ms * 1000 else 0;
    while (true) {
        sched.prepareWait(s.channel());
        const result = blk: {
            const irq = net.acquire();
            defer net.release(irq);
            break :blk ready(s, context);
        };
        if (result) |value| {
            sched.cancelWait();
            return value;
        }
        if (nonblock) {
            sched.cancelWait();
            return Error.WouldBlock;
        }
        if (sched.interruptPending()) {
            sched.cancelWait();
            return Error.Interrupted;
        }
        if (deadline != 0) {
            const now = tsc.microsSinceBoot();
            if (now >= deadline) {
                sched.cancelWait();
                return Error.WouldBlock;
            }
            sched.commitWaitTimeout(@max((deadline - now) / 1000, 1));
        } else sched.commitWait();
    }
}

fn tcpError(e: tcp.Error) Error {
    return switch (e) {
        tcp.Error.Refused => Error.Refused,
        tcp.Error.Reset => Error.Reset,
        tcp.Error.Timeout => Error.TimedOut,
        tcp.Error.Unreachable => Error.Unreachable,
        tcp.Error.OutOfMemory, tcp.Error.NoSockets => Error.OutOfMemory,
        tcp.Error.AddressInUse => Error.AddressUnavailable,
        tcp.Error.BrokenPipe => Error.BrokenPipe,
        else => Error.NotConnected,
    };
}

// ── Addresses ───────────────────────────────────────────────────────────────

fn udpPortBusyLocked(port: u16, except: *Socket) bool {
    var cursor = udp_sockets;
    while (cursor) |other| : (cursor = other.next_udp) {
        if (other != except and other.local.port == port) return true;
    }
    return net.legacyUdpPortBusyLocked(port);
}

fn ephemeralUdpPortLocked(s: *Socket) ?u16 {
    var tries: usize = 0;
    while (tries < 28232) : (tries += 1) {
        const port = next_udp_port;
        next_udp_port = if (next_udp_port >= 60999) 32768 else next_udp_port + 1;
        if (!udpPortBusyLocked(port, s)) return port;
    }
    return null;
}

fn bindLocked(s: *Socket, at: Endpoint) Error!void {
    if (s.bound) return Error.InvalidArgument;
    const any = std.mem.eql(u8, &at.ip, &[4]u8{ 0, 0, 0, 0 });
    const loopback = s.kind == .datagram and net.isLoopback(at.ip);
    if (!any and !loopback and !std.mem.eql(u8, &at.ip, &net.local_ip)) return Error.AddressUnavailable;
    var port = at.port;
    switch (s.kind) {
        .datagram => {
            if (port == 0) port = ephemeralUdpPortLocked(s) orelse return Error.AddressInUse;
            if (udpPortBusyLocked(port, s)) return Error.AddressInUse;
            s.next_udp = udp_sockets;
            udp_sockets = s;
        },
        .stream => {
            if (port == 0) port = tcp.ephemeralPortLocked() orelse return Error.AddressInUse;
            if (!s.reuse_address and tcp.portBusyLocked(port)) return Error.AddressInUse;
        },
    }
    s.local = .{ .ip = at.ip, .port = port };
    s.bound = true;
}

pub fn bind(s: *Socket, at: Endpoint) Error!void {
    const irq = net.acquire();
    defer net.release(irq);
    return bindLocked(s, at);
}

/// getsockname: the local address, with the interface's address for a
/// connected socket bound to any.
pub fn localAddress(s: *Socket) Endpoint {
    const irq = net.acquire();
    defer net.release(irq);
    var at = s.local;
    if (s.tcb) |c| at.port = c.local_port;
    if ((s.connected or s.tcb != null) and std.mem.eql(u8, &at.ip, &[4]u8{ 0, 0, 0, 0 }))
        at.ip = if (s.connected and net.isLoopback(s.remote.ip)) LOOPBACK_IP else net.local_ip;
    return at;
}

/// getpeername.
pub fn peerAddress(s: *Socket) Error!Endpoint {
    const irq = net.acquire();
    defer net.release(irq);
    if (s.kind == .stream) {
        const c = s.tcb orelse return Error.NotConnected;
        if (c.state == .syn_sent or c.state == .closed) return Error.NotConnected;
        return .{ .ip = c.remote_ip, .port = c.remote_port };
    }
    if (!s.connected) return Error.NotConnected;
    return s.remote;
}

// ── Connecting ──────────────────────────────────────────────────────────────

const LOOPBACK_IP: net.Ipv4Addr = .{ 127, 0, 0, 1 };

fn checkDestination(to: Endpoint, kind: Kind) Error!void {
    if (to.port == 0) return Error.InvalidArgument;
    if (kind == .stream and net.isLoopback(to.ip)) return Error.Unreachable;
    if (std.mem.eql(u8, &to.ip, &[4]u8{ 0, 0, 0, 0 })) return Error.Unreachable;
}

/// connect(). A stream socket starts the handshake and, unless
/// non-blocking, waits for it; a datagram socket just records the peer.
pub fn connect(s: *Socket, to: Endpoint, nonblock: bool) Error!void {
    switch (s.kind) {
        .datagram => {
            // AF_UNSPEC (port and address 0) dissolves the association.
            const irq = net.acquire();
            defer net.release(irq);
            if (to.port == 0 and std.mem.eql(u8, &to.ip, &[4]u8{ 0, 0, 0, 0 })) {
                s.connected = false;
                return;
            }
            try checkDestination(to, .datagram);
            if (!s.bound) try bindLocked(s, .{});
            s.remote = to;
            s.connected = true;
            return;
        },
        .stream => {},
    }
    try checkDestination(to, .stream);
    {
        const irq = net.acquire();
        defer net.release(irq);
        if (s.tcb) |c| {
            if (c.state == .syn_sent) return Error.AlreadyInProgress;
            if (c.failure == null and c.state != .closed) return Error.AlreadyConnected;
            return Error.InvalidArgument;
        }
    }
    const c = tcp.create() catch return Error.OutOfMemory;
    {
        const irq = net.acquire();
        defer net.release(irq);
        if (s.tcb != null) {
            tcp.destroyUnused(c);
            return Error.AlreadyInProgress;
        }
        c.wake_channel = s.channel();
        c.source = &s.source;
        tcp.keepaliveLocked(c, s.keepalive);
        tcp.connectLocked(c, to.ip, to.port, if (s.bound) s.local.port else 0) catch |e| {
            tcp.destroyUnused(c);
            return tcpError(e);
        };
        s.tcb = c;
        s.pending_error = null;
    }
    if (nonblock) return Error.InProgress;
    _ = try waitFor(s, false, 0, {}, struct {
        fn f(sock: *Socket, _: void) ?Error!usize {
            const t = sock.tcb.?;
            if (t.state == .syn_sent) return null;
            if (t.failure) |why| return tcpError(why);
            return 0;
        }
    }.f);
}

// ── Stream I/O ──────────────────────────────────────────────────────────────

fn streamSend(s: *Socket, data: []const u8, nonblock: bool) Error!usize {
    return waitFor(s, nonblock, s.send_timeout_ms, data, struct {
        fn f(sock: *Socket, bytes: []const u8) ?Error!usize {
            if (sock.write_shut) return Error.BrokenPipe;
            const c = sock.tcb orelse return Error.NotConnected;
            if (c.failure) |why| return tcpError(why);
            switch (c.state) {
                .syn_sent => return null,
                .established, .close_wait => {},
                .closed => return Error.NotConnected,
                else => return Error.BrokenPipe,
            }
            if (bytes.len == 0) return 0;
            const n = tcp.writeLocked(c, bytes);
            return if (n == 0) null else n;
        }
    }.f);
}

const ReceiveRequest = struct { out: []u8, peek: bool };

fn streamReceive(s: *Socket, out: []u8, nonblock: bool, peek: bool) Error!usize {
    return waitFor(s, nonblock, s.receive_timeout_ms, ReceiveRequest{ .out = out, .peek = peek }, struct {
        fn f(sock: *Socket, request: ReceiveRequest) ?Error!usize {
            const c = sock.tcb orelse return Error.NotConnected;
            if (sock.read_shut) return 0;
            const n = tcp.readLocked(c, request.out, !request.peek);
            if (n > 0) return n;
            if (c.failure) |why| return tcpError(why);
            if (c.peer_fin) return 0;
            if (c.state == .syn_sent) return null;
            if (c.state == .closed) return 0;
            if (request.out.len == 0) return 0;
            return null;
        }
    }.f);
}

// ── Datagram I/O ────────────────────────────────────────────────────────────

/// A datagram for `port` arrived. Caller holds the network lock.
pub fn deliverUdpLocked(port: u16, from_ip: net.Ipv4Addr, from_port: u16, data: []const u8) void {
    var cursor = udp_sockets;
    while (cursor) |s| : (cursor = s.next_udp) {
        if (s.local.port != port) continue;
        // One bound to 127/8 hears only this machine.
        if (net.isLoopback(s.local.ip) and !net.isLoopback(from_ip)) return;
        // A connected socket takes datagrams from its peer only.
        if (s.connected and (s.remote.port != from_port or !std.mem.eql(u8, &s.remote.ip, &from_ip))) return;
        if (s.read_shut or data.len > MAX_UDP_PAYLOAD or s.queued + data.len > UDP_QUEUE_LIMIT) return;
        const d = heap.create(Datagram) catch return;
        d.* = .{ .from = .{ .ip = from_ip, .port = from_port }, .len = data.len };
        @memcpy(d.data[0..data.len], data);
        if (s.queue_tail) |tail| tail.next = d else s.queue_head = d;
        s.queue_tail = d;
        s.queued += data.len;
        changedLocked(s);
        return;
    }
}

/// Whether any datagram socket is open, so the network thread keeps
/// polling often enough for replies.
pub fn udpOpenLocked() bool {
    return udp_sockets != null;
}

fn datagramSend(s: *Socket, data: []const u8, to: ?Endpoint) Error!usize {
    if (data.len > MAX_UDP_PAYLOAD) return Error.MessageTooLong;
    const irq = net.acquire();
    defer net.release(irq);
    if (s.write_shut) return Error.BrokenPipe;
    const destination = if (to) |t| t else if (s.connected) s.remote else return Error.DestinationRequired;
    if (std.mem.eql(u8, &destination.ip, &net.BROADCAST_IP)) {
        if (!s.broadcast) return Error.NotPermitted;
    } else try checkDestination(destination, .datagram);
    if (!s.bound) try bindLocked(s, .{});
    if (net.isLoopback(s.local.ip) and !net.isLoopback(destination.ip)) return Error.Unreachable;
    if (net.isLoopback(destination.ip)) {
        deliverUdpLocked(destination.port, LOOPBACK_IP, s.local.port, data);
        return data.len;
    }
    net.sendUdpLocked(s.local.port, destination.ip, destination.port, data) catch |e| return switch (e) {
        error.TooLarge => Error.MessageTooLong,
        // The next hop is being resolved: the datagram is held and sent
        // when the answer comes (net.zig), which is what UDP promises.
        error.NoRoute => data.len,
        else => Error.Unreachable,
    };
    return data.len;
}

pub const Received = struct { bytes: usize, from: Endpoint, truncated: bool };

const DatagramRequest = struct { out: []u8, peek: bool, result: *Received };

fn datagramReceive(s: *Socket, out: []u8, nonblock: bool, peek: bool) Error!Received {
    var received: Received = .{ .bytes = 0, .from = .{}, .truncated = false };
    _ = try waitFor(s, nonblock, s.receive_timeout_ms, DatagramRequest{ .out = out, .peek = peek, .result = &received }, struct {
        fn f(sock: *Socket, request: DatagramRequest) ?Error!usize {
            const d = sock.queue_head orelse {
                if (sock.read_shut) return 0;
                return null;
            };
            const n = @min(request.out.len, d.len);
            @memcpy(request.out[0..n], d.data[0..n]);
            request.result.* = .{ .bytes = n, .from = d.from, .truncated = n < d.len };
            if (!request.peek) {
                sock.queue_head = d.next;
                if (sock.queue_head == null) sock.queue_tail = null;
                sock.queued -= d.len;
                heap.destroy(d);
            }
            return n;
        }
    }.f);
    return received;
}

// ── Common entry points ─────────────────────────────────────────────────────

/// send/sendto/write. `to` only for datagram sockets (a stream socket that
/// is connected ignores it, as Linux does when it matches).
pub fn send(s: *Socket, data: []const u8, to: ?Endpoint, nonblock: bool) Error!usize {
    return switch (s.kind) {
        .stream => streamSend(s, data, nonblock),
        .datagram => datagramSend(s, data, to),
    };
}

/// recv/recvfrom/read.
pub fn receive(s: *Socket, out: []u8, nonblock: bool, peek: bool) Error!Received {
    return switch (s.kind) {
        .stream => .{ .bytes = try streamReceive(s, out, nonblock, peek), .from = blk: {
            const irq = net.acquire();
            defer net.release(irq);
            break :blk if (s.tcb) |c| .{ .ip = c.remote_ip, .port = c.remote_port } else .{};
        }, .truncated = false },
        .datagram => datagramReceive(s, out, nonblock, peek),
    };
}

/// shutdown(): 0 stop receiving, 1 stop sending (a FIN), 2 both.
pub fn shutdown(s: *Socket, how: u2) Error!void {
    const irq = net.acquire();
    defer net.release(irq);
    if (s.kind == .stream) {
        const c = s.tcb orelse return Error.NotConnected;
        if (c.state == .syn_sent or c.state == .closed) return Error.NotConnected;
        if (how == 1 or how == 2) tcp.shutdownWriteLocked(c);
    } else if (!s.connected) return Error.NotConnected;
    if (how == 0 or how == 2) s.read_shut = true;
    if (how == 1 or how == 2) s.write_shut = true;
    changedLocked(s);
}

pub const Ready = struct { readable: bool, writable: bool, failed: bool, hangup: bool, read_hangup: bool };

pub fn poll(s: *Socket) Ready {
    const irq = net.acquire();
    defer net.release(irq);
    switch (s.kind) {
        .datagram => return .{
            .readable = s.queue_head != null or s.read_shut,
            .writable = !s.write_shut,
            .failed = false,
            .hangup = s.read_shut and s.write_shut,
            .read_hangup = s.read_shut,
        },
        .stream => {
            // An unconnected stream socket: writable is what POSIX says of
            // it for poll, and nothing will arrive.
            const c = s.tcb orelse return .{ .readable = false, .writable = true, .failed = false, .hangup = true, .read_hangup = false };
            const r = tcp.pollLocked(c);
            return .{
                .readable = r.readable or s.read_shut,
                .writable = r.writable and !s.write_shut,
                .failed = r.failed,
                .hangup = r.hangup,
                .read_hangup = r.read_hangup or s.read_shut,
            };
        },
    }
}

/// Bytes waiting to be read (FIONREAD, fstat's size).
pub fn pending(s: *Socket) usize {
    const irq = net.acquire();
    defer net.release(irq);
    return switch (s.kind) {
        .stream => if (s.tcb) |c| tcp.pendingLocked(c) else 0,
        .datagram => if (s.queue_head) |d| d.len else 0,
    };
}

/// The description closed: stream connections finish in the background
/// (or reset, with an abortive linger or unread data); datagrams queued are
/// discarded.
pub fn close(s: *Socket) void {
    readiness.detachAll(&s.source);
    const irq = net.acquire();
    if (s.tcb) |c| {
        if (s.abortive_close) tcp.abortLocked(c);
        tcp.detachLocked(c);
        s.tcb = null;
    }
    if (s.kind == .datagram and s.bound) {
        var link = &udp_sockets;
        while (link.*) |other| {
            if (other == s) {
                link.* = other.next_udp;
                break;
            }
            link = &other.next_udp;
        }
    }
    var queue = s.queue_head;
    s.queue_head = null;
    net.release(irq);
    while (queue) |d| {
        queue = d.next;
        heap.destroy(d);
    }
    heap.destroy(s);
}

// ── Options ─────────────────────────────────────────────────────────────────
//
// Levels and names are Linux's, which OrangeOS's socket calls use natively.

pub const SOL_SOCKET: u32 = 1;
pub const IPPROTO_IP: u32 = 0;
pub const IPPROTO_TCP: u32 = 6;

const SO_REUSEADDR: u32 = 2;
const SO_TYPE: u32 = 3;
const SO_ERROR: u32 = 4;
const SO_BROADCAST: u32 = 6;
const SO_SNDBUF: u32 = 7;
const SO_RCVBUF: u32 = 8;
const SO_KEEPALIVE: u32 = 9;
const SO_LINGER: u32 = 13;
const SO_RCVTIMEO: u32 = 20;
const SO_SNDTIMEO: u32 = 21;
const SO_ACCEPTCONN: u32 = 30;
const SO_PROTOCOL: u32 = 38;
const SO_DOMAIN: u32 = 39;
const TCP_NODELAY: u32 = 1;

/// SO_ERROR's value: the errno of a pending failure, cleared by reading.
pub fn takeError(s: *Socket) ?Error {
    const irq = net.acquire();
    defer net.release(irq);
    if (s.pending_error) |e| {
        s.pending_error = null;
        return e;
    }
    if (s.tcb) |c| if (c.failure) |why| {
        return tcpError(why);
    };
    return null;
}

/// Integer-valued options, plus SO_LINGER and the timeouts, which the
/// syscall layer converts. `value` is what getsockopt returns.
pub const OptionValue = union(enum) {
    int: i32,
    linger: struct { on: bool, seconds: i32 },
    timeout_ms: u64,
};

pub fn getOption(s: *Socket, level: u32, name: u32) Error!OptionValue {
    const irq = net.acquire();
    defer net.release(irq);
    if (level == SOL_SOCKET) return switch (name) {
        SO_TYPE => .{ .int = if (s.kind == .stream) 1 else 2 },
        SO_DOMAIN => .{ .int = 2 },
        SO_PROTOCOL => .{ .int = if (s.kind == .stream) 6 else 17 },
        SO_ACCEPTCONN => .{ .int = 0 },
        SO_REUSEADDR => .{ .int = @intFromBool(s.reuse_address) },
        SO_BROADCAST => .{ .int = @intFromBool(s.broadcast) },
        SO_KEEPALIVE => .{ .int = @intFromBool(s.keepalive) },
        // The fixed capacities; setting them is a hint, as on Linux.
        SO_SNDBUF => .{ .int = @intCast(if (s.kind == .stream) tcp.TX_CAPACITY else MAX_UDP_PAYLOAD) },
        SO_RCVBUF => .{ .int = @intCast(if (s.kind == .stream) tcp.RX_CAPACITY else UDP_QUEUE_LIMIT) },
        SO_LINGER => .{ .linger = .{ .on = s.abortive_close, .seconds = 0 } },
        SO_RCVTIMEO => .{ .timeout_ms = s.receive_timeout_ms },
        SO_SNDTIMEO => .{ .timeout_ms = s.send_timeout_ms },
        else => Error.NoProtocolOption,
    };
    if (level == IPPROTO_TCP and s.kind == .stream) return switch (name) {
        TCP_NODELAY => .{ .int = @intFromBool(s.no_delay) },
        else => Error.NoProtocolOption,
    };
    return Error.NoProtocolOption;
}

pub fn setOption(s: *Socket, level: u32, name: u32, value: OptionValue) Error!void {
    const irq = net.acquire();
    defer net.release(irq);
    const flag = switch (value) {
        .int => |v| v != 0,
        else => false,
    };
    if (level == SOL_SOCKET) switch (name) {
        SO_REUSEADDR => s.reuse_address = flag,
        SO_BROADCAST => s.broadcast = flag,
        SO_KEEPALIVE => {
            s.keepalive = flag;
            if (s.tcb) |c| tcp.keepaliveLocked(c, flag);
        },
        SO_SNDBUF, SO_RCVBUF => {},
        SO_LINGER => switch (value) {
            // Only the abortive form: a close that blocks until data drains
            // is not implemented, and saying yes to it would be untrue.
            .linger => |l| {
                if (l.on and l.seconds != 0) return Error.NotSupported;
                s.abortive_close = l.on;
            },
            else => return Error.InvalidArgument,
        },
        SO_RCVTIMEO => s.receive_timeout_ms = switch (value) {
            .timeout_ms => |ms| ms,
            else => return Error.InvalidArgument,
        },
        SO_SNDTIMEO => s.send_timeout_ms = switch (value) {
            .timeout_ms => |ms| ms,
            else => return Error.InvalidArgument,
        },
        else => return Error.NoProtocolOption,
    } else if (level == IPPROTO_TCP and s.kind == .stream) switch (name) {
        // Segments are always sent at once (there is no Nagle delay), so
        // NODELAY is how this stack behaves either way.
        TCP_NODELAY => s.no_delay = flag,
        else => return Error.NoProtocolOption,
    } else return Error.NoProtocolOption;
}
