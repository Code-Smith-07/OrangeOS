//! Grove — the Orange OS desktop shell.
//!
//! A launcher built on Segment. Clicking an entry spawns the program, which
//! then asks Peel for its own window. Grove has no special authority: it is an
//! ordinary application that happens to call spawn.

const pulp = @import("pulp");
const segment = @import("segment");

const Entry = struct {
    label: []const u8,
    path: []const u8,
};

const ENTRIES = [_]Entry{
    .{ .label = "Terminal", .path = "/bin/squeeze" },
    .{ .label = "Clock", .path = "/bin/clock" },
    .{ .label = "About", .path = "/bin/about" },
};

var app: segment.App = undefined;
var status_id: u32 = 0;
var launched: u32 = 0;

/// Called by Segment when a launcher button is released over itself.
fn launch(id: u32) void {
    // Widget ids are assigned in creation order; the buttons start after the
    // header widgets, so the entry index is derived from the offset.
    const first_button: u32 = 4;
    if (id < first_button) return;
    const index = id - first_button;
    if (index >= ENTRIES.len) return;

    const entry = ENTRIES[index];
    if (pulp.spawn(entry.path)) |pid| {
        launched += 1;
        pulp.print("grove: launched {s} as pid {d}\n", .{ entry.path, pid });
        app.setText(status_id, entry.label);
    } else |_| {
        pulp.print("grove: cannot launch {s}\n", .{entry.path});
        app.setText(status_id, "launch failed");
    }
}

export fn _start() callconv(.c) noreturn {
    app = segment.createApp("Grove", 220, 240, 900, 90) catch {
        pulp.puts("grove: no display server\n");
        pulp.exit(1);
    };

    _ = app.panel(0, 0, 220, 30, segment.theme.surface);
    _ = app.label("Orange OS", 12, 11, 1, segment.theme.accent);
    _ = app.separator(0, 30, 220);

    var y: i32 = 44;
    for (ENTRIES) |_| {
        // Ids come back in order; launch() maps them to entries by offset.
        y += 0;
        break;
    }

    y = 44;
    var i: usize = 0;
    while (i < ENTRIES.len) : (i += 1) {
        _ = app.button(ENTRIES[i].label, 12, y, 196, 30, launch);
        y += 38;
    }

    _ = app.separator(0, y + 6, 220);
    status_id = app.label("ready", 12, y + 18, 1, segment.theme.text_dim);

    app.run();
}
