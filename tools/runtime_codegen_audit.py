#!/usr/bin/env python3
"""Audit built kernel/app register classes using LLVM's ELF disassembler."""
import pathlib
import re
import shutil
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]


def main():
    objdump = shutil.which("llvm-objdump")
    if objdump is None and shutil.which("xcrun"):
        objdump = subprocess.check_output(["xcrun", "--find", "llvm-objdump"], text=True).strip()
    if not objdump:
        raise SystemExit("Install LLVM's llvm-objdump or Xcode command-line tools")
    for binary in ("kernel.elf", "c-abi-probe", "cxx-abi-probe", "peel"):
        assembly = subprocess.check_output([objdump, "-d", str(ROOT / "zig-out/bin" / binary)], text=True)
        lanes = re.findall(r"\b[xyz]?mm\d+\b", assembly)
        if binary == "kernel.elf":
            assert not lanes, "kernel unexpectedly uses MMX/SIMD registers"
            assert "fxsave64" in assembly and "fxrstor64" in assembly
            print("PASS kernel: explicit FXSAVE64/FXRSTOR64, no MMX/XMM/YMM/ZMM register use")
        else:
            assert re.search(r"\bxmm\d+\b", assembly), f"{binary}: missing native SSE code"
            assert not re.search(r"\b[yz]mm\d+\b", assembly), f"{binary}: unsupported extended registers"
            print(f"PASS {binary}: native SSE code, no YMM/ZMM register use")


if __name__ == "__main__":
    main()
