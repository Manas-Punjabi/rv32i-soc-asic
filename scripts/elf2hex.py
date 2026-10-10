#!/usr/bin/env python3
"""Convert an RV32 ELF into a $readmemh word image for tb_core / the SoC memories.

Usage: elf2hex.py <elf> <out.hex> [--base 0x80000000] [--objcopy riscv64-unknown-elf-objcopy]

The image is one 32-bit little-endian word per line, starting at --base; a
sparse '@<word-index>' marker precedes each contiguous region. Gaps between
sections stay zero. Done via objcopy -O binary so no ELF parsing is needed.
"""
import argparse, os, subprocess, tempfile

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("elf")
    ap.add_argument("out")
    ap.add_argument("--base", type=lambda s: int(s, 0), default=0x80000000)
    ap.add_argument("--objcopy", default="riscv64-unknown-elf-objcopy")
    a = ap.parse_args()

    with tempfile.TemporaryDirectory() as td:
        binf = os.path.join(td, "img.bin")
        subprocess.run([a.objcopy, "-O", "binary", a.elf, binf], check=True)
        data = open(binf, "rb").read()

    # objcopy -O binary starts at the lowest loadable address; find it
    lma = subprocess.run([a.objcopy.replace("objcopy", "readelf"), "-l", a.elf],
                         capture_output=True, text=True, check=True).stdout
    starts = [int(l.split()[2], 16) for l in lma.splitlines() if l.strip().startswith("LOAD")]
    start = min(starts) if starts else a.base
    if start < a.base:
        raise SystemExit(f"ELF loads at {start:#x}, below --base {a.base:#x}")

    data += b"\0" * (-len(data) % 4)
    with open(a.out, "w") as fh:
        fh.write(f"@{(start - a.base) // 4:x}\n")
        for i in range(0, len(data), 4):
            fh.write(f"{int.from_bytes(data[i:i+4], 'little'):08x}\n")

if __name__ == "__main__":
    main()
