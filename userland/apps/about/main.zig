//! about — a small Segment application.
//!
//! Exists to be launched from Grove, proving the whole chain: a click in one
//! process starts another, which asks Peel for a window of its own.

const pulp = @import("pulp");
const segment = @import("segment");

var app: segment.App = undefined;
var clicks: u32 = 0;
var counter_id: u32 = 0;
var counter_text: [32]u8 = undefined;

fn bump(id: u32) void {
    _ = id;
    clicks += 1;

    // Format by hand: there is no allocator, and the buffer must outlive the
    // call since the widget only stores a slice of it.
    const prefix = "clicks: ";
    @memcpy(counter_text[0..prefix.len], prefix);
    var n = prefix.len;

    var digits: [10]u8 = undefined;
    var d: usize = 0;
    var v = clicks;
    if (v == 0) {
        digits[0] = '0';
        d = 1;
    } else {
        while (v > 0) : (v /= 10) {
            digits[d] = '0' + @as(u8, @intCast(v % 10));
            d += 1;
        }
    }
    var k: usize = 0;
    while (k < d) : (k += 1) {
        counter_text[n] = digits[d - 1 - k];
        n += 1;
    }

    app.setText(counter_id, counter_text[0..n]);
}

export fn _start() callconv(.c) noreturn {
    app = segment.createApp("About Orange OS", 340, 210, 420, 470) catch {
        pulp.puts("about: no display server\n");
        pulp.exit(1);
    };

    _ = app.panel(0, 0, 340, 34, segment.theme.surface);
    _ = app.label("Orange OS 0.1.0", 14, 13, 1, segment.theme.accent);
    _ = app.separator(0, 34, 340);

    _ = app.label("Zest kernel, written from scratch.", 14, 52, 1, segment.theme.text);
    _ = app.label("Peel compositor. Segment toolkit.", 14, 68, 1, segment.theme.text_dim);
    _ = app.label("No Linux. No BSD. No inherited code.", 14, 84, 1, segment.theme.text_dim);

    counter_id = app.label("clicks: 0", 14, 116, 1, segment.theme.text);
    _ = app.button("Click me", 14, 140, 140, 32, bump);
    _ = app.button("Quit", 170, 140, 140, 32, quit);

    app.run();
}

fn quit(id: u32) void {
    _ = id;
    app.close();
}
