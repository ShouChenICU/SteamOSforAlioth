#!/usr/bin/env bash
# 断言 scripts/apply-alioth-devr.sh 把 Valve Frame 镜像「去 VR 化」这一层
# 正确装进一棵 rootfs。
#
# 这一层是 Task 8 才暴露出来的缺口：原先的裁决是「--install 不调
# scripts/apply-overlays.sh」（那个脚本要求有编译好的 gamescope），但连带
# 把整层去 VR 化也漏掉了。Frame 是 VR 头显，它的 gamescope-session.target
# 描述就是 "Gamescope VR Session"，gamescope 默认以 --backend openvr
# --vr-session-manager 启动，SteamVR 不在就立刻退 —— 表现是全程黑屏。
#
# 用一棵假的 rootfs 目录树，不碰真镜像、不需要 root、几毫秒跑完。
# 照 scripts/assert-alioth-overlay-applied.sh 的样式。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPLY="${ROOT}/scripts/apply-alioth-devr.sh"
SOVL="${ROOT}/steamos-overlay"

fails=0
pass() { printf 'PASS  %s — %s\n' "$1" "$2"; }
fail() { printf 'FAIL  %s — %s\n' "$1" "$2"; fails=$((fails + 1)); }

R="$(mktemp -d)"
trap 'rm -rf "$R"' EXIT

# 假 rootfs：Frame 镜像里与这一层相关的那几个原件。
mkdir -p "$R/usr/lib/steamos" "$R/usr/bin" "$R/var/lib/overlays/etc/upper"
echo "stock session" >"$R/usr/lib/steamos/gamescope-session"
echo "stock onready" >"$R/usr/lib/steamos/gamescope-onready"
echo "unrelated" >"$R/usr/bin/somebinary"

if [[ ! -x "$APPLY" ]]; then
  fail "脚本存在" "没有可执行的 $APPLY"
  echo; echo "${fails} 条断言失败"; exit 1
fi

out="$("$APPLY" "$R" 2>&1)"; rc=$?
[[ $rc -eq 0 ]] || fail "首次运行" "退出码 $rc: ${out:0:300}"

# 1. 会话那一套文件都装进去了，而且可执行位保住了。
#    gamescope-session / gamescope-onready / start-gamescope-session 都是由
#    systemd 的 ExecStart 或别的脚本直接执行的，装成 0644 会以 203/EXEC 失败。
want_exec=(
  usr/lib/steamos/gamescope-session
  usr/lib/steamos/gamescope-onready
  usr/lib/steamos/panel-modes
  usr/lib/steamos/sm8550-fixpad
  usr/bin/start-gamescope-session
)
missing=(); notexec=()
for f in "${want_exec[@]}"; do
  if [[ ! -f "$R/$f" ]]; then missing+=("$f"); elif [[ ! -x "$R/$f" ]]; then notexec+=("$f"); fi
