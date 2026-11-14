//! notify: post a notification from the terminal (docs/design/014, M6).
//!
//! Programs with no window can notify too. Spawned programs do not receive
//! arguments yet, so this one posts a fixed message: enough to see a banner
//! arrive from a shell and to test the path end to end.
const pulp = @import("pulp");
const libpeel = @import("libpeel");

export fn _start() callconv(.c) noreturn {
    libpeel.notifyWithoutWindow("Hello from the terminal", "A program with no window posted this.") catch {
        pulp.puts("notify: the desktop is not running\n");
        pulp.exit(1);
    };
    pulp.puts("notify: posted\n");
    pulp.exit(0);
}
