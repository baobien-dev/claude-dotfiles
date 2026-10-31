#!/usr/bin/env python3
# Writes width-table.sh: the code point ranges statusline-lib.sh counts as
# 2 columns (East Asian wide or fullwidth) and as 0 columns (combining marks,
# format characters except the soft hyphen, and conjoining Hangul jamo).
import sys
import unicodedata


def is_zero(cp):
    category = unicodedata.category(chr(cp))
    return (category in ("Mn", "Me", "Cf") and cp != 0xAD) or 0x1160 <= cp <= 0x11FF or 0xD7B0 <= cp <= 0xD7FF


def is_wide(cp):
    return unicodedata.east_asian_width(chr(cp)) in ("W", "F")


def ranges(points):
    out = []
    for cp in points:
        if out and out[-1][1] == cp - 1:
            out[-1][1] = cp
        else:
            out.append([cp, cp])
    return out


def emit(name, points):
    body = "\n".join(f"    0x{lo:X} 0x{hi:X}" for lo, hi in ranges(points))
    return f"{name}=(\n{body}\n)"


zero = [cp for cp in range(sys.maxunicode + 1) if is_zero(cp)]
wide = [cp for cp in range(sys.maxunicode + 1) if is_wide(cp) and not is_zero(cp)]
print("# shellcheck shell=bash disable=SC2034")
print(f"# Written by gen-width-table.py from Python {sys.version.split()[0]}, Unicode {unicodedata.unidata_version}.")
print("# Inclusive code point ranges as lo hi pairs, sorted. Sourced by statusline-lib.sh.")
print(emit("WIDE_RANGES", wide))
print(emit("ZERO_RANGES", zero))
