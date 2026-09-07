//! Gregorian civil time, independent of the monotonic scheduling clock.
const std = @import("std");
pub const Date = struct { year: u16, month: u8, day: u8, hour: u8, minute: u8, second: u8, weekday: u8 };
pub fn leap(year: u16) bool {
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
}
pub fn daysInMonth(year: u16, month: u8) u8 {
    if (month < 1 or month > 12) return 0;
    return if (month == 2 and leap(year)) 29 else ([_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 })[month - 1];
}
pub fn toEpoch(year: u16, month: u8, day: u8, hour: u8, minute: u8, second: u8) ?u64 {
    if (year < 1970 or year > 2399 or day == 0 or day > daysInMonth(year, month) or hour > 23 or minute > 59 or second > 59) return null;
    var days: u64 = 0;
    var y: u16 = 1970;
    while (y < year) : (y += 1) days += if (leap(y)) @as(u64, 366) else 365;
    var m: u8 = 1;
    while (m < month) : (m += 1) days += daysInMonth(year, m);
    return (days + day - 1) * 86400 + @as(u64, hour) * 3600 + @as(u64, minute) * 60 + second;
}
pub fn fromEpoch(seconds: u64, offset_minutes: i32) Date {
    const local: u64 = @intCast(@max(0, @as(i64, @intCast(@min(seconds, 13_569_465_599))) + @as(i64, offset_minutes) * 60));
    var days = local / 86400;
    const weekday: u8 = @intCast((days + 4) % 7);
    var year: u16 = 1970;
    while (true) {
        const count: u64 = if (leap(year)) 366 else 365;
        if (days < count) break;
        days -= count;
        year += 1;
    }
    var month: u8 = 1;
    while (days >= daysInMonth(year, month)) : (month += 1) days -= daysInMonth(year, month);
    return .{ .year = year, .month = month, .day = @intCast(days + 1), .hour = @intCast(local / 3600 % 24), .minute = @intCast(local / 60 % 60), .second = @intCast(local % 60), .weekday = weekday };
}
pub fn clockText(buf: []u8, d: Date) []const u8 {
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2} {s}", .{ if (d.hour % 12 == 0) @as(u8, 12) else d.hour % 12, d.minute, d.second, if (d.hour < 12) "AM" else "PM" }) catch "";
}
pub fn dateText(buf: []u8, d: Date) []const u8 {
    const days = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    return std.fmt.bufPrint(buf, "{s} {d} {s}", .{ days[d.weekday], d.day, months[d.month - 1] }) catch "";
}

/// First day of the browsed month; saturate at the civil conversion bounds.
pub fn monthAt(date: Date, offset: i32) Date {
    const month = std.math.clamp(@as(i64, date.year) * 12 + date.month - 1 + offset, 1970 * 12, 2399 * 12 + 11);
    return fromEpoch(toEpoch(@intCast(@divTrunc(month, 12)), @intCast(@mod(month, 12) + 1), 1, 0, 0, 0).?, 0);
}

test "calendar month browsing crosses years and clamps boundaries" {
    const january = fromEpoch(toEpoch(2026, 1, 20, 0, 0, 0).?, 0);
    const previous = monthAt(january, -1);
    try std.testing.expectEqual(@as(u16, 2025), previous.year);
    try std.testing.expectEqual(@as(u8, 12), previous.month);
    try std.testing.expectEqual(@as(u8, 1), previous.day);
    try std.testing.expectEqual(@as(u8, 1), previous.weekday);
    const february = monthAt(january, -23);
    try std.testing.expectEqual(@as(u8, 29), daysInMonth(february.year, february.month));
    try std.testing.expectEqual(@as(u16, 1970), monthAt(january, -2147483648).year);
    try std.testing.expectEqual(@as(u16, 2399), monthAt(january, 2147483647).year);
}
test "Gregorian validation, leap years and local midnight" {
    try std.testing.expect(toEpoch(2025, 2, 29, 0, 0, 0) == null);
    try std.testing.expect(toEpoch(2026, 0, 1, 0, 0, 0) == null);
    try std.testing.expect(toEpoch(2100, 2, 29, 0, 0, 0) == null);
    const leap_day = fromEpoch(toEpoch(2024, 2, 29, 23, 59, 59).? + 1, 0);
    try std.testing.expectEqual(@as(u8, 3), leap_day.month);
    try std.testing.expectEqual(@as(u8, 1), leap_day.day);
    const india = fromEpoch(toEpoch(2026, 9, 6, 18, 30, 0).?, 330);
    try std.testing.expectEqual(@as(u8, 7), india.day);
    try std.testing.expectEqual(@as(u8, 0), india.hour);
    try std.testing.expectEqual(@as(u8, 1), india.weekday);
    const west = fromEpoch(toEpoch(2026, 1, 1, 0, 0, 0).?, -60);
    try std.testing.expectEqual(@as(u16, 2025), west.year);
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("12:00:00 AM", clockText(&buf, india));
}

test "civil conversion round-trips every supported day" {
    var year: u16 = 1970;
    while (year <= 2399) : (year += 1) {
        var month: u8 = 1;
        while (month <= 12) : (month += 1) {
            var day: u8 = 1;
            while (day <= daysInMonth(year, month)) : (day += 1) {
                const d = fromEpoch(toEpoch(year, month, day, 23, 59, 59).?, 0);
                try std.testing.expectEqual(year, d.year);
                try std.testing.expectEqual(month, d.month);
                try std.testing.expectEqual(day, d.day);
                try std.testing.expectEqual(@as(u8, 23), d.hour);
            }
        }
    }
}
