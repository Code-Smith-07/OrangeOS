//! Settings (docs/design/014, M5): one window, a sidebar of panes, and in
//! each pane only things that are real.
//!
//! Wi-Fi, Bluetooth, Sound, Display and Battery show the Mac's own hardware
//! through the companion, and their switches and sliders change it (each
//! needs its grant in the companion's menu; without one the control is
//! shown disabled, with the reason). Appearance and Lock Screen change
//! OrangeOS itself and are saved on the data disk. The rest report what the
//! system knows: network addresses, date and time, shortcuts, disk space.
const std = @import("std");
const pulp = @import("pulp");
const appkit = @import("appkit");
const ui = appkit.ui;
const K = appkit.K;
const proto = appkit.proto;
const model = @import("host_model");
const account = @import("account");

const BAR: i32 = ui.Metrics.toolbar_h;
const SIDEBAR_W: i32 = 214;
const CANVAS: u32 = 0xF0F1F4;
const ROW_H: i32 = 44;
const NOTE_H: i32 = 22;

const Pane = enum { wifi, bluetooth, network, sound, display, battery, appearance, lock, datetime, keyboard, storage, about };
const PaneInfo = struct { name: []const u8, icon: ui.Icon, tint: u32 };
const PANES = [_]PaneInfo{
    .{ .name = "Wi-Fi", .icon = .wifi, .tint = 0x2F8CF0 },
    .{ .name = "Bluetooth", .icon = .bluetooth, .tint = 0x3478F6 },
    .{ .name = "Network", .icon = .controls, .tint = 0x34A853 },
    .{ .name = "Sound", .icon = .speaker, .tint = 0xF0506E },
    .{ .name = "Display", .icon = .sym_display, .tint = 0x5B8DEF },
    .{ .name = "Battery", .icon = .battery_plain, .tint = 0x3CB371 },
    .{ .name = "Appearance", .icon = .sun, .tint = 0x4B4F58 },
    .{ .name = "Lock Screen", .icon = .sym_lock, .tint = 0x8A8F98 },
    .{ .name = "Date & Time", .icon = .sym_clock, .tint = 0xF28A1E },
    .{ .name = "Keyboard", .icon = .sym_keyboard, .tint = 0x8A8F98 },
    .{ .name = "Storage", .icon = .sym_image, .tint = 0x6C7A91 },
    .{ .name = "About", .icon = .sym_info, .tint = 0x8A8F98 },
};

// What a row does when used.
const Act = struct {
    const wifi: u32 = 1;
    const bluetooth: u32 = 2;
    const volume: u32 = 3;
    const brightness: u32 = 4;
    const theme: u32 = 5;
    const reduce_motion: u32 = 6;
    const lock_after: u32 = 7;
    const lock_now: u32 = 8;
    const set_password: u32 = 9;
    const remove_password: u32 = 10;
};

const Kind = enum { info, toggle, slider, meter, button, choice, field, note };
const Field = ui.TextInput(account.MAX_PASSWORD);
const Row = struct {
    kind: Kind = .info,
    label: []const u8 = "",
    value: []const u8 = "",
    act: u32 = 0,
    on: bool = false,
    /// Slider and meter: 0 to 100.
    level: i32 = 0,
    enabled: bool = true,
    choices: []const []const u8 = &.{},
    selected: usize = 0,
    field: ?*Field = null,
    secure: bool = false,
    /// The last row of its card.
    last: bool = false,
    bad: bool = false,
    /// A meter that is good when full (a battery), drawn green.
    good: bool = false,
};

var app: appkit.App = undefined;
var pane: Pane = .wifi;
var rows: [20]Row = undefined;
var row_count: usize = 0;
var arena: [1536]u8 = undefined;
var arena_len: usize = 0;

var host: model.Model = .{};
var host_json: [4096]u8 = undefined;
var host_scratch: [32768]u8 = undefined;
var prefs: proto.Preferences = std.mem.zeroes(proto.Preferences);
var have_prefs = false;

/// A command sent to the Mac that has not answered yet.
var pending: i64 = 0;
var pending_act: u32 = 0;
var note_text: []const u8 = "";
var note_bad = false;
/// A slider being dragged: its row and the level under the pointer.
var drag_row: ?usize = null;
var drag_level: i32 = 0;

var has_data = false;
var user: ?account.Account = null;
var name_field: Field = .{};
var current_field: Field = .{};
var new_field: Field = .{};
var confirm_field: Field = .{};
var focus: ?*Field = null;
var last_second: u64 = 0;

