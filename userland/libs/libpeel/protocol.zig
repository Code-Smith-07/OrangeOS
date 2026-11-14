//! The Peel display protocol.
//!
//! One port carries control; shared memory carries pixels. A client never
//! sends pixel data through the kernel — it writes into a buffer Peel has
//! mapped and then sends a 32-byte message saying which rectangle changed.
//! That split is why compositing stays cheap.
//!
//! Both Peel and its clients build against this file, so the wire format
//! cannot drift between them.

pub const PORT = "peel";

pub const WindowFlags = struct {
    pub const closable: u32 = 1 << 0;
    /// Top-right transient surface: no frame, dragging, dock or overview entry.
    /// Presentation only; grants no host-control authority.
    pub const panel: u32 = 1 << 1;
    /// The user may resize the window (docs/design/014, M2). The client
    /// allocates its buffer at the capacity in CreateWindow and redraws at
    /// each size Peel configures.
    pub const resizable: u32 = 1 << 2;
    /// The client draws under the title area (a toolbar window, like Finder):
    /// Peel draws no title bar, only the window buttons, centred in the
    /// client's `bar_height`. The client asks Peel to move the window when
    /// its own empty toolbar is dragged (Op.move_request).
    pub const full_size_content: u32 = 1 << 3;
    /// The close button asks the client (close_requested) and leaves the
    /// window up, so a document with unsaved changes can ask first. A
    /// second press on the button closes it regardless.
    pub const confirms_close: u32 = 1 << 4;
};

/// The applications Peel knows: the dock, the menu bar's app name, Spotlight
/// and "open this document" all use these numbers. A window says which it
/// belongs to when it is created (0 is Welcome, the default).
pub const App = struct {
    pub const welcome: u32 = 0;
    pub const terminal: u32 = 1;
    pub const clock: u32 = 2;
    pub const about: u32 = 3;
    pub const files: u32 = 4;
    pub const trash: u32 = 5;
    pub const controls: u32 = 6;
    pub const browser: u32 = 7;
    pub const editor: u32 = 8;
    pub const viewer: u32 = 9;
    pub const calculator: u32 = 10;
    pub const settings: u32 = 11;
    pub const count: usize = 12;
};

pub const Op = struct {
    /// Client -> Peel: please give me a window.
    pub const create_window: u32 = 1;
    /// Client -> Peel: this rectangle of my buffer changed.
    pub const commit: u32 = 2;
    /// Client -> Peel: I am going away.
    pub const destroy: u32 = 3;
    /// Client -> desktop: focus or launch a built-in application (u32 index).
    pub const launch_app: u32 = 4;
    /// Query backing scale before allocating client pixels (payload: i64 pid).
    pub const display_info: u32 = 5;
    pub const display_info_reply: u32 = 131;
    /// Request a public desktop panel (u32 action: overview or appearance).
    pub const desktop_panel: u32 = 6;
    /// Client -> Peel: my buffer now holds a frame of this size (Resized),
    /// in answer to a configure.
    pub const resized: u32 = 7;
    /// Client -> Peel: the user pressed my toolbar background; move the
    /// window with the pointer (Destroy payload: just the window id).
    pub const move_request: u32 = 8;
    /// Client -> Peel: open this file with the application that handles it
    /// (payload: the path). Peel starts the app and hands it the path.
    pub const open_document: u32 = 9;
    /// Client -> Peel: change my title bar text (payload: the title).
    pub const set_title: u32 = 10;
    /// Client -> Peel: my menus for the menu bar (payload: see Menu below).
    pub const set_menu: u32 = 11;
    /// Client -> Peel: show a notification (Notify).
    pub const notify: u32 = 12;
    /// Settings -> Peel: change a desktop preference (Preference).
    pub const set_preference: u32 = 13;
    /// Client -> Peel: tell me the desktop preferences (payload: i64 pid).
    pub const get_preferences: u32 = 14;
    /// Peel -> client: your window was created.
    pub const created: u32 = 128;
    /// Peel -> client: an input event landed on you.
    pub const input: u32 = 129;
    /// Peel -> client: the user pressed the window's close button.
    pub const close_requested: u32 = 130;
    /// Peel -> panel: current desktop palette (u32), on creation and changes.
    pub const appearance: u32 = 132;
    /// Peel -> client: please draw at this size (Configure).
    pub const configure: u32 = 133;
    /// Peel -> client: open this file (payload: the path).
    pub const open_file: u32 = 134;
    /// Peel -> client: the user chose one of your menu items (u32 id).
    pub const menu_action: u32 = 135;
    /// Peel -> client: the desktop preferences (Preferences).
    pub const preferences: u32 = 136;
};

/// Menus are sent as text, one item per line, so they are easy to build
/// and to check: `M<title>` starts a menu, `I<id> <label>` adds an item,
/// `D<id> <label>` a disabled one, `-` a separator; a tab and a shortcut
/// may follow a label (shown at the right). At most 6 menus of 12 items.
pub const MENU_MAX_BYTES: usize = 1024;

