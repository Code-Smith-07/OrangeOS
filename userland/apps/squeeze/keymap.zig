//! Scancode set 1 to ASCII.
//!
//! The PS/2 controller reports set 1 in QEMU's default translated mode. Only
//! the keys a shell needs are mapped; the rest produce nothing rather than
//! guessing.

pub const LSHIFT: u8 = 0x2A;
pub const RSHIFT: u8 = 0x36;
pub const CTRL: u8 = 0x1D;
pub const CAPS: u8 = 0x3A;
pub const BACKSPACE: u8 = 0x0E;
pub const ENTER: u8 = 0x1C;
pub const TAB: u8 = 0x0F;
pub const ESC: u8 = 0x01;

const unshifted = [_]u8{
    0,    0,   '1',  '2', '3',  '4', '5', '6', '7', '8', '9', '0', '-', '=', 8,   0,
    'q',  'w', 'e',  'r', 't',  'y', 'u', 'i', 'o', 'p', '[', ']', '\n', 0,  'a', 's',
    'd',  'f', 'g',  'h', 'j',  'k', 'l', ';', '\'', '`', 0,  '\\', 'z', 'x', 'c', 'v',
    'b',  'n', 'm',  ',', '.',  '/', 0,   '*', 0,   ' ', 0,   0,   0,   0,   0,   0,
};

const shifted = [_]u8{
    0,    0,   '!',  '@', '#',  '$', '%', '^', '&', '*', '(', ')', '_', '+', 8,   0,
    'Q',  'W', 'E',  'R', 'T',  'Y', 'U', 'I', 'O', 'P', '{', '}', '\n', 0,  'A', 'S',
    'D',  'F', 'G',  'H', 'J',  'K', 'L', ':', '"',  '~', 0,  '|',  'Z', 'X', 'C', 'V',
    'B',  'N', 'M',  '<', '>',  '?', 0,   '*', 0,   ' ', 0,   0,   0,   0,   0,   0,
};

/// Returns the character for a scancode, or 0 if it does not produce one.
pub fn translate(code: u8, shift: bool) u8 {
    if (code >= unshifted.len) return 0;
    return if (shift) shifted[code] else unshifted[code];
}