fn text(comptime fmt: []const u8, args: anytype) []const u8 {
    const out = std.fmt.bufPrint(arena[arena_len..], fmt, args) catch return "";
    arena_len += out.len;
    return out;
}
fn add(row: Row) void {
    if (row_count == rows.len) return;
    rows[row_count] = row;
    row_count += 1;
}
fn endCard() void {
    if (row_count > 0) rows[row_count - 1].last = true;
}
fn note(str: []const u8) void {
    add(.{ .kind = .note, .label = str, .last = true });
}

fn loadAccount() void {
    pulp.mkdir(account.DIR) catch {};
    has_data = pulp.exists(account.DIR);
    var buf: [512]u8 = undefined;
    user = if (appkit.readFile(account.PATH, &buf, null)) |bytes| account.Account.parse(bytes) else null;
    if (user) |*u| name_field.set(u.name());
}

fn connected() bool {
    return host.connection == .fresh;
}
const NOT_CONNECTED = "Not connected to your Mac. Start OrangeOS with scripts/run-desktop.sh.";
const NEEDS_GRANT = "Allow this in the OrangeOS Companion menu on your Mac's menu bar.";

fn radioText(row: model.Row) []const u8 {
    return switch (row.reading) {
        .on => "On",
        .off => "Off",
        .status => |s| switch (s) {
            .permission_required => "macOS permission needed",
            .denied => "Permission denied on the Mac",
            .unsupported => "Not supported on this Mac",
            else => "Unknown",
        },
        .percent => "Unknown",
    };
}

fn ip(buf: []u8, value: u32) []const u8 {
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ value & 255, (value >> 8) & 255, (value >> 16) & 255, value >> 24 }) catch "";
}

fn megabytes(bytes: u64) u64 {
    return (bytes + 500_000) / 1_000_000;
}