pub const Notify = extern struct {
    title_len: u32,
    body_len: u32,
    title: [48]u8,
    body: [120]u8,
};

/// Preference keys for set_preference.
pub const Pref = struct {
    pub const theme: u32 = 1;
    pub const reduce_motion: u32 = 2;
    /// Minutes of no input before the screen locks (0: never).
    pub const lock_minutes: u32 = 3;
    /// Lock the screen now (value ignored).
    pub const lock_now: u32 = 4;
    /// The account file changed: read it again (value ignored).
    pub const account_changed: u32 = 5;
};

pub const Preference = extern struct {
    key: u32,
    value: u32,
};

pub const Preferences = extern struct {
    theme: u32,
    reduce_motion: u32,
    lock_minutes: u32,
    /// 1 when preferences reach the /data disk.
    kept: u32,
    /// 1 when a password is set.
    has_password: u32,
    screen_width: u32,
    screen_height: u32,
    scale: u32,
};

/// Peel's answer to display_info: the backing scale, and the largest
/// content a window can have on this screen (logical points), which is
/// what a resizable client allocates.
pub const DisplayInfo = extern struct {
    scale: u32,
    max_width: u32,
    max_height: u32,
};

/// Request to create a window. `shm_name` names a buffer the client has
/// already created, sized width * height * 4 bytes.
pub const CreateWindow = extern struct {
    /// The client's pid, so Peel can derive its reply port name. Handle
    /// transfer would make this unnecessary; it does not exist yet.
    pid: i64,
    width: u32,
    height: u32,
    x: i32,
    y: i32,
    title_len: u32,
    shm_name_len: u32,
    flags: u32,
    /// Logical dimensions above; buffer is width*scale by height*scale.
    scale: u32,
    /// Resizable windows: the buffer is capacity_w by capacity_h logical
    /// pixels (rows are capacity_w * scale apart), and the content may be
    /// resized between the minimum and the capacity. Others: 0.
    capacity_w: u32 = 0,
    capacity_h: u32 = 0,
    min_w: u32 = 0,
    min_h: u32 = 0,
    /// Full-size content: the height of the client's top bar, in which Peel
    /// centres the window buttons.
    bar_height: u32 = 0,
    /// Which application this window belongs to (App.*).
    app: u32 = 0,
    title: [48]u8,
    shm_name: [32]u8,
};

/// Client says part of its buffer changed.
pub const Commit = extern struct {
    window_id: u32,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

/// Peel asks a resizable client to draw at a new content size, and the
/// client answers with the same struct once its buffer shows that size.
pub const Configure = extern struct {
    window_id: u32,
    width: u32,
    height: u32,
};

/// Either side identifies the window whose lifetime is ending.
pub const Destroy = extern struct {
    window_id: u32,
};

/// Peel's answer to create_window.
pub const Created = extern struct {
    window_id: u32,
    width: u32,
    height: u32,
};

/// An input event, in window-relative coordinates.
pub const Input = extern struct {
    window_id: u32,
    kind: u8,
    code: u8,
    value: u8,
    reserved: u8,
    x: i32,
    y: i32,
};

pub fn replyPortName(buf: []u8, pid: i64) []const u8 {
    // "peel.<pid>" — each client gets its own reply port, since handle
    // transfer does not exist yet and a shared reply port would deliver one
    // client's answer to another.
    const prefix = "peel.";
    @memcpy(buf[0..prefix.len], prefix);
    var n = prefix.len;

    var digits: [20]u8 = undefined;
    var d: usize = 0;
    var v: u64 = @intCast(if (pid < 0) 0 else pid);
    if (v == 0) {
        digits[0] = '0';
        d = 1;
    } else {
        while (v > 0) : (v /= 10) {
            digits[d] = '0' + @as(u8, @intCast(v % 10));
            d += 1;
        }
    }
    var i: usize = 0;
    while (i < d) : (i += 1) {
        buf[n] = digits[d - 1 - i];
        n += 1;
    }
    return buf[0..n];
}

pub fn shmName(buf: []u8, pid: i64) []const u8 {
    const prefix = "win.";
    @memcpy(buf[0..prefix.len], prefix);
    var n = prefix.len;

    var digits: [20]u8 = undefined;
    var d: usize = 0;
    var v: u64 = @intCast(if (pid < 0) 0 else pid);
    if (v == 0) {
        digits[0] = '0';
        d = 1;
    } else {
        while (v > 0) : (v /= 10) {
            digits[d] = '0' + @as(u8, @intCast(v % 10));
            d += 1;
        }
    }
    var i: usize = 0;
    while (i < d) : (i += 1) {
        buf[n] = digits[d - 1 - i];
        n += 1;
    }
    return buf[0..n];
}
