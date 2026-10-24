#!/usr/bin/env bash
# 断言阶段 1 的调试镜像和刷机脚本满足 spec 的硬性约束。
#
# 用法: scripts/assert-alioth-boot-image.sh
#
# 分三组：
#   A. flash-alioth.sh 的槽位安全（Review Focus #1 / #2）—— 这是整个移植里
#      唯一能把手机写坏的代码，所以断言的是「脚本里根本不存在那些写法」，
#      而不是「运行时大概不会走到」。
#   B. boot-debug.img 的结构 —— 页大小、载入地址、cmdline。每一条都对应一个
#      在真机上只会表现为「15 秒后弹回 fastboot」或「黑屏」的失败。
#   C. 内核配置 —— 阶段 1 没有 rootfs 也没有 modprobe，面板和触摸必须是 =y。
set -uo pipefail

PORT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMG_DIR="${STEAMOS_WORK:-${PORT_ROOT}/work}/steamos-alioth"
# ALIOTH_BOOT_IMAGE: flash-alioth.sh 把它正要刷的那个镜像传进来
# （--install 刷 boot.img，--boot/--test 刷 boot-debug.img），这样 B 组
# 结构断言针对的总是真正要写进分区的那一个。
IMG="${ALIOTH_BOOT_IMAGE:-${IMG_DIR}/boot-debug.img}"
KOUT="$(readlink -f "${KERNEL_OUT:-${PORT_ROOT}/work/kernel-sm8250/output/current}" 2>/dev/null || true)"
# FLASH_SCRIPT 可覆盖：用故意违规的副本验证这组断言真的抓得住。
FLASH="${FLASH_SCRIPT:-${PORT_ROOT}/flash-alioth.sh}"
BOOT_PART_SIZE=$((0xC000000))

fails=0
check() { # check <ok> <label> <detail>
  if [[ "$1" == 1 ]]; then printf 'PASS  %s — %s\n' "$2" "$3"
  else printf 'FAIL  %s — %s\n' "$2" "$3"; fails=$((fails + 1)); fi
}

echo "--- A. 刷机脚本的槽位安全 ---"

# 整组 A 都在 python 里做，而且先把源码里「给人看的文本」剔干净再找命令。
# 不这么做的话每一条都能在约束被违反的情况下通过 —— 这不是假设，是实际
# 发生过的：`grep -q current-slot` 会被 die 消息里的那句中文提示满足，
# 而统计「写操作」时 `echo "=> fastboot flash ..."` 和真的 flash 没法区分。
python3 - "$FLASH" <<'PY'
import re, sys

src = open(sys.argv[1]).read()
raw = src.splitlines()

# 代码行：先去注释，再按 heredoc 标记跳过文本段（顺序很重要 —— 反过来的话，
# 一条含 `<<WORD` 的注释会把后面的真代码一路吞到匹配的终止符或文件尾）。
# 区段标记写在注释里，而注释下面会被跳过，所以先按行号把区段算出来。
region_idx, _flag = set(), False
for _n, _l in enumerate(raw):
    if "INSTALL-ONLY REGION" in _l:
        _flag = not _flag
        continue
    if _flag:
        region_idx.add(_n)

code, i = [], 0
while i < len(raw):
    line = raw[i]
    if line.lstrip().startswith("#"):
        i += 1
        continue
    m = re.search(r"""<<-?\s*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\1""", line)
    if m:
        term = m.group(2)
        i += 1
        while i < len(raw) and raw[i].strip() != term:
            i += 1
        i += 1
        continue
    code.append((i, line))
    i += 1

# 命令行：再把 echo / printf 整行剔掉。它们只是把命令打印出来给人看。
cmds_n = [(n, l) for n, l in code
          if not re.match(r"\s*(echo|printf)\b", l)]
code = [l for _, l in code]
cmds = [l for _, l in cmds_n]
code_s, cmds_s = "\n".join(code), "\n".join(cmds)

# INSTALL-ONLY 区段。spec §6.5 要求两个模式的代码路径物理隔离，所以从
# 阶段 2 起，规则按区段分开：写 userdata 和碰 slot b 只许发生在区段**内**，
# 区段外（也就是 --boot/--test 会走到的一切）仍然按阶段 1 的严格规则办。
# super 与 abl 两边都绝对禁止。
raw_out = [l for n, l in enumerate(raw)
           if n not in region_idx and "INSTALL-ONLY REGION" not in l]
