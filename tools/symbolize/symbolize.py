#!/usr/bin/env python3
"""Orange OS — resolve kernel backtrace addresses to function names.

Reads the kernel ELF's symbol table and maps addresses to `function +offset`.
Feed it a panic backtrace and it tells you where the fault actually was.

Usage:
    ./tools/symbolize/symbolize.py 0xffffffff8000c34f 0xffffffff800082b9
    cat build/serial.log | ./tools/symbolize/symbolize.py
    ./tools/symbolize/symbolize.py --elf path/to/kernel.elf 0x...
"""

import re
import struct
import sys

DEFAULT_ELF = "zig-out/bin/kernel.elf"
STT_FUNC = 2


def load_symbols(path):
    with open(path, "rb") as fh:
        f = fh.read()
    if f[:4] != b"\x7fELF":
        sys.exit(f"{path}: not an ELF file")

    (e_shoff,) = struct.unpack_from("<Q", f, 0x28)
    e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", f, 0x3A)

    def sh(i):
        return struct.unpack_from("<IIQQQQIIQQ", f, e_shoff + i * e_shentsize)

    _, _, _, _, so, ss, *_ = sh(e_shstrndx)
    shstr = f[so : so + ss]

    def name(off, blob):
        return blob[off : blob.index(b"\0", off)].decode(errors="replace")

    symtab = strtab = None
    for i in range(e_shnum):
        n, _, _, _, off, size, _, _, _, entsz = sh(i)
        if name(n, shstr) == ".symtab":
            symtab = (off, size, entsz)
        elif name(n, shstr) == ".strtab":
            strtab = (off, size)

    if not symtab or not strtab:
        sys.exit(f"{path}: no symbol table (was the kernel built with -fno-strip?)")

    off, size, entsz = symtab
    so2, ss2 = strtab
    st = f[so2 : so2 + ss2]

    syms = []
    for i in range(size // entsz):
        n, info, _, _, value, sz = struct.unpack_from("<IBBHQQ", f, off + i * entsz)
        if value and (info & 0xF) == STT_FUNC:
            syms.append((value, sz, name(n, st)))
    syms.sort()
    return syms


def resolve(syms, addr):
    best = None
    for value, size, nm in syms:
        if value <= addr and (size == 0 or addr < value + size):
            best = (value, nm)
    return best


def main():
    args = sys.argv[1:]
    elf = DEFAULT_ELF
    if "--elf" in args:
        i = args.index("--elf")
        elf = args[i + 1]
        del args[i : i + 2]

    syms = load_symbols(elf)

    text = " ".join(args) if args else sys.stdin.read()
    addrs = [int(a, 16) for a in re.findall(r"0x[0-9a-fA-F]{8,16}", text)]

    if not addrs:
        sys.exit("no hex addresses found")

    for a in addrs:
        r = resolve(syms, a)
        if r:
            print(f"0x{a:016x}  {r[1]} +0x{a - r[0]:x}")
        else:
            print(f"0x{a:016x}  <unresolved>")


if __name__ == "__main__":
    main()
