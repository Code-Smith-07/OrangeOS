//! Readiness notification for objects that become readable or writable over
//! time: pipe ends, eventfds, socket ends.
//!
//! Each such object end carries a Source. A Watcher (an epoll interest)
//! attaches to it and is called whenever the object's state may have
//! changed; the watcher then re-queries the state itself, so a notification
//! only ever means "look again". When an end's open file description closes,
//! its Source is detached from every watcher, which is how closing a
//! descriptor removes it from epoll sets without dangling pointers.
//!
//! One global lock covers every watcher list. Watcher callbacks run under it
//! and must be short: they may take the scheduler lock (to wake a waiter)
//! but nothing that calls `notify`.

const spinlock = @import("../sync/spinlock.zig");

pub const Watcher = struct {
    next: ?*Watcher = null,
    prev: ?*Watcher = null,
    /// Null once detached, by the watcher or because the source closed.
    source: ?*Source = null,
    notify: *const fn (*Watcher) void,
};

pub const Source = struct {
    first: ?*Watcher = null,
};

var lock: spinlock.SpinLock = .{};

pub fn acquire() spinlock.IrqState {
    return spinlock.acquireIrqSave(&lock);
}

pub fn releaseLock(state: spinlock.IrqState) void {
    spinlock.releaseIrqRestore(&lock, state);
}

/// Caller holds the readiness lock.
pub fn attachLocked(source: *Source, watcher: *Watcher) void {
    watcher.source = source;
    watcher.prev = null;
    watcher.next = source.first;
    if (source.first) |first| first.prev = watcher;
    source.first = watcher;
}

/// Caller holds the readiness lock. Harmless on a detached watcher.
pub fn detachLocked(watcher: *Watcher) void {
    const source = watcher.source orelse return;
    if (watcher.prev) |prev| prev.next = watcher.next else source.first = watcher.next;
    if (watcher.next) |next| next.prev = watcher.prev;
    watcher.next = null;
    watcher.prev = null;
    watcher.source = null;
}

/// The object's state may have changed.
pub fn notify(source: *Source) void {
    const state = acquire();
    defer releaseLock(state);
    var cursor = source.first;
    while (cursor) |watcher| {
        cursor = watcher.next;
        watcher.notify(watcher);
    }
}

/// The end is closing: detach every watcher, then tell each once more so it
/// notices the source is gone.
pub fn detachAll(source: *Source) void {
    const state = acquire();
    defer releaseLock(state);
    while (source.first) |watcher| {
        detachLocked(watcher);
        watcher.notify(watcher);
    }
}
