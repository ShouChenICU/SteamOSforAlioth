#!/usr/bin/env bash
# 取回 Valve Frame 的官方 aarch64 rootfs 并解包成一棵目录树。
#
# 为什么是新文件而不是复用 make-steamos-sm8650.sh：那个脚本里的
# ensure_official_rootfs() 做的正是这件事，但它嵌在一个继续往下造 SD 卡
# 三分区镜像（p1 BOOT / p2 root / p3 home）的流程里，没有「取完就停」的
# 开关，而 alioth 走的是手机模型 —— 单个 ext4 刷进 userdata。把那个函数
# 抽出来会改动上游文件、扩大每次 merge 的冲突面（spec §4）。
#
# 四步，与上游同一条流水线、同一组 URL：
#   1. curl 取 RAUC bundle（.raucb，其实是个 squashfs）
#   2. unsquashfs 解出 rootfs.img.caibx 与 manifest.raucm
#   3. scripts/extract_rootfs.py 按 caibx 从 casync chunk store 重组 rootfs.img
#      （sha256 取自 manifest，由该脚本校验）
#   4. loop 挂载后 rsync 成目录树（-aHAX --numeric-ids，保 xattr 与属主）
#
# 每一步都幂等：bundle 在就不重下，rootfs.img 有 .ok 标记就不重组，
# 目标树里有 usr/bin/bash 就直接返回。重跑这个脚本不会重新下载几 GB。
#
# 用法: scripts/fetch-steamos-rootfs.sh [输出目录]
#   默认输出 ${STEAMOS_ROOTFS:-${STEAMOS_WORK:-<repo>/work}/rootfs}
# 版本由 STEAMOS_BUILD / STEAMOS_VERSION 覆盖（默认与上游一致）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="${ROOT}/scripts"
WORKDIR="${STEAMOS_WORK:-${ROOT}/work}"
R="${1:-${STEAMOS_ROOTFS:-${WORKDIR}/rootfs}}"

# 与 make-steamos-sm8650.sh 同一组默认值；versions.env 若存在则优先。
[[ -f "${ROOT}/versions.env" ]] && source "${ROOT}/versions.env"
STEAMOS_BUILD="${STEAMOS_BUILD:-20261002.6232440}"
STEAMOS_BUNDLE="deckard-${STEAMOS_BUILD}-${STEAMOS_VERSION:-0.5.3}"
STEAMOS_URL="https://steamdeck-images.steamos.cloud/vr/${STEAMOS_BUILD}"

log() { echo "fetch-steamos-rootfs: $*" >&2; }
die() { echo "fetch-steamos-rootfs: $*" >&2; exit 1; }

for c in curl unsquashfs rsync python3; do
  command -v "$c" >/dev/null || die "缺少 $c"
done

if [[ -x "${R}/usr/bin/bash" ]]; then
  log "rootfs 已解包在 ${R}，不做任何事"
  exit 0
fi

dl="${WORKDIR}/steamos-${STEAMOS_BUILD}"
img="${dl}/rootfs.img"
mkdir -p "${dl}"

if [[ ! -s "${dl}/bundle/rootfs.img.caibx" ]]; then
  log "取 RAUC bundle ${STEAMOS_BUNDLE}"
  curl -fL --retry 3 -o "${dl}/${STEAMOS_BUNDLE}.raucb" \
    "${STEAMOS_URL}/${STEAMOS_BUNDLE}.raucb"
  rm -rf "${dl}/bundle"
  unsquashfs -q -d "${dl}/bundle" "${dl}/${STEAMOS_BUNDLE}.raucb"
fi

sha="$(sed -n '/^\[image.rootfs\]/,/^\[/{s/^sha256=//p}' "${dl}/bundle/manifest.raucm")"
[[ -n "$sha" ]] || die "manifest.raucm 里没有 [image.rootfs] 的 sha256"

if [[ ! -s "${img}" || ! -f "${img}.ok" ]]; then
  log "按 casync chunk 重组 rootfs.img（sha256 ${sha}）"
  python3 "${SCRIPTS}/extract_rootfs.py" \
    --caibx "${dl}/bundle/rootfs.img.caibx" --output "${img}" \
    --store "${STEAMOS_URL}/${STEAMOS_BUNDLE}.castr" \
    --store "https://steamdeck-images.steamos.cloud/vr/chunks.castr" \
    --expected-sha256 "${sha}"
  touch "${img}.ok"
fi

log "解包 rootfs.img → ${R}"
mnt="${WORKDIR}/.rootfs-ro"
mkdir -p "${mnt}" "${R}"
# 已挂着就先卸，否则重跑会 rsync 出一棵空树。
mountpoint -q "${mnt}" && sudo umount "${mnt}"
sudo mount -o loop,ro "${img}" "${mnt}"
trap 'sudo umount "${mnt}" 2>/dev/null || true' EXIT
sudo rsync -aHAX --filter="-x btrfs.*" --numeric-ids "${mnt}/" "${R}/"
sudo umount "${mnt}"
trap - EXIT

[[ -x "${R}/usr/bin/bash" ]] || die "解包后的 rootfs 里没有 /usr/bin/bash"
log "完成: ${R}"