/// Build the rows of the current pane from what is true right now.
fn build() void {
    row_count = 0;
    arena_len = 0;
    const wifi = host.rows[0];
    const bluetooth = host.rows[1];
    const brightness = host.rows[2];
    const audio = host.rows[3];
    const battery = host.rows[4];
    switch (pane) {
        .wifi => {
            add(.{ .kind = .toggle, .label = "Wi-Fi", .act = Act.wifi, .on = wifi.reading == .on, .enabled = connected() and wifi.control and pending == 0 });
            add(.{ .label = "Status", .value = if (connected()) radioText(wifi) else "Not connected" });
            add(.{ .label = "Radio", .value = "Your Mac's Wi-Fi (CoreWLAN)" });
            endCard();
            if (!connected()) note(NOT_CONNECTED) else if (!wifi.control) note(NEEDS_GRANT);
            note("This switch turns your Mac's Wi-Fi radio on and off.");
            note("OrangeOS itself reaches the internet through QEMU's network.");
        },
        .bluetooth => {
            add(.{ .kind = .toggle, .label = "Bluetooth", .act = Act.bluetooth, .on = bluetooth.reading == .on, .enabled = connected() and bluetooth.control and pending == 0 });
            add(.{ .label = "Status", .value = if (connected()) radioText(bluetooth) else "Not connected" });
            add(.{ .label = "Connected devices", .value = if (bluetooth.connected) |n| text("{d}", .{n}) else "--" });
            endCard();
            if (!connected()) note(NOT_CONNECTED) else if (bluetooth.reading == .status) note("Choose \"Show Mac Bluetooth status in OrangeOS\" in the Companion menu.") else if (!bluetooth.control) note(NEEDS_GRANT);
            note("Only the on/off state and a count leave your Mac: no device names.");
        },
        .network => {
            if (pulp.netInfo()) |info| {
                var a: [16]u8 = undefined;
                var b: [16]u8 = undefined;
                var c: [16]u8 = undefined;
                add(.{ .label = "Connection", .value = if (info.up != 0) "Connected" else "Not connected" });
                add(.{ .label = "IP address", .value = text("{s}", .{ip(&a, info.ip)}) });
                add(.{ .label = "Router", .value = text("{s}", .{ip(&b, info.gateway)}) });
                add(.{ .label = "Subnet mask", .value = text("{s}", .{ip(&c, info.netmask)}) });
                add(.{ .label = "Hardware address", .value = text("{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{ info.mac[0], info.mac[1], info.mac[2], info.mac[3], info.mac[4], info.mac[5] }) });
            } else |_| add(.{ .label = "Connection", .value = "No network adapter" });
            add(.{ .label = "Adapter", .value = "Intel PRO/1000 (e1000)" });
            endCard();
            note("The wired adapter the virtual machine gives OrangeOS.");
        },
        .sound => {
            const level: i32 = if (audio.reading == .percent) audio.reading.percent else 0;
            add(.{ .kind = .slider, .label = "Output volume", .act = Act.volume, .level = level, .value = if (audio.reading == .percent) text("{d}%", .{level}) else "--", .enabled = connected() and audio.control and audio.reading == .percent and pending == 0 });
            add(.{ .label = "Muted", .value = if (audio.muted) |m| (if (m) "Yes" else "No") else "--" });
            add(.{ .label = "Output", .value = "Your Mac's sound output (CoreAudio)" });
            endCard();
            if (!connected()) note(NOT_CONNECTED) else if (!audio.control) note(NEEDS_GRANT);
            note("OrangeOS plays its own sound through this output.");
        },
        .display => {
            const level: i32 = if (brightness.reading == .percent) brightness.reading.percent else 0;
            add(.{ .kind = .slider, .label = "Brightness", .act = Act.brightness, .level = level, .value = if (brightness.reading == .percent) text("{d}%", .{level}) else "--", .enabled = connected() and brightness.control and brightness.reading == .percent and pending == 0 });
            endCard();
            if (!connected()) note(NOT_CONNECTED) else if (!brightness.control) note(NEEDS_GRANT);
            if (have_prefs) {
                add(.{ .label = "Resolution", .value = text("{d} x {d}", .{ prefs.screen_width * prefs.scale, prefs.screen_height * prefs.scale }) });
                add(.{ .label = "Looks like", .value = text("{d} x {d}", .{ prefs.screen_width, prefs.screen_height }) });
                add(.{ .label = "Sharpness", .value = if (prefs.scale == 2) "Retina (2 pixels per point)" else "Standard" });
                endCard();
            }
            note("Brightness is your Mac's built-in display (5% at the least).");
        },
        .battery => {
            const level: i32 = if (battery.reading == .percent) battery.reading.percent else 0;
            add(.{ .kind = .meter, .label = "Charge", .level = level, .value = if (battery.reading == .percent) text("{d}%", .{level}) else "--", .bad = level <= 20 and battery.power != true, .good = true });
            add(.{ .label = "Power source", .value = if (!connected()) "--" else if (battery.power == true) "Power adapter" else "Battery" });
            endCard();
            if (!connected()) note(NOT_CONNECTED);
            note("Your Mac's battery. OrangeOS warns you when it runs low.");
        },
        .appearance => {
            add(.{ .kind = .choice, .label = "Theme", .act = Act.theme, .choices = &.{ "Coastal", "Citrus", "Aurora" }, .selected = @min(prefs.theme, 2), .enabled = have_prefs });
            add(.{ .kind = .toggle, .label = "Reduce motion", .act = Act.reduce_motion, .on = prefs.reduce_motion != 0, .enabled = have_prefs });
            endCard();
            note("Each theme has its own wallpaper, colours and window style.");
            note(if (prefs.kept != 0) "Your choices are kept after a restart." else "No data disk: choices reset on restart.");
        },
        .lock => {
            if (!has_data) {
                note("No data disk is attached, so a password cannot be kept.");
            } else {
                add(.{ .kind = .field, .label = "Your name", .field = &name_field });
                if (user != null) add(.{ .kind = .field, .label = "Current password", .field = &current_field, .secure = true });
                add(.{ .kind = .field, .label = if (user != null) "New password" else "Password", .field = &new_field, .secure = true });
                add(.{ .kind = .field, .label = "Type it again", .field = &confirm_field, .secure = true });
                add(.{ .kind = .button, .label = "", .value = if (user != null) "Change Password" else "Set Password", .act = Act.set_password });
                endCard();
                add(.{ .kind = .choice, .label = "Lock after", .act = Act.lock_after, .choices = &.{ "Never", "1 min", "5 min", "15 min" }, .selected = lockChoice(prefs.lock_minutes), .enabled = have_prefs and user != null });
                add(.{ .kind = .button, .label = "Lock the screen now", .value = "Lock Now", .act = Act.lock_now, .enabled = user != null });
                if (user != null) add(.{ .kind = .button, .label = "Stop asking for a password", .value = "Remove Password", .act = Act.remove_password });
                endCard();
                note(if (user != null) "The screen asks for the password at start-up and when locked." else "With a password, OrangeOS asks for it at start-up and when locked.");
            }
        },
        .datetime => {
            if (pulp.wallTime()) |seconds| {
                const date = pulp.calendar.fromEpoch(seconds, pulp.timezone_minutes);
                var a: [32]u8 = undefined;
                var b: [32]u8 = undefined;
                add(.{ .label = "Date", .value = text("{s} {d}", .{ pulp.calendar.dateText(&a, date), date.year }) });
                add(.{ .label = "Time", .value = text("{s}", .{pulp.calendar.clockText(&b, date)}) });
            } else add(.{ .label = "Clock", .value = "Unavailable" });
            const tz = pulp.timezone_minutes;
            add(.{ .label = "Time zone", .value = text("UTC{c}{d:0>2}:{d:0>2}", .{ @as(u8, if (tz < 0) '-' else '+'), @abs(tz) / 60, @abs(tz) % 60 }) });
            endCard();
            note("The time comes from your computer's clock.");
        },
        .keyboard => {
            add(.{ .label = "Layout", .value = "US English" });
            endCard();
            add(.{ .label = "Spotlight", .value = "Option + Space" });
            add(.{ .label = "Switch windows", .value = "Option + Tab" });
            add(.{ .label = "Mission Control", .value = "F3" });
            add(.{ .label = "Appearance panel", .value = "F4" });
            add(.{ .label = "Show the desktop", .value = "F11" });
            add(.{ .label = "Close a panel", .value = "Escape" });
            endCard();
            note("OrangeOS uses Option where a Mac uses Command.");
        },
        .storage => {
            for ([_][2][]const u8{ .{ "System disk", "/" }, .{ "Data disk", "/data/Documents" } }) |disk| {
                if (pulp.statfs(disk[1])) |fs| {
                    const used = fs.total_bytes -| fs.free_bytes;
                    add(.{ .kind = .meter, .label = disk[0], .level = @intCast(if (fs.total_bytes == 0) 0 else used * 100 / fs.total_bytes), .value = text("{d} MB of {d} MB used", .{ megabytes(used), megabytes(fs.total_bytes) }) });
                } else |_| add(.{ .label = disk[0], .value = "Not attached" });
            }
            endCard();
            note("The system disk holds OrangeOS and cannot be changed.");
            note("The data disk holds your documents and settings.");
        },
        .about => {
            add(.{ .label = "Orange OS", .value = "Version 0.1.0 (Daybreak)" });
            add(.{ .label = "Kernel", .value = "Zest, with CitrusFS" });
            add(.{ .label = "Processor type", .value = "Intel 64-bit (x86-64)" });
            if (have_prefs) add(.{ .label = "Display", .value = text("{d} x {d}", .{ prefs.screen_width * prefs.scale, prefs.screen_height * prefs.scale }) });
            endCard();
            add(.{ .label = "Official Vishwateja", .value = "" });
            add(.{ .label = "Developed by Vishwateja S B", .value = "" });
            add(.{ .label = "Software Developer and AI Data Analyst", .value = "" });
            endCard();
            note("(c) 2026 Official Vishwateja. All Rights Reserved.");
        },
    }
    if (note_text.len > 0) add(.{ .kind = .note, .label = note_text, .bad = note_bad, .last = true });
}

fn lockChoice(minutes: u32) usize {
    return switch (minutes) {
        0 => 0,
        1 => 1,
        2...5 => 2,
        else => 3,
    };
}

// ── Layout ────────────────────────────────────────────────────────────────

fn sidebarRow(i: usize) ui.Rect {
    return .{ .x = 10, .y = BAR + 4 + @as(i32, @intCast(i)) * 32, .w = SIDEBAR_W - 20, .h = 30 };
}
fn contentX() i32 {
    return SIDEBAR_W + 24;
}
fn contentW() i32 {
    return @min(app.width() - SIDEBAR_W - 48, 620);
}
/// Row `i`'s rectangle: cards stack with a gap after each one.
fn rowRect(i: usize) ui.Rect {
    var y: i32 = BAR + 16;
    for (rows[0..row_count], 0..) |row, k| {
        const h: i32 = if (row.kind == .note) NOTE_H else ROW_H;
        if (k == i) return .{ .x = contentX(), .y = y, .w = contentW(), .h = h };
        y += h;
        if (row.last and row.kind != .note) y += 12;
        if (row.kind == .note and k + 1 < row_count and rows[k + 1].kind != .note) y += 10;
    }
    return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
}
/// The control at the right of a row.
fn controlRect(i: usize) ui.Rect {
    const r = rowRect(i);
    const row = rows[i];
    return switch (row.kind) {
        .toggle => .{ .x = r.right() - 16 - ui.Metrics.switch_w, .y = r.y + @divTrunc(r.h - ui.Metrics.switch_h, 2), .w = ui.Metrics.switch_w, .h = ui.Metrics.switch_h },
        .slider, .meter => .{ .x = r.right() - 16 - 48 - 200, .y = r.y + 8, .w = 200, .h = r.h - 16 },
        .button => blk: {
            const w = ui.textWidth(row.value, 1) + 32;
            break :blk .{ .x = r.right() - 16 - w, .y = r.y + @divTrunc(r.h - 27, 2), .w = w, .h = 27 };
        },
        .choice => blk: {
            const w: i32 = @intCast(row.choices.len * 72);
            break :blk .{ .x = r.right() - 16 - w, .y = r.y + 8, .w = w, .h = 28 };
        },
        .field => .{ .x = r.right() - 16 - 230, .y = r.y + 10, .w = 230, .h = 24 },
        else => .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    };
}
fn sliderLevel(i: usize, x: i32) i32 {
    const c = controlRect(i);
    return std.math.clamp(@divTrunc((x - c.x - 8) * 100, @max(1, c.w - 16)), 0, 100);
}

// Target ids: 1.. panes, 100+ rows, 200 + row*8 + segment for choices.
const MAX_TARGETS = PANES.len + 20 + 20 * 4;
fn targets(out: *[MAX_TARGETS]ui.Button) []const ui.Button {
    var n: usize = 0;
    for (0..PANES.len) |i| {
        out[n] = .{ .id = @intCast(1 + i), .rect = sidebarRow(i) };
        n += 1;
    }
    for (rows[0..row_count], 0..) |row, i| {
        if (!row.enabled) continue;
        switch (row.kind) {
            .toggle, .button, .field, .slider => {
                out[n] = .{ .id = @intCast(100 + i), .rect = controlRect(i) };
                n += 1;
            },
            .choice => for (0..row.choices.len) |seg| {
                out[n] = .{ .id = @intCast(200 + i * 8 + seg), .rect = ui.segment(controlRect(i), row.choices.len, seg) };
                n += 1;
            },
            else => {},
        }
    }
    return out[0..n];
}

// ── Doing things ──────────────────────────────────────────────────────────

fn say(str: []const u8, bad: bool) void {
    note_text = str;
    note_bad = bad;
}

/// Ask the Mac (through the kernel's mailbox and the guest agent) to change
/// a device. The answer arrives later; `poll` reports it.
fn sendToMac(op: u64, value: u64, device: u64, what: u32) void {
    const id = pulp.syscall3(112, op, value, device);
    if (id > 0) {
        pending = id;
        pending_act = what;
        say("Asking your Mac...", false);
        pulp.print("settings: sent device command {d} value {d}\n", .{ what, value });
    } else say(switch (id) {
        -16 => "Your Mac is still busy with the last change. Try again.",
        -13 => "This copy of Settings may not control hardware.",
        else => "The request could not be sent.",
    }, true);
}

fn poll() bool {
    if (pending == 0) return false;
    const result = pulp.syscall3(112, 1, @bitCast(pending), 0);
    if (result == -11) return false;
    pending = 0;
    say(switch (result) {
        0 => switch (pending_act) {
            Act.wifi => "Your Mac's Wi-Fi was switched.",
            Act.bluetooth => "Your Mac's Bluetooth was switched.",
            Act.volume => "Your Mac's volume was changed.",
            else => "Your Mac's brightness was changed.",
        },
        -13 => NEEDS_GRANT,
        -95 => "This Mac does not support that control.",
        -110, -107 => "Your Mac did not answer. Is the Companion running?",
        else => "Your Mac could not make the change.",
    }, result != 0);
    pulp.print("settings: device command {d} result {d}\n", .{ pending_act, result });
    return true;
}

fn setPassword() void {
    const name = name_field.text();
    if (!account.validName(name)) return say("Type your name (up to 32 letters, no = sign).", true);
    if (user) |*u| if (!u.check(current_field.text())) return say("The current password is not right.", true);
    if (new_field.len < account.MIN_PASSWORD) return say("Use at least 4 characters for the password.", true);
    if (!std.mem.eql(u8, new_field.text(), confirm_field.text())) return say("The two passwords are not the same.", true);
    var salt: [16]u8 = undefined;
    pulp.random(&salt) catch return say("The system could not make a random salt.", true);
    const created = account.Account.create(name, new_field.text(), salt) orelse return say("That name or password cannot be used.", true);
    var buf: [256]u8 = undefined;
    const body = created.serialize(&buf) orelse return;
    if (!appkit.writeFileAtomic(account.PATH, body)) return say("The password could not be saved.", true);
    user = created;
    wipeFields();
    app.win.setPreference(proto.Pref.account_changed, 0);
    say("Password set. The screen asks for it at start-up and when locked.", false);
    pulp.puts("settings: password set\n");
}

fn removePassword() void {
    const u = user orelse return;
    if (!u.check(current_field.text())) return say("Type the current password first, then Remove Password.", true);
    pulp.unlink(account.PATH) catch return say("The password could not be removed.", true);
    user = null;
    wipeFields();
    app.win.setPreference(proto.Pref.account_changed, 0);
    say("Password removed. The screen no longer locks.", false);
    pulp.puts("settings: password removed\n");
}

/// Typed passwords do not stay in memory once used.
fn wipeFields() void {
    for ([_]*Field{ &current_field, &new_field, &confirm_field }) |f| {
        @memset(&f.buf, 0);
        f.clear();
    }
    focus = null;
}

fn activate(i: usize, segment: usize) void {
    const row = rows[i];
    switch (row.act) {
        Act.wifi => sendToMac(6, @intFromBool(!row.on), 1, Act.wifi),
        Act.bluetooth => sendToMac(7, @intFromBool(!row.on), 1, Act.bluetooth),
        Act.theme => app.win.setPreference(proto.Pref.theme, @intCast(segment)),
        Act.reduce_motion => app.win.setPreference(proto.Pref.reduce_motion, @intFromBool(!row.on)),
        Act.lock_after => app.win.setPreference(proto.Pref.lock_minutes, ([_]u32{ 0, 1, 5, 15 })[@min(segment, 3)]),
        Act.lock_now => app.win.setPreference(proto.Pref.lock_now, 0),
        Act.set_password => setPassword(),
        Act.remove_password => removePassword(),
        else => if (row.kind == .field) {
            focus = row.field;
        },
    }
}

fn commitSlider(i: usize, level: i32) void {
    const row = rows[i];
    if (row.act == Act.volume) sendToMac(0, @intCast(level), host.rows[3].device, Act.volume);
    if (row.act == Act.brightness) sendToMac(5, @intCast(@max(5, level)), host.rows[2].device, Act.brightness);
}

// ── Drawing ───────────────────────────────────────────────────────────────

fn paint() void {
    build();
    var s = app.surface();
    const W = app.width();
    const H = app.height();
    const T = ui.Tone;
    const pointer = app.pointer;
    s.fill(.{ .x = 0, .y = 0, .w = W, .h = H }, CANVAS);
    s.fill(.{ .x = 0, .y = 0, .w = SIDEBAR_W, .h = H }, T.sidebar);
    s.fill(.{ .x = SIDEBAR_W - 1, .y = 0, .w = 1, .h = H }, T.hairline);
    for (PANES, 0..) |info, i| {
        const r = sidebarRow(i);
        const active = @intFromEnum(pane) == i;
        if (active) s.rounded(r, 7, T.accent, 255) else if (pointer.hover == 1 + i) s.rounded(r, 7, 0xE1E3E8, 255);
        // A small glossy tile in the pane's own colour, with a white symbol.
        const tile = ui.Rect{ .x = r.x + 7, .y = r.y + 5, .w = 20, .h = 20 };
        s.rounded(tile, 5, info.tint, 255);
        s.rounded(.{ .x = tile.x + 1, .y = tile.y + 1, .w = 18, .h = 8 }, 4, 0xFFFFFF, 46);
        ui.iconTint(&s, info.icon, tile.x + 3, tile.y + 3, 14, 0xFFFFFF);
        ui.label(&s, info.name, r.x + 36, r.y + 11, 1, if (active) 0xFFFFFF else 0x2B2E34);
    }
    // The pane's name where a toolbar title goes.
    ui.label(&s, PANES[@intFromEnum(pane)].name, contentX(), 22, 1, T.text);
    s.fill(.{ .x = SIDEBAR_W, .y = BAR - 1, .w = W - SIDEBAR_W, .h = 1 }, T.hairline);

    // Cards first, then the rows on them.
    var start: usize = 0;
    for (rows[0..row_count], 0..) |row, i| {
        if (row.kind == .note) {
            start = i + 1;
            continue;
        }
        if (row.last) {
            const top = rowRect(start);
            const bottom = rowRect(i);
            const card = ui.Rect{ .x = top.x, .y = top.y, .w = top.w, .h = bottom.bottom() - top.y };
            s.rounded(.{ .x = card.x, .y = card.y + 1, .w = card.w, .h = card.h }, 10, 0x000000, 14);
            s.rounded(card, 10, 0xFFFFFF, 255);
            start = i + 1;
        }
    }
    for (rows[0..row_count], 0..) |row, i| {
        const r = rowRect(i);
        if (r.bottom() > H) break;
        if (row.kind == .note) {
            ui.label(&s, ui.fitting(row.label, r.w - 8), r.x + 4, r.y + 7, 1, if (row.bad) 0xB05251 else T.secondary);
            continue;
        }
        if (!row.last) s.fill(.{ .x = r.x + 16, .y = r.bottom() - 1, .w = r.w - 16, .h = 1 }, 0xECEDF0);
        const c = controlRect(i);
        const label_room = (if (row.kind == .info) r.w - 32 else c.x - r.x - 28);
        ui.label(&s, ui.fitting(row.label, @max(0, label_room)), r.x + 16, r.y + 18, 1, T.text);
        const id: u32 = @intCast(100 + i);
        switch (row.kind) {
            .info => {
                const room = r.w - 48 - ui.textWidth(ui.fitting(row.label, label_room), 1);
                const shown = ui.fitting(row.value, @max(0, room));
                ui.label(&s, shown, r.right() - 16 - ui.textWidth(shown, 1), r.y + 18, 1, T.secondary);
            },
            .toggle => {
                ui.switchControl(&s, c, row.on);
                if (!row.enabled) s.rounded(c, 12, 0xFFFFFF, 150);
            },
            .slider, .meter => {
                const level = if (drag_row == i) drag_level else row.level;
                const track = ui.Rect{ .x = c.x + 8, .y = c.y + @divTrunc(c.h, 2) - 2, .w = c.w - 16, .h = 5 };
                s.rounded(track, 2, 0xDCDEE3, 255);
                const fill_w = @divTrunc(track.w * level, 100);
                const tone: u32 = if (row.bad) 0xE0544A else if (row.good) 0x34C759 else T.accent;
                if (fill_w > 0) s.rounded(.{ .x = track.x, .y = track.y, .w = fill_w, .h = track.h }, 2, if (row.enabled or row.kind == .meter) tone else 0xB9BDC6, 255);
                if (row.kind == .slider) {
                    // A round glossy knob with a soft shadow.
                    const kx = track.x + fill_w;
                    const ky = track.y + 2;
                    s.circle(kx, ky + 1, 10, 0xD0D3D9);
                    s.circle(kx, ky, 9, if (row.enabled) 0xFFFFFF else 0xF1F2F4);
                }
                const value = if (drag_row == i) text("{d}%", .{drag_level}) else row.value;
                // Meters carry longer text ("41 MB of 96 MB used") under the bar's left.
                if (row.kind == .meter and ui.textWidth(value, 1) > 44) {
                    ui.label(&s, ui.fitting(value, c.w + 44), c.right() + 44 - ui.textWidth(ui.fitting(value, c.w + 44), 1), r.y + 28, 1, T.secondary);
                } else ui.label(&s, value, c.right() + 44 - ui.textWidth(value, 1), r.y + 18, 1, T.secondary);
            },
            .button => {
                var st = ui.ControlState.of(pointer, id);
                st.enabled = row.enabled;
                ui.pushButton(&s, c, row.value, row.act == Act.set_password, st);
            },
            .choice => {
                const hover: ?usize = if (pointer.hover >= 200 + i * 8 and pointer.hover < 200 + i * 8 + 8) pointer.hover - 200 - i * 8 else null;
                ui.segmented(&s, c, row.choices.len, row.selected, hover);
                for (row.choices, 0..) |choice, k| {
                    const seg = ui.segment(c, row.choices.len, k);
                    ui.label(&s, choice, seg.x + @divTrunc(seg.w - ui.textWidth(choice, 1), 2), seg.y + 10, 1, if (!row.enabled) T.disabled else if (k == row.selected) T.accent else T.text);
                }
            },
            .field => if (row.field) |f| ui.textField(&s, c, f.text(), f.caret, focus == f, row.secure, ""),
            .note => {},
        }
    }
    app.presentAll();
    if (pulp.desktop_profile) pulp.print("settings: painted {s}\n", .{PANES[@intFromEnum(pane)].name});
}

fn refreshHost() bool {
    const n = pulp.syscall3(111, 0, @intFromPtr(&host_json), host_json.len);
    const next = model.parse(host_json[0..if (n > 0) @intCast(n) else 0], &host_scratch);
    if (host.eql(next)) return false;
    host = next;
    return true;
}

const MENU = "MView\nI1 Wi-Fi\nI2 Bluetooth\nI4 Sound\nI5 Display\nI7 Appearance\nI8 Lock Screen\nI12 About\n";

export fn _start() callconv(.c) noreturn {
    app = appkit.App.open(.{
        .title = "Settings",
        .app = proto.App.settings,
        .width = 800,
        .height = 580,
        .x = 240,
        .y = 80,
        .min_w = 700,
        .min_h = 520,
        .bar_height = BAR,
        .menu = MENU,
    });
    loadAccount();
    _ = refreshHost();
    app.win.requestPreferences();
    paint();
    var last_host: u64 = 0;
    while (true) {
        var dirty = false;
        const now = pulp.uptimeMs();
        if (now -| last_host >= 500) {
            last_host = now;
            if (refreshHost()) dirty = true;
            if (poll()) dirty = true;
            // The clock in Date & Time ticks.
            if (pane == .datetime) if (pulp.wallTime()) |sec| if (sec != last_second) {
                last_second = sec;
                dirty = true;
            };
        }
        while (app.next()) |event| switch (event) {
            .close => app.quit(),
            .resized => dirty = true,
            .preferences => |p| {
                prefs = p;
                have_prefs = true;
                dirty = true;
            },
            .menu => |id| if (id >= 1 and id <= PANES.len) {
                pane = @enumFromInt(id - 1);
                say("", false);
                focus = null;
                dirty = true;
            },
            .key => |k| if (k.down) {
                if (focus) |f| {
                    if (k.code == K.enter and pane == .lock) {
                        setPassword();
                    } else if (k.code == K.tab) {
                        // Tab walks the fields of the pane, and wraps.
                        var fields: [6]*Field = undefined;
                        var n: usize = 0;
                        var at: usize = 0;
                        for (rows[0..row_count]) |row| if (row.kind == .field and n < fields.len) {
                            if (row.field == f) at = n;
                            fields[n] = row.field.?;
                            n += 1;
                        };
                        if (n > 0) focus = fields[(at + 1) % n];
                    } else if (k.code == K.esc) {
                        focus = null;
                    } else if (k.ch != 0) {
                        _ = f.insert(k.ch);
                    } else _ = f.editKey(k.code);
                    dirty = true;
                } else if (k.code == K.up or k.code == K.down) {
                    const i = @intFromEnum(pane);
                    const next = if (k.code == K.up) i -| 1 else @min(PANES.len - 1, i + 1);
                    if (next != i) {
                        pane = @enumFromInt(next);
                        say("", false);
                        dirty = true;
                    }
                }
            },
            .mouse => |m| {
                const before = app.pointer;
                var buttons: [MAX_TARGETS]ui.Button = undefined;
                const list = targets(&buttons);
                const action = app.click(m, list);
                if (app.pointer.visualChanged(before)) dirty = true;
                // Sliders follow the pointer while held and act on release.
                if (m.pressed and app.pointer.pressed >= 100 and app.pointer.pressed < 200) {
                    const i: usize = app.pointer.pressed - 100;
                    if (rows[i].kind == .slider) {
                        drag_row = i;
                        drag_level = sliderLevel(i, m.x);
                        dirty = true;
                    }
                }
                if (drag_row) |i| {
                    if (m.buttons & 1 != 0) {
                        const level = sliderLevel(i, m.x);
                        if (level != drag_level) {
                            drag_level = level;
                            dirty = true;
                        }
                    } else {
                        drag_row = null;
                        commitSlider(i, drag_level);
                        dirty = true;
                    }
                } else if (action >= 1 and action <= PANES.len) {
                    pane = @enumFromInt(action - 1);
                    say("", false);
                    focus = null;
                    dirty = true;
                } else if (action >= 200) {
                    activate((action - 200) / 8, (action - 200) % 8);
                    dirty = true;
                } else if (action >= 100) {
                    if (rows[action - 100].kind != .slider) activate(action - 100, 0);
                    dirty = true;
                } else if (m.pressed and app.pointer.pressed == 0) {
                    if (m.y >= 0 and m.y < BAR) app.win.requestMove();
                    if (focus != null) {
                        focus = null;
                        dirty = true;
                    }
                }
            },
            else => {},
        };
        if (dirty) paint();
        app.idle();
    }
}