cmds_in = [l for n, l in cmds_n if n in region_idx]
cmds_out = [l for n, l in cmds_n if n not in region_idx]

fails = 0
def check(ok, label, detail):
    global fails
    print(("PASS  " if ok else "FAIL  ") + label + " — " + detail)
    if not ok:
        fails += 1

# 1. super 与 abl 绝对禁止 —— 整个文件，连注释和提示文字都不许出现。
#    super 刻意保留着：格掉 userdata 就能把 Android 装回来。abl 是
#    bootloader，写坏了只剩 EDL 9008。
hits = [l for l in raw if re.search(r"\bsuper\b|abl_a|abl_b", l)]
check(not hits, "禁写分区名（全文）",
      "不出现 super / abl_a / abl_b" if not hits
      else "; ".join(h.strip() for h in hits[:3]))

# 1b. userdata 只许出现在 INSTALL-ONLY 区段里。阶段 2 授权了写 userdata，
#     但只授权给 --install；--test 的代码路径上必须根本不存在这种代码，
#     这样迭代内核期间不可能手滑擦掉系统（spec §6.5）。
ud = [l.strip() for l in raw_out if "userdata" in l]
check(not ud, "userdata 只在 INSTALL-ONLY 区段",
      "区段外不出现 userdata" if not ud else "; ".join(ud[:3]))

# 2. slot b 的任何分区都不许出现在**可执行代码**里。救砖说明里的
#    `fastboot --set-active=b` 是给人看的文本，已经被剔掉了。
bslot = [l.strip() for l in cmds_out
         if re.search(r"\b(boot|dtbo|vbmeta|vendor_boot|init_boot|recovery)_b\b", l)]
check(not bslot, "代码里不碰 slot b 的分区",
      "区段外没有 *_b 分区出现在命令里" if not bslot else "; ".join(bslot))

# 3. 目标槽必须被钉死成 a。少了这条，把 TARGET 改成 b 就能让整组 A 全过，
#    而结果是写 boot_b —— 正是硬性约束禁止的那件事。
m = re.search(r"^\s*TARGET=([A-Za-z0-9]+)\s*$", code_s, re.M)
check(bool(m) and m.group(1) == "a", "目标槽钉死为 a",
      "TARGET=%s" % m.group(1) if m else "找不到 TARGET= 赋值")

# 4. 真的去读活动槽，而不只是在错误消息里提到它。
reads = [l.strip() for l in cmds if re.search(r"getvar\s+(\"|')?current-slot", l)]
check(bool(reads), "运行时读活动槽",
      "; ".join(reads) if reads else "代码里没有 getvar current-slot（只在文本里提到不算）")

# 5. 读设备型号，避免把 sm8250 的镜像刷进这个 kit 里别的手机。
prod = [l.strip() for l in cmds if re.search(r"getvar\s+(\"|')?product", l)]
check(bool(prod), "校验设备型号",
      "; ".join(prod) if prod else "代码里没有 getvar product")

# 6. 目标槽==活动槽要拒绝，而且要以非零退出（spec 的原文要求）。
#    在可执行代码里找这个条件分支，并确认它的分支体里有 exit 非零。
blk = re.search(r"if\s*\[\[[^\n]*\$\{?mode\}?[^\n]*--test[^\n]*\$\{?active\}?[^\n]*==[^\n]*"
                r"\$\{?TARGET\}?[^\n]*\]\];?\s*then(.*?)\nfi", code_s, re.S)
if not blk:
    blk = re.search(r"if\s*\[\[[^\n]*\$\{?active\}?[^\n]*==[^\n]*\$\{?TARGET\}?[^\n]*\]\];?\s*then(.*?)\nfi",
                    code_s, re.S)
if not blk:
    check(False, "目标槽==活动槽时拒绝", "找不到比较 $active 与 $TARGET 的条件分支")
else:
    ex = re.search(r"\bexit\s+([1-9][0-9]*)", blk.group(1))
    check(bool(ex), "目标槽==活动槽时拒绝",
          "分支体以 exit %s 退出" % ex.group(1) if ex
          else "找到了分支，但分支体里没有非零 exit —— spec 要求以非零退出")

