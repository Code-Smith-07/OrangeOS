//! ping — send ICMP echo requests to the gateway.
//!
//! Argument passing to spawned programs does not exist yet, so the target is
//! the configured gateway rather than something typed on the command line.

const pulp = @import("pulp");

export fn _start() callconv(.c) noreturn {
    const info = pulp.netInfo() catch {
        pulp.puts("ping: no network\n");
        pulp.exit(1);
    };

    if (info.up == 0) {
        pulp.puts("ping: link is down\n");
        pulp.exit(1);
    }

    const ip = pulp.unpackIp(info.ip);
    const gw = pulp.unpackIp(info.gateway);

    pulp.print("  address {d}.{d}.{d}.{d}  mac {x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}\n", .{
        ip[0],       ip[1],       ip[2],       ip[3],
        info.mac[0], info.mac[1], info.mac[2], info.mac[3], info.mac[4], info.mac[5],
    });
    pulp.print("  PING {d}.{d}.{d}.{d}\n", .{ gw[0], gw[1], gw[2], gw[3] });

    var seq: u16 = 1;
    var received: u32 = 0;
    while (seq <= 4) : (seq += 1) {
        if (pulp.ping(gw, seq, 1000)) |us| {
            received += 1;
            pulp.print("  reply seq={d} time={d}.{d} ms\n", .{ seq, us / 1000, (us % 1000) / 100 });
        } else {
            pulp.print("  seq={d} timed out\n", .{seq});
        }
        pulp.sleepMs(300);
    }

    pulp.print("  4 sent, {d} received\n", .{received});
    pulp.exit(0);
}
