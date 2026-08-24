//! Juice — the Orange OS shell.
//!
//! Reads a line, splits it, and either handles it as a builtin or spawns the
//! matching program from /bin. No pipes, redirection, or job control yet.

const pulp = @import("pulp");

const VERSION = "0.1.0";
const MAX_ARGS = 16;
const PATH_DIR = "/bin/";

var cwd_buf: [256]u8 = undefined;
var cwd_len: usize = 1;

fn cwd() []const u8 {
    return cwd_buf[0..cwd_len];
}

fn banner() void {
    pulp.puts("\n");
    pulp.puts("  \x1b[38;5;208mJuice\x1b[0m " ++ VERSION ++ " - the Orange OS shell\n");
    pulp.puts("  type 'help' for builtins\n\n");
}

fn prompt() void {
    pulp.puts("\x1b[38;5;208morange\x1b[0m:");
    pulp.puts(cwd());
    pulp.puts("$ ");
}

// ── Builtins ────────────────────────────────────────────────────────────────

fn builtinHelp() void {
    pulp.puts(
        \\builtins:
        \\  help            this text
        \\  echo <args>     print arguments
        \\  cd <dir>        change directory
        \\  pwd             print working directory
        \\  ls [dir]        list a directory
        \\  cat <file>      print a file
        \\  uptime          milliseconds since boot
        \\  pid             this shell's pid
        \\  clear           clear the screen
        \\  exit            leave the shell
        \\
        \\anything else is looked up in /bin
        \\
    );
}

fn builtinLs(args: [][]const u8, n: usize) void {
    const path = if (n > 1) args[1] else cwd();

    var entries: [32]pulp.DirEntry = undefined;
    const count = pulp.readdir(path, &entries) catch {
        // No @errorName here: it needs the compiler-emitted error name table,
        // which a freestanding binary linked with a custom script does not
        // reliably get, and reading it dereferences null.
        pulp.puts("ls: cannot read directory\n");
        return;
    };

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const e = &entries[i];
        const name = e.nameSlice();
        if (pulp.eql(name, ".") or pulp.eql(name, "..")) continue;
        if (e.isDir()) {
            pulp.print("  \x1b[38;5;208m{s}/\x1b[0m\n", .{name});
        } else {
            pulp.print("  {s}\n", .{name});
        }
    }
}

fn builtinCat(args: [][]const u8, n: usize) void {
    if (n < 2) {
        pulp.puts("cat: missing operand\n");
        return;
    }

    const fd = pulp.open(args[1]) catch {
        pulp.puts("cat: cannot open file\n");
        return;
    };
    defer pulp.close(fd);

    var buf: [512]u8 = undefined;
    while (true) {
        const got = pulp.read(@intCast(fd), &buf) catch break;
        if (got == 0) break;
        pulp.puts(buf[0..got]);
    }
}

/// Resolve a path against the working directory. Absolute paths win.
fn resolvePath(arg: []const u8, out: []u8) []const u8 {
    if (arg.len > 0 and arg[0] == '/') {
        const n = @min(arg.len, out.len);
        @memcpy(out[0..n], arg[0..n]);
        return out[0..n];
    }
    var n: usize = 0;
    const base = cwd();
    @memcpy(out[0..base.len], base);
    n = base.len;
    if (n > 0 and out[n - 1] != '/') {
        out[n] = '/';
        n += 1;
    }
    const take = @min(arg.len, out.len - n);
    @memcpy(out[n .. n + take], arg[0..take]);
    return out[0 .. n + take];
}

fn builtinCd(args: [][]const u8, n: usize) void {
    if (n < 2) {
        cwd_buf[0] = '/';
        cwd_len = 1;
        return;
    }

    var tmp: [256]u8 = undefined;
    const target = resolvePath(args[1], &tmp);

    // Confirm it exists and is a directory before committing.
    var probe: [1]pulp.DirEntry = undefined;
    _ = pulp.readdir(target, &probe) catch {
        pulp.print("cd: {s}: not a directory\n", .{args[1]});
        return;
    };

    @memcpy(cwd_buf[0..target.len], target);
    cwd_len = target.len;
}

/// Run a program from /bin and wait for it.
fn runExternal(args: [][]const u8, n: usize) void {
    _ = n;
    var path: [256]u8 = undefined;
    @memcpy(path[0..PATH_DIR.len], PATH_DIR);
    const take = @min(args[0].len, path.len - PATH_DIR.len);
    @memcpy(path[PATH_DIR.len .. PATH_DIR.len + take], args[0][0..take]);
    const full = path[0 .. PATH_DIR.len + take];

    const pid = pulp.spawn(full) catch {
        pulp.print("juice: {s}: command not found\n", .{args[0]});
        return;
    };

    _ = pulp.wait(pid) catch {};
}

fn execute(line: []const u8) bool {
    var args: [MAX_ARGS][]const u8 = undefined;
    const n = pulp.tokenize(line, &args);
    if (n == 0) return true;

    const cmd = args[0];

    if (pulp.eql(cmd, "exit")) return false;
    if (pulp.eql(cmd, "help")) {
        builtinHelp();
    } else if (pulp.eql(cmd, "echo")) {
        var i: usize = 1;
        while (i < n) : (i += 1) {
            if (i > 1) pulp.puts(" ");
            pulp.puts(args[i]);
        }
        pulp.puts("\n");
    } else if (pulp.eql(cmd, "pwd")) {
        pulp.print("{s}\n", .{cwd()});
    } else if (pulp.eql(cmd, "cd")) {
        builtinCd(&args, n);
    } else if (pulp.eql(cmd, "ls")) {
        builtinLs(&args, n);
    } else if (pulp.eql(cmd, "cat")) {
        builtinCat(&args, n);
    } else if (pulp.eql(cmd, "uptime")) {
        pulp.print("{d} ms\n", .{pulp.uptimeMs()});
    } else if (pulp.eql(cmd, "pid")) {
        pulp.print("{d}\n", .{pulp.getpid()});
    } else if (pulp.eql(cmd, "clear")) {
        pulp.puts("\x1b[2J\x1b[H");
    } else {
        runExternal(&args, n);
    }

    return true;
}

export fn _start() callconv(.c) noreturn {
    cwd_buf[0] = '/';
    cwd_len = 1;

    banner();

    var line: [256]u8 = undefined;
    while (true) {
        prompt();
        const input = pulp.readLine(&line) orelse break;
        if (!execute(input)) break;
    }

    pulp.puts("\ngoodbye.\n");
    pulp.exit(0);
}