# 7. 所有真的会执行的 fastboot 写操作都必须经过 $TARGET。
WRITE_RE = r"\bfastboot\b[^\n]*(\bflash\b|\berase\b|\bset_active\b|--set-active|--slot)"
writes = [l.strip() for l in cmds_out if re.search(WRITE_RE, l)]
bad = [w for w in writes if "TARGET" not in w]
check(bool(writes) and not bad, "写操作只针对目标槽",
      "区段外 %d 条，全部经过 $TARGET" % len(writes) if writes and not bad
      else ("有不经 $TARGET 的写操作: %s" % "; ".join(bad) if bad
            else "区段外一条写操作都没有（被换成 echo 了？）"))

# 7c. 区段内的写操作也要在白名单里。阶段 2 允许 --install 写两个槽的
#     boot/dtbo 和 userdata，不允许它写别的任何分区。
ALLOWED = r"(erase|flash)\s+\"?(dtbo_|boot_)|flash\s+userdata|--set-active"
iwrites = [l.strip() for l in cmds_in if re.search(WRITE_RE, l)]
ibad = [w for w in iwrites if not re.search(ALLOWED, w)]
check(bool(iwrites) and not ibad, "区段内只写 boot/dtbo/userdata",
      "区段内 %d 条，都在白名单里" % len(iwrites) if iwrites and not ibad
      else ("区段内有白名单外的写操作: %s" % "; ".join(ibad) if ibad
            else "区段内一条写操作都没有 —— --install 没实现？"))

# 7b. 上面那条只说「存在的写操作都经过 $TARGET」。光有它不够：把真命令换成
#     `echo fastboot flash ...` 同样能通过，因为 echo 行已经被剔掉了，于是
#     「一条违规的写操作都没有」。所以再正面要求那两条命令确实存在。
for pat, label in ((r'\bfastboot\s+erase\s+"?dtbo_\$\{?TARGET\}?', "erase dtbo_$TARGET"),
                   (r'\bfastboot\s+flash\s+"?boot_\$\{?TARGET\}?', "flash boot_$TARGET")):
    found = [l.strip() for l in cmds if re.search(pat, l)]
    check(bool(found), "确实执行 " + label,
          found[0] if found else "找不到这条命令（被换成 echo 了？）")

# 8. 不许有把槽位标成 successful 的动作（spec 硬性约束），也不许有那几个
#    会一次写掉整台设备的 fastboot 子命令。
danger = []
for pat, why in (
    (r"\bbootctl\b", "bootctl 会把槽位标成 successful"),
    (r"set[-_]slot[-_]successful", "直接标记槽位 successful"),
    (r"\bfastboot\b[^\n]*\bflashall\b", "flashall 会写所有分区"),
    (r"\bfastboot\b[^\n]*\bupdate\b", "update 会按 zip 写所有分区"),
    (r"\bfastboot\b[^\n]*\s-w(\s|$)", "-w 会擦除用户数据"),
    (r"\bfastboot\b[^\n]*\bwipe-super\b", "wipe-super 会重建 super"),
    (r"\bfastboot\b[^\n]*\b(delete|create)-logical-partition\b", "改动逻辑分区表"),
    (r"\bfastboot\b[^\n]*\b(oem|flashing)\b", "oem/flashing 子命令不可预测"),
):
    if re.search(pat, cmds_s):
        danger.append(why)
check(not danger, "没有标记 successful、也没有整机写操作",
      "以上都不出现" if not danger else "; ".join(danger))

# 9. 救砖说明必须给出 --set-active=b（这条反过来，要求文本里**有**）。
check("--set-active=b" in src, "说明了退路",
      "脚本里写明了 fastboot --set-active=b")

# 10. 不许把「等 bootloader 自己回退」当成退路。它确实会回退 —— 2026-10-23
#     实测：活动槽 b 的启动连续失败后，bootloader 自己把 b 标成
#     slot-unbootable 并把活动槽切到 a，全程没有任何人写过分区。但那条路
#     会花掉启动尝试、落到另一个槽里的旧系统上（实测那边是起不来的旧
#     Android：splash、黑屏、循环），而且会把被放弃的那个槽标成不可启动，
#     最后还是得手动 --set-active=b 才能清掉。所以说明必须指向手动那条。
wait_claim = re.search(r"(等待自动回退|等它自己(退|回)|干等|wait for the bootloader to fall back)", src)
check(not wait_claim, "没有把等自动回退当退路",
      "没有「等自动回退」之类的说法" if not wait_claim
      else "出现了 %r —— 那条路会花掉启动尝试并弄坏好槽的标记" % wait_claim.group(0))

