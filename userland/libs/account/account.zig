//! The user account (docs/design/014, M8): a name and a password check
//! kept on the /data disk. The password itself is never stored: the file
//! holds a random salt and PBKDF2-HMAC-SHA256 of the password, so reading
//! the file does not reveal it. Settings writes the file; Peel reads it to
//! lock and unlock the screen.
//!
//! This protects the session at the keyboard. It is not disk encryption,
//! and OrangeOS has no per-file permissions yet, so another program
//! running in the session could replace the file.
const std = @import("std");

pub const PATH = "/data/account/user";
pub const DIR = "/data/account";
pub const ITERATIONS: u32 = 4096;
pub const MAX_NAME = 32;
pub const MAX_PASSWORD = 64;
pub const MIN_PASSWORD = 4;

pub const Account = struct {
    name_buf: [MAX_NAME]u8 = undefined,
    name_len: usize = 0,
    salt: [16]u8 = [_]u8{0} ** 16,
    hash: [32]u8 = [_]u8{0} ** 32,
    iterations: u32 = ITERATIONS,

    pub fn name(self: *const Account) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn create(user: []const u8, password: []const u8, salt: [16]u8) ?Account {
        if (!validName(user) or password.len < MIN_PASSWORD or password.len > MAX_PASSWORD) return null;
        var a = Account{ .salt = salt, .name_len = user.len };
        @memcpy(a.name_buf[0..user.len], user);
        a.hash = derive(password, salt, ITERATIONS);
        return a;
    }

    /// Constant-time comparison, so timing does not leak how much matched.
    pub fn check(self: *const Account, password: []const u8) bool {
        if (password.len == 0 or password.len > MAX_PASSWORD) return false;
        const got = derive(password, self.salt, self.iterations);
        return std.crypto.timing_safe.eql([32]u8, got, self.hash);
    }

    /// The file's text: name, iterations, salt and hash in hex.
    pub fn serialize(self: *const Account, out: []u8) ?[]const u8 {
        return std.fmt.bufPrint(out, "# Orange OS account\nname={s}\niterations={d}\nsalt={s}\nhash={s}\n", .{
            self.name(), self.iterations, std.fmt.bytesToHex(self.salt, .lower), std.fmt.bytesToHex(self.hash, .lower),
        }) catch null;
    }

    pub fn parse(text: []const u8) ?Account {
        var a = Account{};
        var have: u8 = 0;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "name=")) {
                const v = line[5..];
                if (!validName(v)) return null;
                a.name_len = v.len;
                @memcpy(a.name_buf[0..v.len], v);
                have |= 1;
            } else if (std.mem.startsWith(u8, line, "iterations=")) {
                a.iterations = std.fmt.parseInt(u32, line[11..], 10) catch return null;
                if (a.iterations < 1000 or a.iterations > 1_000_000) return null;
                have |= 2;
            } else if (std.mem.startsWith(u8, line, "salt=")) {
                if (line.len != 5 + 32) return null;
                _ = std.fmt.hexToBytes(&a.salt, line[5..]) catch return null;
                have |= 4;
            } else if (std.mem.startsWith(u8, line, "hash=")) {
                if (line.len != 5 + 64) return null;
                _ = std.fmt.hexToBytes(&a.hash, line[5..]) catch return null;
                have |= 8;
            }
        }
        return if (have == 15) a else null;
    }
};

pub fn validName(user: []const u8) bool {
    if (user.len == 0 or user.len > MAX_NAME) return false;
    for (user) |c| if (c < 32 or c > 126 or c == '=') return false;
    return user[0] != ' ' and user[user.len - 1] != ' ';
}

fn derive(password: []const u8, salt: [16]u8, iterations: u32) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.pwhash.pbkdf2(&out, password, &salt, iterations, std.crypto.auth.hmac.sha2.HmacSha256) catch unreachable;
    return out;
}

const testing = std.testing;

test "the right password unlocks, anything else does not" {
    const salt = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    const a = Account.create("Vishwateja", "orange-1234", salt).?;
    try testing.expect(a.check("orange-1234"));
    try testing.expect(!a.check("orange-1235"));
    try testing.expect(!a.check(""));
    try testing.expect(!a.check("orange-1234 "));
    // PBKDF2-HMAC-SHA256 is a published function: the same inputs must give
    // the RFC 7914 section 11 vector (1 iteration, "passwd" / "salt").
    var out: [64]u8 = undefined;
    try std.crypto.pwhash.pbkdf2(&out, "passwd", "salt", 1, std.crypto.auth.hmac.sha2.HmacSha256);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x55, 0xac, 0x04, 0x6e, 0x56, 0xe3, 0x08, 0x9f }, out[0..8]);
}

test "the account file round-trips and never contains the password" {
    const salt = [_]u8{0xAB} ** 16;
    const a = Account.create("Asha Rao", "s3cret-pass", salt).?;
    var buf: [256]u8 = undefined;
    const text = a.serialize(&buf).?;
    try testing.expect(std.mem.indexOf(u8, text, "s3cret-pass") == null);
    const b = Account.parse(text).?;
    try testing.expectEqualStrings("Asha Rao", b.name());
    try testing.expect(b.check("s3cret-pass") and !b.check("S3cret-pass"));
}

test "bad names, short passwords and damaged files are refused" {
    const salt = [_]u8{7} ** 16;
    try testing.expect(Account.create("", "long-enough", salt) == null);
    try testing.expect(Account.create("a=b", "long-enough", salt) == null);
    try testing.expect(Account.create(" pad", "long-enough", salt) == null);
    try testing.expect(Account.create("ok", "abc", salt) == null);
    try testing.expect(Account.parse("") == null);
    try testing.expect(Account.parse("name=x\nsalt=zz\n") == null);
    try testing.expect(Account.parse("name=x\niterations=5\nsalt=00000000000000000000000000000000\nhash=0000000000000000000000000000000000000000000000000000000000000000\n") == null);
}
