#!/usr/bin/env bash
# 从 alioth 自己的 Android 分区里取出两份**机内签名**的固件：
#
#   qcom/sm8250/a650_zap.mbn   Adreno 650 的 zap shader
#   qcom/sm8250/adsp.mbn       ADSP（音频）
#
# 为什么必须是机内这两份，而不能用 linux-firmware 的同名文件：
# 这些镜像走 Qualcomm 的 PAS 加载路径，由 TrustZone 验签。alioth 的 TZ 拒收
# linux-firmware 里所有通用签名的 PAS 镜像 —— qcom_scm_pas_init_image 返
# -EINVAL，内核只说 "error -22 initializing firmware"。后果和原因离得极远：
#   zap 失败 -> GPU hw init failed -110 -> Turnip "could not get GPU ID"
#            -> gamescope "failed to find physical device" -> sddm 死循环
#            -> 用户看到的是一块**黑屏**
#   adsp 失败 -> q6afe 不上线 -> PipeWire 只有 Dummy Output，一点声音没有
# 两份文件和 linux-firmware 的同名文件连大小都一样（zap 两边都是 13964
# 字节），只有签名不同，所以光看文件名、看大小、看「文件在不在」都发现不了。
# scripts/assert-alioth-firmware.sh 的第 2、3 条就是专门钉这件事的。
#
# **不可再分发**：这是小米签的固件，不要提交进 git，不要上传。和
# scripts/extract-nx669j-firmware.sh 一样 —— bring your own。
#
# 用法:
#   scripts/extract-alioth-firmware.sh <modem-dir> <vendor-dir> [OUT]
#
#   <modem-dir>   modem_a 的内容，里面要有 image/adsp.mdt 和 image/adsp.bNN
#   <vendor-dir>  super 里 vendor_a 的内容，要有 firmware/a650_zap.mdt + .bNN
#   OUT           默认 ${STEAMOS_WORK:-<repo>/work}/alioth-firmware
#
# 怎么拿到这两个目录（要 root，而正式系统里 steamos 用户没有免密 sudo，
# 所以用 initramfs 的 root shell：scripts/alioth-shell.sh，它在黑屏时也在）：
#
#   # modem_a 是 vfat，直接挂
#   mkdir -p /mnt/modem && mount -o ro /dev/disk/by-partlabel/modem_a /mnt/modem
#
#   # vendor_a 住在 super 这个 Android 动态分区里，是一段线性 extent。
#   # 设备内核没编 CONFIG_BLK_DEV_DM，所以用 losetup 的 -o/--sizelimit 开一个
#   # **只读**回环，而不是 dmsetup。偏移和长度由 liblp 元数据给出 ——
#   # geometry magic 在 super 的 4096 偏移处，header magic 在 12288 处。
#   #（读 super 是只读操作；写 super 在本项目里是禁止的 —— 格一下 userdata
#   # 就能复活 Android，前提是 super 没被动过。）
#   losetup -r -o <off> --sizelimit <size> /dev/loop7 /dev/disk/by-partlabel/super
#   mkdir -p /mnt/vendor && mount -o ro /dev/loop7 /mnt/vendor
#
# 本脚本自己不挂任何东西、不需要 root：给它两个能读的目录就行。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
M="${1:-}"
V="${2:-}"
OUT="${3:-${STEAMOS_WORK:-${ROOT}/work}/alioth-firmware}"

log() { printf '[alioth-fw] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

[[ -n "$M" && -n "$V" ]] || die "用法: $0 <modem-dir> <vendor-dir> [OUT]"
[[ -f "$M/image/adsp.mdt" ]] \
  || die "$M 里没有 image/adsp.mdt —— 这是 modem_a 的内容吗？"
[[ -f "$V/firmware/a650_zap.mdt" ]] \
  || die "$V 里没有 firmware/a650_zap.mdt —— 这是 super 里 vendor_a 的内容吗？"

command -v python3 >/dev/null || die "没有 python3"

# .mdt + .bNN -> 一个 .mbn。和 linux-msm/pil-squasher 等价，与
# scripts/extract-nx669j-firmware.sh 里的 squash() 同一套算法：
# .mdt 带的是 ELF 头 + program header 表（段内容被剥掉），第 i 个段的内容在
# .bNN 里，NN = 段序号。把每个段按 p_offset 写回去，再把头原样抄回前面。
squash() {
  python3 -I - "$1" "$2" <<'PY'
import struct, sys
from pathlib import Path
mdt, out = Path(sys.argv[1]), Path(sys.argv[2])
d = mdt.read_bytes()
if d[:4] != b"\x7fELF":
    sys.exit(f"{mdt}: not ELF")
if d[4] == 1:
    phoff, = struct.unpack_from("<I", d, 0x1c)
    phentsize, phnum = struct.unpack_from("<HH", d, 0x2a)
    def ph(i):
        _, off, _, _, filesz, _, _, _ = struct.unpack_from("<8I", d, phoff + i * phentsize)
        return off, filesz
else:
    phoff, = struct.unpack_from("<Q", d, 0x20)
    phentsize, phnum = struct.unpack_from("<HH", d, 0x36)
    def ph(i):
        _, _, off, _, _, filesz, _, _ = struct.unpack_from("<IIQQQQQQ", d, phoff + i * phentsize)
        return off, filesz
img = bytearray()
for i in range(phnum):
    off, size = ph(i)
    if not size:
        continue
    seg = mdt.with_suffix(f".b{i:02d}")
    data = seg.read_bytes() if seg.exists() else d[off:off + size]
    if len(img) < off + len(data):
        img.extend(b"\0" * (off + len(data) - len(img)))
    img[off:off + len(data)] = data
hdr = phoff + phnum * phentsize
img[:hdr] = d[:hdr]
out.write_bytes(img)
print(f"{out.name}: {len(img)} bytes from {phnum} phdrs", file=sys.stderr)
PY
}

q="$OUT/qcom/sm8250"
rm -rf "$OUT"
mkdir -p "$q"

log "adsp  <- $M/image/adsp.mdt"
squash "$M/image/adsp.mdt" "$q/adsp.mbn"

log "a650_zap <- $V/firmware/a650_zap.mdt"
squash "$V/firmware/a650_zap.mdt" "$q/a650_zap.mbn"

# vendor 分区里常常**也**放着一份已经 squash 好的 a650_zap.elf。它存在的时候
# 就是一个免费的交叉校验：我们算出来的应该和它逐字节相同。不相同说明 squash
# 的段拼接错了，而那种错误在真机上只会表现成「TZ 拒收」，和签名不对一模一样。
if [[ -f "$V/firmware/a650_zap.elf" ]]; then
  if cmp -s "$q/a650_zap.mbn" "$V/firmware/a650_zap.elf"; then
    log "交叉校验: 和 vendor 里的 a650_zap.elf 逐字节相同"
  else
    die "squash 出来的 a650_zap.mbn 和 vendor 里的 a650_zap.elf 不同 —— 段拼接错了"
  fi
fi

log "完成: $OUT"
log "下一步: ALIOTH_FW_DIR=$OUT ./make-steamos-alioth.sh --install"
log "注意: 这是小米签的固件，不可再分发 —— 不要提交进 git。"