# 10b. 反过来，也不许宣称这台机器没有自动回退。那是 2026-10-23 之前写在
#      这里的结论，依据是 UART 日志里每次启动都打 "A/B retry count NOT
#      decremented" 以及 retry 计数停在 7。实测把它证伪了：同一次
#      getvar 读到 slot-retry-count a:7 对 b:4，b 这边确实在记账。
#      留这条断言，是因为那句话会让操作者以为失败的槽不会被 bootloader
#      动过 —— 而它会，连好槽的标记一起动。
denial = re.search(r"(自动回退并不存在|不会自己退回|不做 A/B 重试记账|retry 计数器不递减"
                   r"|counter is inert|does not do that on this phone)", src)
check(not denial, "没有宣称自动回退不存在",
      "没有这类说法" if not denial
      else "出现了 %r —— 2026-10-23 实测证伪" % denial.group(0))

sys.exit(min(fails, 100))
PY
fails=$((fails + $?))

echo
echo "--- B. boot-debug.img 的结构 ---"

if [[ ! -s "$IMG" ]]; then
  check 0 "镜像存在" "没有 $IMG —— 先跑 ./make-steamos-alioth.sh --kernel-only"
else
  size=$(stat -c %s "$IMG")
  check "$(( size <= BOOT_PART_SIZE ? 1 : 0 ))" "镜像装得下" \
    "$size 字节 / 分区 $BOOT_PART_SIZE 字节"

  python3 - "$IMG" "${KOUT}/dtbs/sm8250-xiaomi-alioth.dtb" <<'PY'
import struct, sys, zlib

img, want_dtb = sys.argv[1], sys.argv[2]
blob = open(img, "rb").read()
magic, ksize, kaddr, rsize, raddr, ssize, saddr, taddr, page, hdrv = \
    struct.unpack_from("<8s10I", blob, 0)[:10]
cmdline = struct.unpack_from("<512s", blob, 8 + 10 * 4 + 16)[0].split(b"\0")[0].decode()

fails = 0
def check(ok, label, detail):
    global fails
    print(("PASS  " if ok else "FAIL  ") + label + " — " + detail)
    if not ok:
        fails += 1

check(magic == b"ANDROID!", "boot magic", repr(magic))
check(hdrv == 0, "header_version", "%d（期望 0 —— pmaports 的 deviceinfo 没有设"
      " bootimg_header_version，而那个镜像在这台机器上起得来）" % hdrv)
check(page == 4096, "page_size", "%d（期望 4096 = deviceinfo 的 flash_pagesize；"
      "上游默认的 2048 是 ROCKNIX ABL 的值）" % page)
check(kaddr == 0x00008000, "kernel_addr", "0x%x（期望 0x8000）" % kaddr)
check(raddr == 0x01000000, "ramdisk_addr", "0x%x（期望 0x1000000）" % raddr)
check(taddr == 0x00000100, "tags_addr", "0x%x（期望 0x100）" % taddr)
# second_size 是 0，bootloader 不会在这个地址加载任何东西。断言它只是因为
# 上面四个地址的全部意义就是「不偏离这台机器被证明过的那一组」，而
# mkbootimg-v0.py 自己的默认值是 ROCKNIX 的基址。
check(ssize == 0, "second_size", "%d（期望 0）" % ssize)
check(saddr == 0x00F00000, "second_addr",
      "0x%x（期望 0x00F00000 = deviceinfo 的 offset_base+offset_second）" % saddr)

# cmdline。每一条缺失都是一个「症状离原因很远」的 bug：
for arg, why in (
    ("steamos.usbshell=1", "initramfs/init 里启动 USB gadget shell 的唯一开关"),
    ("steamos.root=PARTLABEL=userdata", "ABL 会追加自己的参数，root= 可能被压掉"),
    ("console=tty0", "CMDLINE_QUIET=0 才有，面板控制台靠它"),
    ("initcall_blacklist=simpledrm_platform_driver_init",
     "simpledrm 占掉 DRM minor 0 的话 msm 落在 dri/1，而镜像自带的 MangoHud "
     "把 perf_now 的路径写死成 dri/0 —— 面板上 GPU 占用率恒为 0"),
):
    check(arg in cmdline.split(), "cmdline " + arg, why)
for arg, why in (("quiet", "会压掉面板上的内核日志"), ("loglevel=0", "同上"),
                 ("fbcon=rotate:1", "面板驱动已向 DRM 报告 rotation=270，再叠一层是复合旋转")):
    check(arg not in cmdline.split(), "cmdline 无 " + arg, why)
