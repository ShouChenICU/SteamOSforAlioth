#!/usr/bin/env python3
"""Write an empty AVB vbmeta image with verification disabled (flags = 2,
like `avbtool make_vbmeta_image --flags 2 --padding_size 4096`).

    mk-vbmeta-disabled.py OUT

Flashed to vbmeta_b, it lets an unlocked tablet start our boot image from
slot b (microSD dual boot) without the stock image's hash checks."""
import struct, sys

hdr = bytearray(256)
hdr[0:4] = b"AVB0"
struct.pack_into(">II", hdr, 4, 1, 0)          # required libavb 1.0
# block sizes, algorithm, offsets and sizes all 0: no signature, no descriptors
struct.pack_into(">QI", hdr, 112, 0, 2)        # rollback index 0, flags: verification disabled
rel = b"avbtool 1.2.0"
hdr[128:128 + len(rel)] = rel
open(sys.argv[1], "wb").write(bytes(hdr) + bytes(4096 - len(hdr)))
