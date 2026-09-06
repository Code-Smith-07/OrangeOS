//! Read the PC RTC once on the boot CPU, before SMP starts. Hardware stays
//! in UTC; civil timezone conversion belongs to userland. No CMOS writes.
const io = @import("../arch/x86_64/io.zig");
const calendar = @import("calendar");
fn read(reg: u8) u8 {
    io.outb(0x70, reg);
    return io.inb(0x71);
}
fn snapshot() [8]u8 {
    return .{ read(0), read(2), read(4), read(7), read(8), read(9), read(0x32), read(0x0B) };
}
fn decode(value: u8, binary: bool) ?u8 {
    if (binary) return value;
    if (value & 15 > 9 or value >> 4 > 9) return null;
    return (value >> 4) * 10 + (value & 15);
}
pub fn epoch() ?u64 {
    // Bounded retries: absent/broken RTC must never hang boot. Two matching
    // snapshots and UIP checks reject a read spanning the one-second update.
    for (0..10000) |_| {
        if (read(0x0A) & 0x80 != 0) continue;
        const a = snapshot();
        if (read(0x0A) & 0x80 != 0) continue;
        const b = snapshot();
        if (read(0x0A) & 0x80 != 0 or !@import("std").mem.eql(u8, &a, &b)) continue;
        if (read(0x0D) & 0x80 == 0) return null;
        const binary = a[7] & 4 != 0;
        var hour = decode(a[2] & 0x7F, binary) orelse return null;
        if (a[7] & 2 == 0) {
            if (hour < 1 or hour > 12) return null;
            hour = hour % 12 + (if (a[2] & 0x80 != 0) @as(u8, 12) else 0);
        }
        const year = decode(a[5], binary) orelse return null;
        // Conventional PC century register; old firmware falls back to the
        // 1970..2069 pivot when it leaves the century unset.
        const century = decode(a[6], binary) orelse 0;
        const full_year: u16 = if (century >= 19 and century <= 23) @as(u16, century) * 100 + year else (if (year >= 70) @as(u16, 1900) else 2000) + year;
        return calendar.toEpoch(full_year, decode(a[4], binary) orelse return null, decode(a[3], binary) orelse return null, hour, decode(a[1], binary) orelse return null, decode(a[0], binary) orelse return null);
    }
    return null;
}