check(len(cmdline) < 512, "cmdline 长度", "%d 字符（上限 512）" % len(cmdline))

# payload = gzip(Image) ++ 追加的 DTB。断言只追加了一个 DTB，且就是 alioth 的。
payload = blob[page:page + ksize]
d = zlib.decompressobj(31)   # 31 = gzip 包装
d.decompress(payload)
tail = d.unused_data
check(tail.startswith(b"\xd0\x0d\xfe\xed"), "追加了 DTB",
      "gzip 流之后是 %s" % tail[:4].hex())
total = 0
n = 0
while total + 8 <= len(tail) and tail[total:total + 4] == b"\xd0\x0d\xfe\xed":
    # totalsize 来自被检查的数据本身，0 会让这个循环永远不前进。
    sz = struct.unpack_from(">I", tail, total + 4)[0]
    if sz == 0:
        check(False, "DTB totalsize", "第 %d 个 DTB 的 totalsize 是 0" % (n + 1))
        break
    total += sz
    n += 1
check(n == 1, "只有一个 DTB",
      "%d 个（只给这台机器的设备树，不把另外十块板子的也塞进去）" % n)
check(total == len(tail), "DTB 之后没有多余字节",
      "载荷尾部 %d 字节全部属于 DTB" % total if total == len(tail)
      else "DTB 占 %d 字节，尾部还剩 %d 字节未被解释" % (total, len(tail) - total))
try:
    check(tail[:total] == open(want_dtb, "rb").read(), "DTB 是 alioth 的",
          "和 %s 逐字节相同" % want_dtb.split("/")[-1])
except OSError as e:
    check(False, "DTB 是 alioth 的", "读不到 %s: %s" % (want_dtb, e))

sys.exit(min(fails, 100))
PY
  fails=$((fails + $?))
fi

echo
echo "--- C. 内核配置 ---"
C="$(ls "${KOUT}"/config-* 2>/dev/null | head -n1)"
if [[ ! -s "${C:-}" ]]; then
  check 0 "config 存在" "在 $KOUT 里找不到 config-*"
else
  # 阶段 1 的 initramfs 没有 /lib/modules 也没有 modprobe：这几项 =m 等于没有。
  for sym in DRM_PANEL_SAMSUNG_AMS667XX01 TOUCHSCREEN_FT8756 SPI_QCOM_GENI \
             DRM_SIMPLEDRM USB_CONFIGFS_ACM U_SERIAL_CONSOLE USB_CONFIGFS_NCM; do
    got="$(grep -E "^(CONFIG_${sym}=|# CONFIG_${sym} is)" "$C" || echo '(未出现)')"
    check "$([[ "$got" == "CONFIG_${sym}=y" ]] && echo 1 || echo 0)" "$sym" "$got"
  done
  # perf_now 靠 debugfs 暴露，Game Mode 的叠加面板只认那一个文件。
  got="$(grep -E '^CONFIG_DEBUG_FS=' "$C" || echo '(未出现)')"
  check "$([[ "$got" == "CONFIG_DEBUG_FS=y" ]] && echo 1 || echo 0)" \
    "DEBUG_FS（perf_now 前提）" "$got"
  # 4K 页是 FEX 的硬性前提（spec）。不成立则整个项目终止，所以每次都断言。
  got="$(grep -E '^CONFIG_ARM64_4K_PAGES=' "$C" || echo '(未出现)')"
  check "$([[ "$got" == "CONFIG_ARM64_4K_PAGES=y" ]] && echo 1 || echo 0)" \
    "4K 页（FEX 前提）" "$got"
fi

# GPU 占用率只有这一条通路：MangoHud 的 msm 后端读 debugfs 里的 perf_now，
# 别的什么都不读。补丁掉了的话表现是「叠加面板里 GPU 恒为 0」，和驱动根本
# 没起来长得一模一样 —— 所以在镜像里直接查符号。
M="$(ls "${KOUT}"/System.map-* 2>/dev/null | head -n1)"
if [[ ! -s "${M:-}" ]]; then
  check 0 "System.map 存在" "在 $KOUT 里找不到 System.map-*"
else
  got="$(grep -cE ' msm_devfreq_get_load$' "$M" || true)"
  check "$([[ "$got" == 1 ]] && echo 1 || echo 0)" \
    "msm_devfreq_get_load（GPU 占用率）" "符号出现 ${got} 次"
fi

echo
if (( fails )); then echo "${fails} 条断言失败"; exit 1; fi
echo "全部断言通过"
