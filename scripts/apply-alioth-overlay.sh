#!/usr/bin/env bash
# 把 alioth-overlay/ 装进一棵已经由 apply-overlays.sh 处理过的 rootfs。
#
# 为什么是独立脚本而不是 apply-overlays.sh 里的一个 DEVICE=alioth 分支：
# 那个脚本在第 32-37 行就要求真 rootfs、编译好的内核（boot/KERNEL + modules）
# 和编译好的 gamescope，远早于第 875 行的 overlay 块，所以它没法对一棵假目录树
# 跑起来 —— 也就没法测。独立脚本对上游文件零修改（spec §4 要求把每次 rebase
# 的冲突面压到最小），而且可以单独测。
#
# 只做加法，不删 sm8250-overlay 的任何东西。原因是实地查过的：
#   - 掌机的 5 个 InputPlumber profile 全都 gate 在各自的 DT model 上
#     （Retroid Pocket 5 / AYN Thor Lite / MANGMI … / AYANEO …），对
#     "Xiaomi Poco F3" 一个都匹配不上，是惰性的，删不删都一样；
#   - 而 etc/systemd/user/steamos-powerbuttond.service 恰恰是**我们要用的**
#     —— alioth-overlay 的 99-zz-alioth-powerbuttond.conf 只写了 Wants=，
#     把它当掌机文件删掉，Wants= 就悬空了，systemd 对此一声不吭，电源键
#     静默失灵。所以「两个 overlay 互斥」只能按 profile 粒度理解，不能按
#     目录粒度执行。
#
# 用法: scripts/apply-alioth-overlay.sh <rootfs-dir>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OVL="${ROOT}/alioth-overlay"
R="${1:-}"

log() { echo "apply-alioth-overlay: $*" >&2; }
die() { echo "apply-alioth-overlay: $*" >&2; exit 1; }

[[ -n "$R" ]] || die "用法: $0 <rootfs-dir>"
[[ -d "$R" ]] || die "rootfs 目录不存在: $R"
[[ -d "$OVL" ]] || die "找不到 $OVL"

# etc/ 与 usr/ 下的文件就是全部；README.md 刻意留在仓库里不入镜像。
mapfile -t files < <(cd "$OVL" && find etc usr -type f | sort)
[[ ${#files[@]} -gt 0 ]] || die "$OVL 下 etc/ 与 usr/ 里一个文件都没有"

# 原样保留权限位，不要一律 0644：alioth-firstboot 是要被 systemd 执行的，
# 装成 0644 的话 ExecStart 会以 203/EXEC 失败，而那条日志离「首次开机没
# 扩展根文件系统」这个症状很远。
log "装入 ${#files[@]} 个文件 → $R"
for f in "${files[@]}"; do
  install -D -m "$(stat -c %a "$OVL/$f")" "$OVL/$f" "$R/$f"
done

# 符号链接要原样复制（install 会跟过去把目标文件复制一份）。unit 的
# enable 链接就是这么来的 —— 放在 usr/lib 下而不是 /etc 下，因为
# SteamOS 的 /etc 是 overlayfs 且挂载很晚，而这个 unit 要在 sysinit 之前跑。
mapfile -t links < <(cd "$OVL" && find etc usr -type l | sort)
for f in "${links[@]}"; do
  mkdir -p "$(dirname "$R/$f")"
  cp -a --no-target-directory "$OVL/$f" "$R/$f"
done
[[ ${#links[@]} -gt 0 ]] && log "另有 ${#links[@]} 个符号链接"

# /etc 在 SteamOS 上是 overlayfs，而且挂得很晚：只写下层（镜像里的 /etc）
# 开机时根本看不到。upper 是 /var/lib/overlays/etc/upper，同一份再放一次。
upper="$R/var/lib/overlays/etc/upper"
n=0
for f in "${files[@]}"; do
  [[ "$f" == etc/* ]] || continue
  install -D -m0644 "$OVL/$f" "$upper/${f#etc/}"
  n=$((n + 1))
done
log "其中 $n 个 etc/ 文件已镜像到 var/lib/overlays/etc/upper"

# 时钟下限。alioth 的 PMIC RTC 首次开机读出垃圾值（真机实测 2091-01-25），
# systemd 判定「比内置 epoch 超前 15 年以上」就把系统时间拍回它编译时的内置
# epoch —— 2026-02-23，比 rootfs 的构建日期早八个月。后果不是「时间不对」：
# PAM 立刻报 "account steamos has password changed in future"，HTTPS 证书全部
# 「尚未生效」，Steam 登不上。
#
# systemd 优先采用 /usr/lib/clock-epoch 的 mtime 作为 epoch，所以放一个
# mtime = 构建时刻的空文件，开机时间就至少是构建日期。联网后 NTP 校准，
# 内核的 11 分钟模式再把 RTC 写回去（这颗 RTC 实测可写，hwclock -w 成功）。
install -D -m0644 /dev/null "$R/usr/lib/clock-epoch"
log "已装 usr/lib/clock-epoch（mtime = 构建时刻）"

# 99-zz-alioth-powerbuttond.conf 的 Wants= 必须指得到东西。systemd 忽略悬空的
# Wants=，不报错、不记日志，故障表现为「电源键在 Game Mode 里没反应」。
pbd="$R/etc/systemd/user/steamos-powerbuttond.service"
if [[ ! -f "$pbd" ]]; then
  die "缺 etc/systemd/user/steamos-powerbuttond.service —— 我们的 Wants= 会悬空，
     电源键将静默失灵。它由 sm8250-overlay 提供，请确认上游的 apply-overlays.sh 是以
     SOC=sm8250 跑的。"
elif grep -qE '^[[:space:]]*Requisite=.*steamvr' "$pbd"; then
  die "etc/systemd/user/steamos-powerbuttond.service 是 Frame 自带版
     （Requisite=steamvr.service，本镜像里 steamvr 被 mask），不会启动。
     应由 sm8250-overlay 的替代版覆盖它。"
fi

log "完成"
