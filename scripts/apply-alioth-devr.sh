#!/usr/bin/env bash
# 把 Valve Frame 镜像「去 VR 化」这一层装进一棵 rootfs。
#
# Frame 是 VR 头显。它的 gamescope-session.target 的 Description 就是
# "Gamescope VR Session"，gamescope 默认以 --backend openvr
# --vr-session-manager 启动，SteamVR 不在就立刻退出。阶段 2 原先的裁决是
# 「--install 不调 scripts/apply-overlays.sh」（那个脚本第 37 行要求有编译
# 好的 gamescope），但那条裁决连带把整层去 VR 化也漏掉了 —— Task 8 真机
# 实测的表现是全程黑屏。
#
# 为什么是独立脚本：和 apply-alioth-overlay.sh 同一个理由 ——
# apply-overlays.sh 在第 32-37 行就要求真 rootfs、编译好的内核和编译好的
# gamescope，没法对一棵假目录树跑，也就没法测。这里只取它第 150-300 行
# 里 alioth 真正需要的那一小部分，对上游文件零修改。
#
# 用法: scripts/apply-alioth-devr.sh <rootfs-dir>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOVL="${ROOT}/steamos-overlay"
R="${1:-}"

log() { echo "apply-alioth-devr: $*" >&2; }
die() { echo "apply-alioth-devr: $*" >&2; exit 1; }

[[ -n "$R" ]] || die "用法: $0 <rootfs-dir>"
[[ -d "$R" ]] || die "rootfs 目录不存在: $R"
[[ -d "$SOVL" ]] || die "找不到 $SOVL"

STOCK="$R/var/lib/steamos-arm-stock"

# 被替换的 Frame 原件留一份，和上游 apply-overlays.sh 的 backup() 同一个
# 位置。只在备份还不存在时备份 —— 否则重跑会把我们自己的版本当成原件存
# 进去，真正的原版就永远丢了。
backup() { # $1=rootfs 里的目标文件 $2=即将装上去的 overlay 源文件
  local src="$1" new="$2" dst="$STOCK/${1#"$R/"}"
  [[ -f "$src" ]] || return 0          # 镜像里本来就没有这个文件
  [[ -e "$dst" ]] && return 0          # 已经备份过
  # 已经装过一遍了：现场这份就是我们自己的版本，不是原件。不加这条，第二次
  # 运行会把我们的版本当成 Frame 原版存进备份，真正的原版就永远丢了。
  cmp -s "$src" "$new" && return 0
  install -D -m0644 "$src" "$dst"
}

# 1. 会话那一套。gamescope-session 是去 VR 化的核心：它把 gamescope 从
#    openvr 后端换成 drm，钉住 DSI-1、输出尺寸与旋转。其余几个是它直接
#    调用或 source 的。权限位原样保留 —— 这几个都是被 ExecStart 或别的
#    脚本直接执行的，装成 0644 会以 203/EXEC 失败。
files=(
  usr/lib/steamos/gamescope-session
  usr/lib/steamos/gamescope-onready
  usr/lib/steamos/panel-modes
  usr/lib/steamos/sm8550-fixpad
  usr/bin/start-gamescope-session
  usr/lib/systemd/user/gamescope-session.service.d/99-odin.conf
  usr/lib/systemd/user/gamescope-session.target.d/99-odin.conf
  usr/lib/systemd/user/steam.service.d/99-odin.conf
  usr/lib/systemd/user/steam.service.d/60-gamescope-env.conf
)
for f in "${files[@]}"; do
  [[ -f "$SOVL/$f" ]] || die "缺 $SOVL/$f"
done
log "装入 ${#files[@]} 个去 VR 化文件 → $R"
for f in "${files[@]}"; do
  backup "$R/$f" "$SOVL/$f"
  install -D -m "$(stat -c %a "$SOVL/$f")" "$SOVL/$f" "$R/$f"
done

# 2. mask。Wants= 是叠加的，而 Frame 的 .wants/ 软链目录不受 drop-in 里
#    那条空 Wants= 影响 —— 唯一可靠的办法是把 unit 本身指向 /dev/null。
#
#    home.mount 是 alioth 独有的一条，上游不 mask（它的 SD 卡布局真有一个
#    home 分区）。Frame 的 home.mount 指向
#    /dev/disk/by-partsets/shared/home，alioth 的 userdata 上只有一个 ext4，
#    没有这个设备 → 90 秒设备超时 → "Dependency failed for /home" →
#    **每一个** session-N.scope 都以 'dependency' 失败，连串口登录也一样，
#    于是没有 seat、没有 DRM master，屏幕不亮（2026-10-23 真机实测）。
#
#    adbd / adbd-post：alioth 上没有 adbd，但 adbd-post 仍会以
#    `while [ $(cat g1/functions/ffs.adb/ready) != 1 ]; do sleep 0.1; done`
#    永远停在 activating。真机上实测它已这样转了 8381 秒 —— 10 Hz 轮询让
#    SoC 出不了深度 idle，待机掉电。上游注释里写的就是这件事。
mask_user=(
  steamvr.service steamvr-logs.service steamvr-proxmicmute.service
  steamvr-v4l2cam.service steamvr-nested-desktop.service
)
mask_sys=(
  steamvr-program-ble.service steamvr-v4l2loopback.service
  steamvr-set-kernel-thread-priorities.service
  deckard-audio-setup.service deckard-fan-control.service
  deckard-fpga.service deckard-led-control.service
  deckard-typec-logger.service deckard-charger.service
  deckard-power-monitor.service deckard-fpga-resume.service
  deckard-boot-images.service set-wifi-mac-address.service
  steamos-boot.service efi.mount esp.mount home.mount
  systemd-repart.service adbd.service adbd-post.service
)

# 刻意不 mask（与上游不同，理由写在 assert-alioth-devr.sh 第 5 条）：
#   usb-gadget.service / usb-gadget.target / usb-ncm-gadget@.service
#     —— alioth 没有 UART 排针也没有 ADB，USB gadget 的 ACM 口和 NCM 网口
#        是唯一的观测通道。
#   usb-ncm-dnsmasq@.service
#     —— 它自己会失败（dnsmasq 起不来），但在失败**之前**已经执行了
#        `ip addr add 10.86.200.233/29 dev usb0`。mask 掉它，设备就没地址，
#        宿主端也就连不上。宿主端静态占 10.86.200.234/29 即可，不需要 DHCP。
#   iwd.service
#     —— 2026-10-23 真机实测：WiFi 在 Frame 原版的 NetworkManager + iwd 下
#        正常扫描与连接。上游换成 wpa_supplicant 是它自己板子的需要。

upper="$R/var/lib/overlays/etc/upper"
mask_one() { # $1=user|system $2=unit
  local scope="$1" u="$2"
  install -d "$R/etc/systemd/$scope" "$upper/systemd/$scope"
  ln -sfn /dev/null "$R/etc/systemd/$scope/$u"
  # /etc 是 overlayfs 且挂得很晚：只写镜像里的 /etc，开机后看不到，
  # mask 等于没做。和 apply-alioth-overlay.sh 镜像 etc/ 文件同一个理由。
  ln -sfn /dev/null "$upper/systemd/$scope/$u"
}
for u in "${mask_user[@]}"; do mask_one user "$u"; done
for u in "${mask_sys[@]}"; do mask_one system "$u"; done
log "已 mask ${#mask_user[@]} 个用户态 + ${#mask_sys[@]} 个系统态 unit（含 upper 镜像）"

log "完成"
