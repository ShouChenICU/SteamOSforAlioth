#!/usr/bin/env python3
"""断言 alioth-mark-slot-successful 只改它该改的那几位，别的一个字节都不动。

用法: scripts/assert-alioth-markslot.py

这个脚本自己造一份合法的 GPT（和真机上 /dev/sde 一样的几何：4096 字节扇区、
96 个 128 字节表项、主 GPT 在 LBA 1/2、备份在尾部），然后对它跑待测脚本。
不碰任何真实块设备。

为什么值得这么测：待测脚本写的是**分区表**，而且写的是 boot_a 和 abl_a 所在
的那块 LUN。写坏了 XBL 就找不到 ABL，那就只能走 EDL 9008。所以它必须在任何
一条前提不成立时拒绝下笔，而「拒绝下笔」这件事在真机上没法安全地试。
"""
import os, struct, subprocess, sys, zlib
from pathlib import Path

SS = 4096
NENT = 96
ESZ = 128
HDR_LBA = 1
ENT_LBA = 2
ENT_SECTORS = (NENT * ESZ + SS - 1) // SS          # 3
NSEC = 557056                                       # 和真机 /dev/sde 一样的量级
BAK_HDR_LBA = NSEC - 1
BAK_ENT_LBA = BAK_HDR_LBA - ENT_SECTORS - 1

ROOT = Path(__file__).resolve().parent.parent
TOOL = ROOT / "alioth-overlay/usr/lib/steamos-arm/alioth-mark-slot-successful"

# attr 的位布局（Qualcomm 的 A/B 槽元数据就放在 GPT 表项的 attributes 高 16 位）
PRIO, ACTIVE, RETRY, SUCCESS, UNBOOT = 48, 50, 51, 54, 55

fails = []
def pass_(n, e): print(f"PASS  {n} — {e}")
def fail(n, e): print(f"FAIL  {n} — {e}"); fails.append(n)


def mkattr(prio=0, active=0, retry=0, success=0, unboot=0):
    return (prio << PRIO) | (active << ACTIVE) | (retry << RETRY) \
         | (success << SUCCESS) | (unboot << UNBOOT)


def rdattr(a):
    return dict(prio=(a >> PRIO) & 3, active=(a >> ACTIVE) & 1,
                retry=(a >> RETRY) & 7, success=(a >> SUCCESS) & 1,
                unboot=(a >> UNBOOT) & 1)


def entry(name, first, last, attr):
    r = bytearray(ESZ)
    r[0:16] = bytes(range(16))                      # type GUID，随便但非零
    r[16:32] = os.urandom(16)
    struct.pack_into("<QQQ", r, 32, first, last, attr)
    nb = name.encode("utf-16-le")
    r[56:56 + len(nb)] = nb
    return bytes(r)


def header(ecrc, cur, bak, elba):
    h = bytearray(92)
    h[0:8] = b"EFI PART"
    struct.pack_into("<IIII", h, 8, 0x10000, 92, 0, 0)
    struct.pack_into("<QQQQ", h, 24, cur, bak, 34, NSEC - 34)
    h[56:72] = os.urandom(16)
    struct.pack_into("<QIII", h, 72, elba, NENT, ESZ, ecrc)
    struct.pack_into("<I", h, 16, zlib.crc32(bytes(h)) & 0xffffffff)
    return bytes(h)


def build(path, parts):
    """parts: [(name, attr)]，其余表项留空。"""
    ents = bytearray(NENT * ESZ)
    for i, (name, attr) in enumerate(parts):
        ents[i * ESZ:(i + 1) * ESZ] = entry(name, 100 + i * 10, 109 + i * 10, attr)
    ecrc = zlib.crc32(bytes(ents)) & 0xffffffff
    img = bytearray(NSEC * SS)
    img[HDR_LBA * SS:HDR_LBA * SS + 92] = header(ecrc, HDR_LBA, BAK_HDR_LBA, ENT_LBA)
    img[ENT_LBA * SS:ENT_LBA * SS + len(ents)] = ents
    img[BAK_HDR_LBA * SS:BAK_HDR_LBA * SS + 92] = header(ecrc, BAK_HDR_LBA, HDR_LBA, BAK_ENT_LBA)
    img[BAK_ENT_LBA * SS:BAK_ENT_LBA * SS + len(ents)] = ents
    path.write_bytes(bytes(img))


