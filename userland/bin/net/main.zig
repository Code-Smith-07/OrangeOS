//! net — show the network configuration and resolve a few names.

const pulp = @import("pulp");

fn showIp(label: []const u8, v: u32) void {
    const a = pulp.unpackIp(v);
    pulp.print("  {s}{d}.{d}.{d}.{d}\n", .{ label, a[0], a[1], a[2], a[3] });
}

export fn _start() callconv(.c) noreturn {
    const info = pulp.netInfo() catch {
        pulp.puts("net: no network\n");
        pulp.exit(1);
    };

    pulp.print("  link      {s}\n", .{if (info.up != 0) "up" else "down"});
    pulp.print("  mac       {x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}\n", .{
        info.mac[0], info.mac[1], info.mac[2], info.mac[3], info.mac[4], info.mac[5],
    });
    showIp("address   ", info.ip);
    showIp("netmask   ", info.netmask);
    showIp("gateway   ", info.gateway);

    if (info.up == 0) pulp.exit(0);

    pulp.puts("\n  resolving:\n");
    const names = [_][]const u8{ "example.com", "one.one.one.one" };
    for (names) |name| {
        if (pulp.resolve(name)) |ip| {
            pulp.print("    {s} -> {d}.{d}.{d}.{d}\n", .{ name, ip[0], ip[1], ip[2], ip[3] });
        } else {
            pulp.print("    {s} -> no answer\n", .{name});
        }
    }

    pulp.exit(0);
}
