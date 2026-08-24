//! fetch — retrieve a page over HTTP.
//!
//! Resolves a hostname, opens a TCP connection, sends a request, and prints
//! the response. The whole path — DNS over UDP, ARP, IPv4, and TCP's
//! handshake, acknowledgement and teardown — is Orange OS code.

const pulp = @import("pulp");

const HOST = "example.com";
const PORT: u16 = 80;

const REQUEST =
    "GET / HTTP/1.0\r\n" ++
    "Host: " ++ HOST ++ "\r\n" ++
    "User-Agent: OrangeOS/0.1\r\n" ++
    "Connection: close\r\n" ++
    "\r\n";

export fn _start() callconv(.c) noreturn {
    pulp.print("  resolving {s}...\n", .{HOST});

    const ip = pulp.resolve(HOST) orelse {
        pulp.puts("  fetch: cannot resolve\n");
        pulp.exit(1);
    };
    pulp.print("  {s} is {d}.{d}.{d}.{d}\n", .{ HOST, ip[0], ip[1], ip[2], ip[3] });

    pulp.print("  connecting to port {d}...\n", .{PORT});
    const sock = pulp.tcpConnect(ip, PORT, 5000) catch {
        pulp.puts("  fetch: connect failed\n");
        pulp.exit(1);
    };
    pulp.puts("  connected\n");

    _ = pulp.tcpSend(sock, REQUEST) catch {
        pulp.puts("  fetch: send failed\n");
        pulp.tcpClose(sock);
        pulp.exit(1);
    };

    var buf: [1024]u8 = undefined;
    var total: usize = 0;
    var shown: usize = 0;

    pulp.puts("\n");
    while (true) {
        const n = pulp.tcpRecv(sock, &buf, 3000) catch break;
        if (n == 0) break;
        total += n;

        // Print the first few hundred bytes; the rest is counted, not shown.
        if (shown < 320) {
            const take = @min(n, 320 - shown);
            pulp.puts(buf[0..take]);
            shown += take;
        }
    }

    pulp.print("\n  --- {d} bytes received ---\n", .{total});
    pulp.tcpClose(sock);
    pulp.exit(0);
}
