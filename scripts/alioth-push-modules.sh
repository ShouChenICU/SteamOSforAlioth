#!/usr/bin/env bash
# 把构建出来的 /lib/modules/<版本> 送上设备，让设备自己装。
#
# 用法:
#   scripts/alioth-push-modules.sh                   # 送 KERNEL_OUT 里的那一棵
#   scripts/alioth-push-modules.sh <modules-dir>     # <dir> 本身是 <版本> 目录
#
# 为什么它必须和 alioth-selfflash-boot.sh 成对存在：boot 镜像里只有内核和
# 设备树，模块在 userdata 上。这个移植里一半的东西是 `=m`，而只换 boot 的
# 后果是「改动在构建机的模块里，设备上加载的还是旧的那份，版本字符串一样
# 所以什么都不报错」。2026-10-24 就这么丢掉了一轮。
#
# 设备侧的边界在 alioth-install-modules 里：归档每个成员的路径、类型、链接
# 目标都先验过，只往 /usr/lib/modules/<版本> 下面写。
set -uo pipefail

PORT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSH="${ALIOTH_SSH:-${PORT_ROOT}/scripts/alioth-ssh.sh}"
INSTALLER=/usr/lib/steamos-arm/alioth-install-modules

die() { echo "alioth-push-modules: $*" >&2; exit 1; }

SRC="${1:-}"
if [[ -z "$SRC" ]]; then
  KOUT="$(readlink -f "${KERNEL_OUT:-${PORT_ROOT}/work/kernel-sm8250/output/current}" 2>/dev/null || true)"
  [[ -n "$KOUT" && -d "$KOUT/modules" ]] \
    || die "找不到 $KOUT/modules —— 先跑 ./build-alioth-kernel.sh，或把 <版本> 目录传进来"
  # modules/ 下面恰好一个版本目录。多于一个就说明有残留，而猜错一个的后果
  # 是把别的版本的模块装上去。
  mapfile -t vers < <(find "$KOUT/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
  [[ "${#vers[@]}" -eq 1 ]] \
    || die "$KOUT/modules 下有 ${#vers[@]} 个版本目录（${vers[*]}）—— 明确指定一个"
  SRC="$KOUT/modules/${vers[0]}"
fi

SRC="${SRC%/}"
[[ -d "$SRC" ]] || die "$SRC 不是目录"
KVER="$(basename "$SRC")"
[[ "$KVER" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || die "目录名 '$KVER' 不像内核版本号"
[[ -n "$(find "$SRC" -name '*.ko*' -print -quit)" ]] || die "$SRC 里一个 .ko 都没有"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TARBALL="$TMP/modules.tar.gz"
# -C 到父目录、把 <版本> 整个打进去：归档的顶层就是版本目录，设备侧靠这
# 一点确定装到哪里。--owner/--group 0 省得设备侧再 chown（它也会 chown，
# 两头都做是因为归档可能不是这个脚本打的）。
tar czf "$TARBALL" -C "$(dirname "$SRC")" --owner=0 --group=0 "$KVER"
size=$(stat -c %s "$TARBALL")
want="$(sha256sum "$TARBALL" | cut -d' ' -f1)"
echo "==> $SRC -> $((size / 1024 / 1024)) MiB 归档（版本 $KVER）"

"$SSH" 'cat > /tmp/alioth-modules.tar.gz' < "$TARBALL" || die "传输失败"
got="$("$SSH" 'sha256sum /tmp/alioth-modules.tar.gz' | cut -d' ' -f1)"
[[ "$got" == "$want" ]] \
  || die "传过去的不一样：本地 ${want:0:12}，设备上 ${got:0:12}"
echo "==> 传输校验通过（sha256 ${want:0:12}）"

"$SSH" "sudo -n $INSTALLER /tmp/alioth-modules.tar.gz --yes" \
  || die "设备侧安装失败 —— 上面的输出说了原因。"
"$SSH" 'rm -f /tmp/alioth-modules.tar.gz' >/dev/null 2>&1

echo "装好了。重启后生效。"