def read_gpt(path, hdr_lba):
    d = path.read_bytes()
    h = d[hdr_lba * SS:hdr_lba * SS + 92]
    assert h[:8] == b"EFI PART", "no magic"
    stored_hcrc, = struct.unpack_from("<I", h, 16)
    m = bytearray(h); m[16:20] = b"\0\0\0\0"
    elba, n, esz = struct.unpack_from("<QII", h, 72)
    stored_ecrc, = struct.unpack_from("<I", h, 88)
    e = d[elba * SS:elba * SS + n * esz]
    return dict(
        hcrc_ok=(zlib.crc32(bytes(m)) & 0xffffffff) == stored_hcrc,
        ecrc_ok=(zlib.crc32(e) & 0xffffffff) == stored_ecrc,
        ents=e,
        attrs={e[i * esz + 56:i * esz + 128].decode("utf-16-le").split("\0")[0]:
               struct.unpack_from("<Q", e, i * esz + 48)[0]
               for i in range(n) if e[i * esz:i * esz + 16] != b"\0" * 16},
    )


def run(img, *args):
    return subprocess.run([sys.executable, str(TOOL), "--device", str(img), *args],
                          capture_output=True, text=True)


def main():
    if not TOOL.exists():
        fail("待测脚本存在", f"没有 {TOOL}")
        print(f"\n{len(fails)} 条断言失败"); return 1

    tmp = Path(os.environ.get("TMPDIR", "/tmp")) / f"markslot.{os.getpid()}"
    tmp.mkdir(parents=True, exist_ok=True)
    img = tmp / "sde.img"

    NORMAL = [("abl_a", mkattr(3, 1, 7, 1)),
              ("boot_a", mkattr(3, 1, 6, 0)),
              ("boot_b", mkattr(2, 0, 7, 0)),
              ("userdata", 0)]

    # 1. 把活动槽标成 successful，并把 retry 拉回上限。
    build(img, NORMAL)
    before = read_gpt(img, HDR_LBA)
    r = run(img)
    g = read_gpt(img, HDR_LBA)
    a = rdattr(g["attrs"].get("boot_a", 0))
    if r.returncode == 0 and a["success"] == 1 and a["retry"] == 7:
        pass_("标记活动槽", f"boot_a success=1 retry=7（之前 success=0 retry=6）")
    else:
        fail("标记活动槽", f"退出 {r.returncode}，boot_a={a}，stderr={r.stderr.strip()[:200]}")

    # 2. 改完之后两份 GPT 的四个 CRC 都还对。写坏 CRC 的后果是 XBL 找不到
    #    ABL，而那只能走 EDL 修 —— 所以这条是整套断言里最要紧的一条。
    gb = read_gpt(img, BAK_HDR_LBA)
    if g["hcrc_ok"] and g["ecrc_ok"] and gb["hcrc_ok"] and gb["ecrc_ok"]:
        pass_("CRC 仍然自洽", "主/备 GPT 的 header 与 entries CRC 都对得上")
    else:
        fail("CRC 仍然自洽", f"主 hdr={g['hcrc_ok']} ents={g['ecrc_ok']}；"
                            f"备 hdr={gb['hcrc_ok']} ents={gb['ecrc_ok']}")

    # 3. 备份 GPT 的表项也跟着改了。只改主份的话，XBL 用主份、而恢复逻辑
    #    用备份，两边不一致是个会潜伏很久的坑。
    ab = rdattr(gb["attrs"].get("boot_a", 0))
    if ab["success"] == 1 and ab["retry"] == 7:
        pass_("备份 GPT 同步", f"备份里 boot_a 也是 success=1 retry=7")
    else:
        fail("备份 GPT 同步", f"备份里 boot_a={ab}")

    # 4. 除了 boot_a 的 attributes，别的字节一个都没动。
    diff = []
    for i in range(NENT):
        o, n = before["ents"][i * ESZ:(i + 1) * ESZ], g["ents"][i * ESZ:(i + 1) * ESZ]
        if o == n:
            continue
        name = n[56:128].decode("utf-16-le").split("\0")[0]
        changed = [k for k in range(ESZ) if o[k] != n[k]]
        if name == "boot_a" and all(48 <= k < 56 for k in changed):
            continue
        diff.append(f"{name}:{changed}")
    if not diff:
        pass_("只动了该动的", "只有 boot_a 表项的 attributes 那 8 个字节变了")
    else:
        fail("只动了该动的", f"还动了 {', '.join(diff)}")

    # 5. 幂等。第二次要是又写一遍，就等于每次开机都写一次分区表。
    sha_before = zlib.crc32(img.read_bytes())
    r2 = run(img)
    if r2.returncode == 0 and zlib.crc32(img.read_bytes()) == sha_before:
        pass_("幂等", "第二次退出 0 且一个字节都没写")
    else:
        fail("幂等", f"退出 {r2.returncode}，镜像{'变了' if zlib.crc32(img.read_bytes()) != sha_before else '没变'}")

    # 6. entries CRC 对不上就必须拒绝下笔。这是「我对这张表的理解是否正确」
    #    的唯一自检：算得出存着的那个 CRC，才说明布局读对了。读错了还硬写，
    #    就是在拿分区表赌运气。
    build(img, NORMAL)
    d = bytearray(img.read_bytes())
    d[ENT_LBA * SS + 300] ^= 0xff          # 篡改表项，不修 CRC
    img.write_bytes(bytes(d))
    r3 = run(img)
    if r3.returncode != 0 and img.read_bytes() == bytes(d):
        pass_("CRC 不符时拒绝", f"退出 {r3.returncode}，镜像未被改动")
    else:
        fail("CRC 不符时拒绝", f"退出 {r3.returncode}，镜像{'被改了' if img.read_bytes() != bytes(d) else '没改'}")

    # 7. 没有活动的 boot_* 槽就拒绝。瞎猜一个槽去标记比什么都不做更糟。
    build(img, [("abl_a", mkattr(3, 1, 7, 1)),
                ("boot_a", mkattr(3, 0, 6, 0)),
                ("boot_b", mkattr(2, 0, 7, 0))])
    d = img.read_bytes()
    r4 = run(img)
    if r4.returncode != 0 and img.read_bytes() == d:
        pass_("没有活动槽时拒绝", f"退出 {r4.returncode}，镜像未被改动")
    else:
        fail("没有活动槽时拒绝", f"退出 {r4.returncode}")

    # 8. --dry-run 一个字节都不写。装这个脚本的人要能先看一眼它打算干什么。
    build(img, NORMAL)
    d = img.read_bytes()
    r5 = run(img, "--dry-run")
    if r5.returncode == 0 and img.read_bytes() == d:
        pass_("--dry-run 不写", f"退出 0，镜像未被改动；说: {r5.stdout.strip().splitlines()[-1][:80] if r5.stdout.strip() else ''}")
    else:
        fail("--dry-run 不写", f"退出 {r5.returncode}，镜像{'被改了' if img.read_bytes() != d else '没改'}")

    # 9. 槽被标成 unbootable 时拒绝。那说明 bootloader 已经判它死刑，
    #    把它改回 successful 是在掩盖一个真实故障。
    build(img, [("boot_a", mkattr(3, 1, 0, 0, 1)), ("boot_b", mkattr(2, 0, 7, 0))])
    d = img.read_bytes()
    r6 = run(img)
    if r6.returncode != 0 and img.read_bytes() == d:
        pass_("unbootable 时拒绝", f"退出 {r6.returncode}，镜像未被改动")
    else:
        fail("unbootable 时拒绝", f"退出 {r6.returncode}")

    # 10. --print-active 只把活动槽的后缀印出来，不写一个字节。
    #     alioth-write-boot 靠它决定写哪个槽 —— 印错了就会写错分区。
    build(img, NORMAL)
    d = img.read_bytes()
    r7 = run(img, "--print-active")
    if r7.returncode == 0 and r7.stdout.strip() == "_a" and img.read_bytes() == d:
        pass_("--print-active", "印出 '_a'，镜像未被改动")
    else:
        fail("--print-active", f"退出 {r7.returncode}，stdout='{r7.stdout.strip()}'，"
                              f"镜像{'被改了' if img.read_bytes() != d else '没改'}")

    # 11. 没有恰好一个活动槽时，--print-active 必须失败而不是随便印一个。
    build(img, [("boot_a", mkattr(3, 0, 6, 0)), ("boot_b", mkattr(2, 0, 7, 0))])
    r8 = run(img, "--print-active")
    if r8.returncode != 0 and not r8.stdout.strip():
        pass_("--print-active 没有活动槽时失败", f"退出 {r8.returncode}，stdout 为空")
    else:
        fail("--print-active 没有活动槽时失败",
             f"退出 {r8.returncode}，stdout='{r8.stdout.strip()}'")

    for f in tmp.iterdir():
        f.unlink()
    tmp.rmdir()

    print()
    if fails:
        print(f"{len(fails)} 条断言失败: {', '.join(fails)}")
        return 1
    print("全部通过。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
