#!/usr/bin/env python3
"""Deterministic SHA-256 of a Libbox static library (T-ARCH-31).

`gomobile bind` emits a Mach-O `ar` archive — for a multi-architecture slice, one archive per
architecture inside a universal ("fat") file. Two builds of identical source differ in two places
per archive, both in the `__.SYMDEF` symbol index and none in any object member: the mtime that
`libtool` stamps into the index's member header with the build time, and the alignment pad after
the index's last symbol name, which `libtool` never initialises. Blanking every member mtime and
zeroing that pad in every archive makes the digest reproducible, so a third party can rebuild from
the published source and compare against a fixed number. A library whose pad is already zero keeps
the digest it had before the pad was handled.
"""
import hashlib, struct, sys

MAGIC = b"!<arch>\n"
FAT_MAGIC, FAT_MAGIC_64 = 0xCAFEBABE, 0xCAFEBABF

def archives(b):
    """(start, end) of each architecture's archive; the whole file if it is not universal."""
    magic = struct.unpack(">I", b[:4])[0] if len(b) >= 8 else 0
    if magic not in (FAT_MAGIC, FAT_MAGIC_64):
        yield 0, len(b)
        return
    count = struct.unpack(">I", b[4:8])[0]
    for i in range(count):
        if magic == FAT_MAGIC:
            _, _, offset, size, _ = struct.unpack(">iiIII", b[8 + 20 * i:28 + 20 * i])
        else:
            _, _, offset, size, _, _ = struct.unpack(">iiQQII", b[8 + 32 * i:40 + 32 * i])
        yield offset, offset + size

def zero_symdef_padding(b, pos, size):
    """`libtool` pads the `__.SYMDEF` string table to alignment with bytes it never initialises, so
    the pad after the last symbol name differs between two builds of identical objects. Zero it:
    a library whose pad is already zero keeps the digest it had."""
    header = bytes(b[pos:pos + 60])
    data, name = pos + 60, header[0:16].decode().strip()
    if name.startswith("#1/"):
        n = int(name[3:])
        name, data = bytes(b[data:data + n]).rstrip(b"\0").decode(), data + n
    if not name.startswith("__.SYMDEF"):
        return
    wide = name.endswith("_64")
    word, entry = (8, 16) if wide else (4, 8)
    fmt = "<Q" if wide else "<I"
    ranlib_size = struct.unpack(fmt, b[data:data + word])[0]
    table = data + word + ranlib_size
    str_size = struct.unpack(fmt, b[table:table + word])[0]
    strings = table + word
    used = 0
    for i in range(ranlib_size // entry):
        strx = struct.unpack(fmt, b[data + word + i * entry:data + word + i * entry + word])[0]
        used = max(used, b.index(b"\0", strings + strx) + 1 - strings)
    b[strings + used:strings + str_size] = bytes(str_size - used)

def canonicalise(data: bytes) -> bytes:
    b = bytearray(data)
    for start, end in archives(b):
        if b[start:start + len(MAGIC)] != MAGIC:
            continue
        pos = start + len(MAGIC)
        while pos + 60 <= end:
            header = bytes(b[pos:pos + 60])
            if header[58:60] != b"`\n":
                break
            try:
                size = int(header[48:58].decode().strip())
            except ValueError:
                break
            b[pos + 16:pos + 28] = b" " * 12          # mtime field
            zero_symdef_padding(b, pos, size)
            pos += 60 + size
            if size % 2:
                pos += 1
    return bytes(b)

for path in sys.argv[1:]:
    with open(path, "rb") as fh:
        print(hashlib.sha256(canonicalise(fh.read())).hexdigest(), path)
