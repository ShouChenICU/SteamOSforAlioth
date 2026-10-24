#!/usr/bin/env python3
"""Android boot image, header version 4, for devices booted by their stock
ABL (Lenovo Legion Y700 Gen 4).

    mkbootimg-v4.py --kernel Image [--ramdisk initrd] [--cmdline ...] \
        [--os-version 15.0.0] [--os-patch-level 2026-08] --out boot.img

Layout (AOSP boot_img_hdr_v4): one 4096-byte page of header, then the kernel,
the ramdisk and the (empty) boot signature, each padded to 4096. There is no
DTB in a v4 boot image; a kernel that needs its own carries it built in.
"""
import argparse
import struct
import sys

PAGE = 4096
MAGIC = b"ANDROID!"


def pad(data):
    return data + b"\0" * (-len(data) % PAGE)


def os_version(version, patch_level):
    # bits 31-25 a, 24-18 b, 17-11 c (version a.b.c); 10-4 year-2000, 3-0 month
    a, b, c = (int(x) for x in (version.split(".") + ["0", "0"])[:3])
    year, month = (int(x) for x in patch_level.split("-")[:2])
    return (a << 25) | (b << 18) | (c << 11) | ((year - 2000) << 4) | month


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kernel", required=True)
    ap.add_argument("--ramdisk")
    ap.add_argument("--cmdline", default="")
    ap.add_argument("--os-version", default="15.0.0")
    ap.add_argument("--os-patch-level", default="2026-08")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    kernel = open(a.kernel, "rb").read()
    ramdisk = open(a.ramdisk, "rb").read() if a.ramdisk else b""
    cmdline = a.cmdline.encode()
    if len(cmdline) >= 1536:  # 512 + 1024 extra, NUL terminated
        sys.exit(f"cmdline is {len(cmdline)} bytes, the v4 header holds 1535")

    header = struct.pack(
        "<8s4I4II1536sI",
        MAGIC,
        len(kernel),
        len(ramdisk),
        os_version(a.os_version, a.os_patch_level),
        1584,  # header_size: everything up to and including signature_size
        0, 0, 0, 0,  # reserved
        4,  # header_version
        cmdline.ljust(1536, b"\0"),
        0,  # signature_size: no boot signature
    )
    assert len(header) == 1584, len(header)
    with open(a.out, "wb") as f:
        f.write(pad(header))
        f.write(pad(kernel))
        if ramdisk:
            f.write(pad(ramdisk))


if __name__ == "__main__":
    main()