done
[[ ${#missing[@]} -eq 0 ]] \
  && pass "会话脚本已装" "${#want_exec[@]} 个都在" \
  || fail "会话脚本已装" "缺少: ${missing[*]}"
[[ ${#notexec[@]} -eq 0 ]] \
  && pass "会话脚本可执行" "都带可执行位" \
  || fail "会话脚本可执行" "装成了不可执行: ${notexec[*]}"

# 2. drop-in。没有 gamescope-session.service.d/99-odin.conf，TimeoutStartSec
#    还是 Frame 原版的 5 秒，而 gamescope 起两个 Xwayland 要十几秒 ——
#    每轮必定超时被杀，sddm 反复重登，屏幕全程不亮（2026-10-23 真机实测）。
want_dropin=(
  usr/lib/systemd/user/gamescope-session.service.d/99-odin.conf
  usr/lib/systemd/user/gamescope-session.target.d/99-odin.conf
  usr/lib/systemd/user/steam.service.d/99-odin.conf
  usr/lib/systemd/user/steam.service.d/60-gamescope-env.conf
)
dmiss=()
for f in "${want_dropin[@]}"; do [[ -f "$R/$f" ]] || dmiss+=("$f"); done
[[ ${#dmiss[@]} -eq 0 ]] \
  && pass "drop-in 已装" "${#want_dropin[@]} 个都在" \
  || fail "drop-in 已装" "缺少: ${dmiss[*]}"

if [[ -f "$R/usr/lib/systemd/user/gamescope-session.service.d/99-odin.conf" ]]; then
  if grep -qE '^[[:space:]]*TimeoutStartSec=' \
      "$R/usr/lib/systemd/user/gamescope-session.service.d/99-odin.conf"; then
    pass "启动超时已放宽" "99-odin.conf 里有 TimeoutStartSec="
  else
    fail "启动超时已放宽" "99-odin.conf 没有 TimeoutStartSec= —— 会沿用 Frame 的 5 秒"
  fi
fi

# 3. 原件要备份。上游 apply-overlays.sh 的 backup() 把被替换的 Frame 原件
#    留在 /var/lib/steamos-arm-stock 下，出问题时能对照。
if [[ -f "$R/var/lib/steamos-arm-stock/usr/lib/steamos/gamescope-session" ]] \
   && grep -q "stock session" "$R/var/lib/steamos-arm-stock/usr/lib/steamos/gamescope-session"; then
  pass "原件已备份" "gamescope-session 的 Frame 原版在 var/lib/steamos-arm-stock 下"
else
  fail "原件已备份" "没有备份被替换的 gamescope-session"
fi

# 4. mask。VR 与 Frame 专属硬件的 unit 必须指向 /dev/null。
#    其中 home.mount 是 alioth 独有的一条，上游不 mask：Frame 的 home.mount
#    指向 /dev/disk/by-partsets/shared/home，而 alioth 只有一个 ext4，没有
#    这个设备 → 90 秒设备超时 → "Dependency failed for /home" → **每一个**
#    session-N.scope 都以 'dependency' 失败（连串口登录也一样），于是没有
#    seat、没有 DRM master，屏幕不亮（2026-10-23 真机实测）。
want_mask_user=(steamvr.service steamvr-logs.service steamvr-proxmicmute.service
                steamvr-v4l2cam.service steamvr-nested-desktop.service)
want_mask_sys=(steamvr-program-ble.service steamvr-v4l2loopback.service
               steamvr-set-kernel-thread-priorities.service
               deckard-audio-setup.service deckard-fan-control.service
               deckard-fpga.service deckard-led-control.service
               deckard-typec-logger.service deckard-charger.service
               deckard-power-monitor.service deckard-fpga-resume.service
               deckard-boot-images.service set-wifi-mac-address.service
               steamos-boot.service efi.mount esp.mount home.mount
               systemd-repart.service adbd.service adbd-post.service)
badmask=()
for u in "${want_mask_user[@]}"; do
  [[ "$(readlink "$R/etc/systemd/user/$u" 2>/dev/null)" == /dev/null ]] || badmask+=("user/$u")
done
for u in "${want_mask_sys[@]}"; do
  [[ "$(readlink "$R/etc/systemd/system/$u" 2>/dev/null)" == /dev/null ]] || badmask+=("system/$u")
done
[[ ${#badmask[@]} -eq 0 ]] \
  && pass "VR/Frame unit 已 mask" "$(( ${#want_mask_user[@]} + ${#want_mask_sys[@]} )) 个都指向 /dev/null" \
  || fail "VR/Frame unit 已 mask" "未 mask: ${badmask[*]}"

# 4b. mask 必须同时落到 /etc 的 overlayfs upper 里。/etc 是
#     lowerdir=/etc,upperdir=/var/lib/overlays/etc/upper，而且挂得很晚 ——
#     只写镜像里的 /etc，开机后看不到，mask 等于没做。和
#     apply-alioth-overlay.sh 镜像 etc/ 文件是同一个理由。
upper_bad=()
for u in "${want_mask_user[@]}"; do
  [[ "$(readlink "$R/var/lib/overlays/etc/upper/systemd/user/$u" 2>/dev/null)" == /dev/null ]] \
    || upper_bad+=("user/$u")
done
for u in "${want_mask_sys[@]}"; do
  [[ "$(readlink "$R/var/lib/overlays/etc/upper/systemd/system/$u" 2>/dev/null)" == /dev/null ]] \
    || upper_bad+=("system/$u")
done
[[ ${#upper_bad[@]} -eq 0 ]] \
  && pass "mask 已镜像到 upper" "upper 里同样指向 /dev/null" \
  || fail "mask 已镜像到 upper" "upper 里缺: ${upper_bad[*]} —— 开机时 mask 不生效"

# 5. 刻意**不**能 mask 的那几个。alioth 没有 UART 排针也没有 ADB，USB
#    gadget 的 ACM 口与 NCM 网口是唯一的观测通道；而
#    usb-ncm-dnsmasq@.service 虽然自己会失败，它在失败前已经执行了
#    `ip addr add 10.86.200.233/29 dev usb0` —— mask 掉它设备就没地址了。
#    iwd 也不 mask：2026-10-23 真机实测 WiFi 在原版 iwd 下正常扫描与连接，
#    上游换 wpa_supplicant 是它自己板子的需要。
keep=(usb-gadget.service usb-gadget.target usb-ncm-gadget@.service
      usb-ncm-dnsmasq@.service iwd.service)
wrong=()
for u in "${keep[@]}"; do
  [[ -L "$R/etc/systemd/system/$u" ]] && wrong+=("$u")
done
[[ ${#wrong[@]} -eq 0 ]] \
  && pass "通道与 WiFi 未被 mask" "${keep[*]} 都没被 mask" \
  || fail "通道与 WiFi 未被 mask" "被 mask 了: ${wrong[*]} —— 会失去串口/网络通道或 WiFi"

# 6. 不碰无关文件。
[[ -f "$R/usr/bin/somebinary" ]] \
  && pass "不误伤无关文件" "usr/bin/somebinary 仍在" \
  || fail "不误伤无关文件" "usr/bin/somebinary 被删了"

# 7. 幂等。构建流程会重跑它，第二次不得报错或改变结果。
before="$(cd "$R" && find . | sort | md5sum)"
out2="$("$APPLY" "$R" 2>&1)"; rc2=$?
after="$(cd "$R" && find . | sort | md5sum)"
if [[ $rc2 -eq 0 && "$before" == "$after" ]]; then
  pass "幂等" "第二次运行退出 0，文件清单不变"
else
  fail "幂等" "第二次运行退出 $rc2，文件清单变了: ${out2:0:200}"
fi

# 7b. 幂等的第二次不得把已经替换过的文件再「备份」一遍 —— 那会把我们自己
#     的版本当成原件存进去，原版就永远丢了。
if [[ -f "$R/var/lib/steamos-arm-stock/usr/lib/steamos/gamescope-session" ]] \
   && grep -q "stock session" "$R/var/lib/steamos-arm-stock/usr/lib/steamos/gamescope-session"; then
  pass "备份不被覆盖" "重跑后备份里仍是 Frame 原版"
else
  fail "备份不被覆盖" "重跑把我们的版本当原件覆盖了备份"
fi

echo
if ((fails)); then
  echo "${fails} 条断言失败"
  exit 1
fi
echo "全部断言通过"
