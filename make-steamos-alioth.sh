#!/usr/bin/env bash
# Build the boot image for alioth (Xiaomi Redmi K40 / POCO F3).
#
# Phase 1 has no rootfs at all, so --kernel-only is the only mode and what
# it makes is a debug image: work/steamos-alioth/boot-debug.img, holding the
# kernel, the single alioth DTB and the initramfs that is built into the
# Image (EMBED_INITRAMFS=1 in kernel-sm8250/soc.env).
#
# This does not reuse the kit's own boot/KERNEL, which is packed for the
# ROCKNIX ABL. Xiaomi's ABL is a different bootloader and gets the page size
# and load addresses that a boot image is actually known to have booted on
# this device with -- see PAGESIZE below.
#
# Flash it with ./flash-alioth.sh --test.
set -euo pipefail

PORT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KCOMMON="${PORT_ROOT}/external-and-mods/kernel-common"
SOC_DIR="${PORT_ROOT}/external-and-mods/kernel-sm8250"
DTB=sm8250-xiaomi-alioth

KOUT="$(readlink -f "${KERNEL_OUT:-${PORT_ROOT}/work/kernel-sm8250/output/current}" 2>/dev/null || true)"
OUT="${STEAMOS_WORK:-${PORT_ROOT}/work}/steamos-alioth"

die() { echo "make-steamos-alioth: $*" >&2; exit 1; }

MODE="${1:-}"
shift || true
SKIP_COPY=0
SRC_ROOTFS="${STEAMOS_SRC_ROOTFS:-${STEAMOS_WORK:-${PORT_ROOT}/work}/rootfs}"
R="${STEAMOS_ROOTFS:-${STEAMOS_WORK:-${PORT_ROOT}/work}/rootfs-alioth}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-copy)    SKIP_COPY=1 ;;
    --from-rootfs)  SRC_ROOTFS="$2"; shift ;;
    *) die "不认识的参数: $1" ;;
  esac
  shift
done
case "$MODE" in
  --kernel-only|--install) ;;
  *) die "用法: $0 --kernel-only | --install [--from-rootfs DIR] [--skip-copy]" ;;
esac

# --install 没有机内签名固件就不要构建。
#
# 2026-10-24 的独立审查指出的不对称：boot 镜像的那套规则是**接线进写入路径**
# 的（flash-alioth.sh 在任何写之前跑 assert-alioth-boot-image.sh），而「固件
# 是不是机内签名版」只靠记性 —— 原来这里只打印四行 `!!` 然后继续，照样产出
# 一个完整的 9 GB kit。那之后的事：rsync 跑十几分钟、警告滚出屏幕、
# `flash-alioth.sh --install`、输入 ERASE，**Android 的 /data 就此消失**，
# 然后设备黑屏无声，因为小米的 TrustZone 拒收 linux-firmware 的通用签名
# a650_zap.mbn。而要重新取固件，得从一台 Android 已经被擦掉的手机上取。
#
# 所以这个检查放在最前面：在 rsync 之前、在任何耗时的事情之前就退出。
# 真要构建一个明知没有 GPU 和声音的测试镜像，设 ALIOTH_FW_GENERIC_OK=1 —— 它
# 会在 kit 里留下一个 GENERIC-FIRMWARE 标记，而 flash-alioth.sh --install 看到
# 那个标记会再拦一次（两次 opt-in，而且产物自己带着出处）。
if [[ "$MODE" == --install && "${ALIOTH_FW_GENERIC_OK:-}" != 1 ]]; then
  [[ -n "${ALIOTH_FW_DIR:-}" ]] \
    || die "--install 需要 ALIOTH_FW_DIR —— 没有机内签名固件，装出来的系统是黑屏加没声音。
     先跑 scripts/extract-alioth-firmware.sh（见它的头注释）取出这台手机自己的
     a650_zap.mbn 和 adsp.mbn，再设 ALIOTH_FW_DIR=<产物目录> 重跑。
     明知要造一个没有 GPU 和声音的测试镜像：ALIOTH_FW_GENERIC_OK=1"
  [[ -d "${ALIOTH_FW_DIR}" ]] \
    || die "ALIOTH_FW_DIR=${ALIOTH_FW_DIR} 不是一个目录"
fi

# Xiaomi's ABL. These are pmaports' deviceinfo values for this device
# (flash_pagesize 4096, offset_base 0 + kernel 0x8000 / ramdisk 0x1000000 /
# tags 0x100), which is the only set a boot image is known to have booted
# with here -- the kit's defaults (2048, 0x10000000) are the ROCKNIX ABL's.
# ABL relocates either way: its UART log puts RAM at 0x80000000, above all
# of these addresses. There is still no reason to deviate from the proven
# values on the one image we cannot test cheaply.
PAGESIZE=4096
KERNEL_ADDR=0x00008000
RAMDISK_ADDR=0x01000000
TAGS_ADDR=0x00000100
# second_size is 0, so nothing is loaded here -- but the whole point of the
# four values above is to not deviate from the set this phone is known to
# have started with, and mkbootimg-v0.py's own default is the ROCKNIX base.
SECOND_ADDR=0x00F00000

img="${KOUT}/boot/Image"
dtb="${KOUT}/dtbs/${DTB}.dtb"
[[ -n "$KOUT" && -d "$KOUT" ]] || die "没有内核输出目录（KERNEL_OUT=${KERNEL_OUT:-默认}）"
[[ -s "$img" ]] || die "没有 $img —— kernel-sm8250/soc.env 里需要 KEEP_IMAGE=1"
[[ -s "$dtb" ]] || die "没有 $dtb —— soc.env 的 DTBS 里要有 $DTB"

mkdir -p "$OUT"

# The payload ABL gets: a gzip stream, with the DTB appended after it.
#
# gzip is what this bootloader is known to take: pmaports' APKBUILD installs
# the kernel with `make zinstall` (i.e. Image.gz) and sets append_dtb, and
# ABL's own log then reports `Best match DTB tags 356/0000002C/...` -- 0x2C
# is 44, alioth's qcom,board-id. Note this gzips the raw Image, never the
# kernel's own Image.gz: with CONFIG_EFI_ZBOOT=y (which this config has)
# that file is an EFI PE wrapper, not a gzip stream, and a bootloader
# without EFI never unpacks it. That is the one bug pmaports' README calls
# "THE IMPOSTOR".
#
# Only alioth's DTB goes in. The kit's 11-DTB KERNEL would also match
# correctly -- board-id <44 0> is unique among them -- but there is no
# reason to hand this bootloader ten other boards' device trees.
pack_boot() {   # pack_boot <输出文件名>
payload="${OUT}/payload.gz"
gzip -9 -n -c "$img" >"$payload"
cat "$dtb" >>"$payload"

# CMDLINE_QUIET=0: the console on the panel is one of the only two log
# channels in phase 1, and the default cmdline's `quiet loglevel=0` would
# silence exactly that.
# No fbcon=rotate: the panel driver now reports its rotation = <270> to DRM
# (.get_orientation), and DRM's fbdev emulation already turns the console
# by itself. A fbcon=rotate on top of that composes with it, and which way
# up the result lands is not something that can be settled away from the
# device -- on the one channel phase 1 depends on, guessing is the wrong
# trade. Reading a boot log on a phone held upright is fine; landscape is
# Game Mode's requirement, i.e. phase 2's.
# steamos.bootlabel= is set to a GPT name that cannot exist here. Left at
# its default the initramfs looks for a partition called ROCKNIX and, if it
# found one, would mount it read-write and write a boot log into it. No
# alioth partition carries that name, so today nothing is written -- but
# "禁止写入" is a hard constraint, and this turns it from a coincidence into
# a guarantee.
# steamos.usbshell=1 is the single switch that starts the USB gadget shell
# (ACM serial + a root shell on 172.16.42.1:23) -- initramfs/init does
# nothing of the sort without it, and that is the other log channel. The
# network half is nc, not telnetd: this busybox has no telnetd applet, so
# every image before this one answered RST on port 23.
# ft8756.poll= is gone: the probe-time power cycle (patch 0024) fixed the
# chip, the ID check now passes on its own and IRQ 152 counted 7398
# interrupts on the last boot, so the 20Hz poll fallback is pure overhead.
# ft8756.ignore_id=1 stays as a one-line safety net -- it still logs
# "unknown chip id, continuing" when the ID read fails, so a regression is
# visible either way, and a warning plus a working panel beats no touch.
# panic=120: CONFIG_PANIC_TIMEOUT=0 in this config, so a panicking kernel
# hangs forever. That is the worst possible behaviour for the crash-log
# channel this image depends on -- pstore writes the record on panic, but
# the only way out of the hang is a long press on power, which is exactly
# the reset that does not preserve DRAM, so the record is destroyed before
# it can be read. Any non-zero value fixes that: the kernel reboots warm,
# DRAM survives, and the record is there to read on the next boot.
#
# 120s rather than a few seconds, because a reproducible panic at boot
# turns this into a loop, and every iteration spends one A/B boot attempt
# -- this port never marks a slot successful, so once they run out the
# bootloader marks the slot unbootable and falls back to the other one,
# which carries stock Android (slot b is never written here). At 120s
# that takes about a quarter of an hour and the panic sits on the panel
# the whole time, which is room to hold volume-down + power and go to
# fastboot instead. At 10s it would be over in a minute.
# No sysrq_always_enabled here, and the reason is worth writing down
# because it reads the other way at first glance: sysrq is ALREADY fully
# enabled. CONFIG_MAGIC_SYSRQ_DEFAULT_ENABLE=0x1 looks like a bitmask
# allowing only loglevel control (SYSRQ_ENABLE_LOG), but sysrq_on_mask()
# is `sysrq_always_enabled || sysrq_enabled == 1 || (sysrq_enabled & mask)`
# -- the value 1 is special-cased to mean every function, and the bitmask
# reading only applies above 1. So reboot and crash work as shipped.
#
# That matters because it is the escape hatch when userspace wedges, which
# is not hypothetical: the debug shell and the network listener both died
# across a host-mode test and left no way into a live kernel. It is reachable from
# the panel only -- u_serial.c has no sysrq handling at all, so the ACM
# console cannot deliver one -- but CONFIG_VT=y, VT_CONSOLE=y and a USB-C
# keyboard enumerating in host mode make Alt+SysRq+B a warm reboot that
# keeps DRAM.
# steamos.root= is used rather than relying on root=, because this ABL
# appends its own arguments after ours and init takes the last root= it
# sees; steamos.root= always wins over root= (initramfs/init).
# PARTLABEL=userdata is a partition that exists but holds Android's
# encrypted f2fs, so init resolves it at once and the ext4 mount then fails
# on the read-only superblock probe, without writing anything, and drops to
# a shell. That failure IS the expected phase-1 outcome.
# initcall_blacklist=simpledrm_platform_driver_init：让 msm 拿到 DRM minor 0。
#
# 镜像自带的 MangoHud 把 GPU 占用率的来源路径写死成
# /sys/kernel/debug/dri/0/perf_now（上游 master 已改成遍历
# /sys/class/drm/<node>/device/drm 找 card*，但这个版本还没有）。而这台机器上
# card0 不存在：simpledrm 开机早期为 /chosen/framebuffer 注册，占掉 minor 0，
# msm 通过 aperture 接管后 simpledrm 退场，可 minor 号不回收 —— 于是 msm 落在
# dri/1，MangoHud 读到的是不存在的文件，面板上就恒为 0。Frame 上 msm 就是
# card0，Valve 才敢写死。
#
# 配置里 CONFIG_DRM_SIMPLEDRM 仍然是 y，屏蔽只在 cmdline 这一层 —— 去掉这个
# token 就全恢复。代价是失去 msm 绑定之前那几秒的 framebuffer 控制台（阶段 1
# 依赖的那条通道）。msm 绑定之后 fbcon 走 CONFIG_DRM_MSM_KMS_FBDEV，面板上的
# 控制台照旧。真要调早期启动，把这个 token 删掉重做镜像即可。
cmdline="$(
  CMDLINE_QUIET=0 \
  KERNEL_CMDLINE_EXTRA="ft8756.ignore_id=1 panic=120 steamos.usbshell=1 steamos.root=PARTLABEL=userdata steamos.bootlabel=steamos-arm-no-boot-partition initcall_blacklist=simpledrm_platform_driver_init" \
  bash -c "source '${SOC_DIR}/soc.env'; source '${KCOMMON}/cmdline.sh'; build_cmdline PARTLABEL=userdata"
)"

# No --ramdisk: EMBED_INITRAMFS=1 puts the initramfs inside the Image, and
# mkbootimg-v0.py then writes the same dummy ramdisk ROCKNIX does.
# Reproducible: without SOURCE_DATE_EPOCH the header's os_version carries
# today's date, so an unchanged kernel yields a different image and a
# different checksum tomorrow -- which also makes SHA256SUMS useless for
# telling two builds apart. The Image's own mtime makes the output a
# function of its input.
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(stat -c %Y "$img")}"

python3 "${KCOMMON}/mkbootimg-v0.py" \
  --kernel "$payload" \
  --cmdline "$cmdline" \
  --pagesize "$PAGESIZE" \
  --kernel-addr "$KERNEL_ADDR" \
  --ramdisk-addr "$RAMDISK_ADDR" \
  --tags-addr "$TAGS_ADDR" \
  --second-addr "$SECOND_ADDR" \
  --out "${OUT}/$1"
rm -f "$payload"
echo "cmdline: $cmdline"
}

# SHA256SUMS 覆盖 OUT 里现有的全部镜像。两个模式共用这个目录，而
# flash-alioth.sh 会 `sha256sum -c` 它 —— 只写自己那一个的话，另一个模式
# 产出的镜像就会从校验里消失。
sums() { (cd "$OUT" && sha256sum ./*.img >SHA256SUMS); }

if [[ "$MODE" == --kernel-only ]]; then
  pack_boot boot-debug.img
  sums
  echo "kernel:  $(basename "$KOUT") ($(readlink -f "$KOUT"))"
  ls -l "${OUT}/boot-debug.img"
  echo
  echo "刷机: ./flash-alioth.sh --test"
  exit 0
fi

# ---------------------------------------------------------------------------
# --install：整机镜像
#
# 不调上游的 scripts/apply-overlays.sh（本仓库已不再带它，见下）。那个脚本要求有编译好的 gamescope
# （第 37 行 die），而 alioth 按 spec §4 原样用 Valve 的 rootfs —— 里面
# 的 gamescope、Steam、FEX、Turnip、InputPlumber 都是现成的，没有理由为了
# 跑通一个前置检查去编一份替换品。这正是 REDMAGIC 6 的做法：
# make-steamos-sm8350.sh 调的是 177 行的 apply-overlays-sm8350.sh，
# 同样不碰那个大脚本。
#
# 于是本模式自己做 apply-overlays-sm8350.sh 做的那三件事：
#   1. 内核模块 + 固件
#   2. sm8250-overlay（主要是 steamos-powerbuttond.service —— spec §7.1
#      点名要它，Frame 自带的 unit 依赖 SteamVR）
#   3. alioth-overlay（scripts/apply-alioth-overlay.sh）
# ---------------------------------------------------------------------------

KREL="$(basename "$KOUT")"
KIT="$OUT"
S8250_OVL="${PORT_ROOT}/sm8250-overlay"

for c in rsync mkfs.ext4 losetup uuidgen; do
  command -v "$c" >/dev/null || die "缺少 $c"
done
[[ -d "$KOUT/modules/$KREL" ]] || die "没有 $KOUT/modules/$KREL"
[[ -d "$KOUT/firmware" ]] || die "没有 $KOUT/firmware"

# 1. 复制共享 rootfs。源永不修改 —— 下一次构建还要从同一个干净的树开始。
if [[ "$SKIP_COPY" -eq 1 ]]; then
  [[ -x "$R/usr/bin/bash" ]] || die "--skip-copy 但 $R 里没有 rootfs"
  echo "==> 跳过复制，沿用 $R"
else
  [[ -x "${SRC_ROOTFS}/usr/bin/bash" ]] \
    || die "没有源 rootfs ${SRC_ROOTFS} —— 先跑 scripts/fetch-steamos-rootfs.sh"
  [[ "$(readlink -f "$SRC_ROOTFS")" != "$(readlink -f "$R")" ]] \
    || die "源和目标必须不同（这个模式会改目标）"
  echo "==> 复制 rootfs ${SRC_ROOTFS} → ${R}"
  sudo mkdir -p "$R"
  sudo rsync -aHAX --numeric-ids --delete "${SRC_ROOTFS}/" "${R}/"
fi

# 2. 内核模块与固件。
echo "==> 装入内核模块与固件（$KREL）"
sudo mkdir -p "$R/usr/lib/modules" "$R/usr/lib/firmware"
sudo rm -rf "$R"/usr/lib/modules/*
sudo cp -a "$KOUT/modules/$KREL" "$R/usr/lib/modules/$KREL"
sudo rsync -a "$KOUT/firmware/" "$R/usr/lib/firmware/"
sudo mkdir -p "$R/opt/steamos-alioth/$KREL"
sudo cp -a "$KOUT/config-$KREL" "$KOUT/dtbs" "$R/opt/steamos-alioth/$KREL/"

# 2a. 机内签名固件。必须盖在 linux-firmware 之后 —— 文件名一样，要的就是
#     后写的赢。
#
#     alioth 的 TrustZone 拒收 linux-firmware 里所有通用签名的 PAS 镜像
#     （qcom_scm_pas_init_image -> -EINVAL，内核只说 "error -22 initializing
#     firmware"）。两份文件连大小都和 linux-firmware 的一样，只有签名不同，
#     所以「文件在不在」这种检查发现不了。没有它们的后果：
#       a650_zap -> GPU hw init failed -110 -> gamescope 找不到物理设备
#                -> sddm 死循环 -> 一块**黑屏**
#       adsp     -> q6afe 不上线 -> PipeWire 只有 Dummy Output
#
#     固件是小米签的，不可再分发，所以不在仓库里：
#     scripts/extract-alioth-firmware.sh 从设备自己的 modem_a 和 super 里取。
if [[ -n "${ALIOTH_FW_DIR:-}" && -d "${ALIOTH_FW_DIR}" ]]; then
  "${PORT_ROOT}/scripts/assert-alioth-firmware.sh" "${ALIOTH_FW_DIR}" \
    || die "ALIOTH_FW_DIR=${ALIOTH_FW_DIR} 没过 assert-alioth-firmware.sh"
  echo "==> 盖上机内签名固件（${ALIOTH_FW_DIR}）"
  sudo rsync -a "${ALIOTH_FW_DIR}/" "$R/usr/lib/firmware/"
  # 让产物自己带着出处，而且是**正面**的那种：flash-alioth.sh --install 要求
  # 看到 DEVICE-FIRMWARE 才肯写 userdata。为什么不是「没有 GENERIC 标记就放
  # 行」—— 那样一个在这个检查存在之前构建的 kit、或者一个手工拷过来的 kit，
  # 都会被当成好的。不可逆的那一步要的是有人签过字，不是没人反对。
  mkdir -p "$OUT"
  rm -f "$OUT/GENERIC-FIRMWARE"
  {
    echo "机内签名固件，取自 ALIOTH_FW_DIR=${ALIOTH_FW_DIR}"
    echo "构建时间 $(date -Is)"
    (cd "${ALIOTH_FW_DIR}" && find . -type f -print0 | sort -z \
      | xargs -0 sha256sum) 2>/dev/null || true
  } >"$OUT/DEVICE-FIRMWARE"
else
  echo "!! 没有 ALIOTH_FW_DIR —— 镜像用的是 linux-firmware 的通用签名固件。"
  echo "!! alioth 的 TrustZone 会拒收它们：开机是黑屏，而且没有声音。"
  echo "!! 先跑 scripts/extract-alioth-firmware.sh（见它的头注释），再设"
  echo "!! ALIOTH_FW_DIR=<产物目录> 重跑。"
  # 让产物自己带着出处。警告会滚出屏幕，文件不会 —— flash-alioth.sh --install
  # 读的是这个文件，不是操作者的记性。
  if [[ "$MODE" == --install ]]; then
    mkdir -p "$OUT"
    rm -f "$OUT/DEVICE-FIRMWARE"
    cat >"$OUT/GENERIC-FIRMWARE" <<'FWEOF'
这个 kit 是在没有 ALIOTH_FW_DIR 的情况下构建的，a650_zap.mbn 与 adsp.mbn 是
linux-firmware 的通用签名版。alioth 的 TrustZone 拒收它们：

  a650_zap -> GPU hw init failed -110 -> gamescope 找不到物理设备
           -> sddm 死循环 -> 一块**黑屏**
  adsp     -> q6afe 不上线 -> PipeWire 只有 Dummy Output，一点声音没有

flash-alioth.sh --install 看到这个文件会拒绝执行。要刷它（明知黑屏无声），
在刷的时候也设 ALIOTH_FW_GENERIC_OK=1。
FWEOF
  fi
fi

# 2b. InputPlumber。Valve 的 Frame 镜像里**没有**这个守护进程 —— 只有
#     Steam 自己的 udev 规则（90-steam-inputplumber.rules）。而 spec §7.1
#     的整个输入设计都压在它上面：蓝牙手柄和音量键经它变成一个虚拟 Deck
#     手柄。上游移植靠 install-inputplumber-sm8550.sh 装一份官方预编译的
#     aarch64 release，这里复用它，但跳过它自带的 SM8550 复合设备配置
#     （我们自己的在 alioth-overlay 里，而那套 ext-hid 服务和 udev 规则
#     在别的板子上不是惰性的）。
#     放在 sm8250-overlay 之前：它的 tarball 会往 $R/etc 里铺文件。
echo "==> 装入 InputPlumber（仅守护进程）"
sudo env INPUTPLUMBER_SKIP_DEVICE_COMPOSITE=1 \
  "${PORT_ROOT}/scripts/install-inputplumber-sm8550.sh" "$R"

# 3. sm8250-overlay。和上游 apply-overlays.sh 的 SOC=sm8250 分支同一个循环、
#    同样的权限位。其中掌机的那些 InputPlumber profile 对 alioth 是惰性的
#    （各自 gate 在自己的 DT model 上），而 steamos-powerbuttond.service
#    是我们要用的，见 alioth-overlay/README.md。
echo "==> 装入 sm8250-overlay"
while IFS= read -r f; do
  sudo install -D -m0644 "$S8250_OVL/$f" "$R/$f"
done < <(cd "$S8250_OVL" && find etc usr -type f)

# 4. alioth-overlay。
echo "==> 装入 alioth-overlay"
sudo "${PORT_ROOT}/scripts/apply-alioth-overlay.sh" "$R"

# 4a2. 去 VR 化。Frame 是 VR 头显：gamescope-session.target 的 Description
#      就是 "Gamescope VR Session"，gamescope 默认以 --backend openvr
#      --vr-session-manager 启动，SteamVR 不在就立刻退 —— 表现是全程黑屏。
#      上面那条「不调 apply-overlays.sh」的裁决当初连带把整层去 VR 化也漏
#      掉了，这是 Task 8 真机实测补上的。放在两个 overlay 之后，是为了备份到
#      /var/lib/steamos-arm-stock 的一定是 Frame 原件而不是 overlay 刚写进去
#      的东西；upper 下的目录这一步自己会建。
echo "==> 去 VR 化（会话脚本 + unit mask）"
sudo "${PORT_ROOT}/scripts/apply-alioth-devr.sh" "$R"

# 4b. /etc 的 overlayfs。etc.mount 是
#     lowerdir=/etc,upperdir=/var/lib/overlays/etc/upper,workdir=.../work，
#     而 overlayfs 要求 upperdir 和 workdir **都已存在** —— systemd 的
#     mount unit 不会替你建。Valve 的 rootfs.img 里两个都没有，所以必须
#     在这里建全。只建 upper 的话 etc.mount 会失败，/etc 退回下层，
#     而我们镜像到 upper 的那些配置就全不生效。
sudo mkdir -p "$R/var/lib/overlays/etc/upper" "$R/var/lib/overlays/etc/work"

# 4c. 启用 inputplumber.service。预编译 release 里带 unit，但不带 enable
#     链接，而没有它 InputPlumber 根本不启动 —— 症状是「手柄在 Steam 里
#     还是 Xbox 图标」。
for u in inputplumber.service; do
  if [[ -f "$R/usr/lib/systemd/system/$u" ]]; then
    sudo mkdir -p "$R/usr/lib/systemd/system/multi-user.target.wants"
    sudo ln -sfn "../$u" "$R/usr/lib/systemd/system/multi-user.target.wants/$u"
    echo "==> 已启用 $u"
  else
    echo "!! 没有 $u —— InputPlumber 没装上？"
  fi
done

# 4d. Steam 客户端种子（spec §6.4）。可选，因为它需要一棵现成的完整
#     ARM 客户端树（STEAM_ARM_SEED）或 vendor 的 install-steam-arm，两者
#     都不在这台构建机上。
#
#     镜像自带 /usr/lib/steam/steam.tar.zst 作为 bootstrap，首次开机联网
#     自举。上游 install-complete-steam-client.sh 的注释说 Frame 的这个
#     tarball「version 0、缺 package zip、转圈」—— 那是他们在自己环境里的
#     结论，alioth 上是不是这样要 Task 8 实测。这里不假装解决了。
STEAM_HOME="$R/home/steamos/.local/share/Steam"
if [[ -n "${STEAM_ARM_SEED:-}" && -d "${STEAM_ARM_SEED}" ]]; then
  echo "==> 预置 Steam ARM 客户端（种子 ${STEAM_ARM_SEED}）"
  sudo mkdir -p "$STEAM_HOME"
  sudo env STEAM_ARM_SEED="${STEAM_ARM_SEED}" \
    "${PORT_ROOT}/scripts/install-complete-steam-client.sh" "$STEAM_HOME"
  sudo chown -R 1000:1000 "$R/home/steamos"
else
  echo "!! 没有 STEAM_ARM_SEED —— 镜像里不预置 Steam 客户端。"
  echo "!! 首次开机会用 /usr/lib/steam/steam.tar.zst 联网自举（约 2.5 GB）。"
  echo "!! spec §6.4 要求预置；要预置就设 STEAM_ARM_SEED=<一棵完整的 Steam 树> 重跑。"
fi

# 4e. 开发者 ssh 入口（可选，默认关闭）。
#
#     为什么默认关闭：这一步产出的是一台会连家里 WiFi 的设备的根文件系统。
#     镜像里躺着一把公钥、ssh 守护进程又是开机自启，那就是个后门 —— 而且
#     是「我按照 README 刷了机」的人完全看不见的后门。所以它由环境变量
#     ALIOTH_SSH_PUBKEY 显式打开，不设就一个字节都不写。
#     scripts/assert-alioth-kit.sh 的 A.1b 条静态断言这件事。
#
#     设了之后能干什么：scripts/alioth-ssh.sh 走 USB NCM（设备 10.86.200.233）
#     直接进系统。Game Mode 下没有终端，而真机上大部分修复（/usr 和 /etc
#     都可写）靠 ssh 就能落地，不必重新刷机 —— 阶段 2 的黑屏、触摸、电源键、
#     音频全是这么诊断出来的。
#
#     用法: ALIOTH_SSH_PUBKEY=~/.ssh/id_ed25519.pub ./make-steamos-alioth.sh --install
if [[ -n "${ALIOTH_SSH_PUBKEY:-}" ]]; then
  pub="${ALIOTH_SSH_PUBKEY}"
  [[ -f "$pub" ]] || die "ALIOTH_SSH_PUBKEY=$pub 不是一个文件"
  grep -qE '^(ssh|ecdsa)-' "$pub" \
    || die "ALIOTH_SSH_PUBKEY=$pub 看着不像公钥（第一行不以 ssh-/ecdsa- 开头）；
     别把私钥装进镜像。"
  echo "==> 装开发者 ssh 入口（公钥 $pub）"

  # 公钥进 steamos 用户的 home。/home 在 alioth 上就在根文件系统里
  #（Frame 的 home.mount 指向一个本机没有的分区，已在去 VR 化那一步 mask 掉）。
  sudo install -d -m0700 -o 1000 -g 1000 "$R/home/steamos/.ssh"
  sudo install -m0600 -o 1000 -g 1000 "$pub" "$R/home/steamos/.ssh/authorized_keys"

  # enable 守护进程。镜像自带的 unit 声明 WantedBy=multi-user.target，
  # 但预编译镜像里没有那条 enable 链接，而构建机上不能对别人的 rootfs 跑
  # systemctl enable（会写到本机的 /etc），所以手工建链接。
  # 两份：镜像里的 /etc 是 overlayfs 的 lowerdir，开机时真正生效的是
  # upperdir —— 只写 lowerdir 的话，开机后这条链接根本不存在。
  for d in "$R/etc/systemd/system" "$R/var/lib/overlays/etc/upper/systemd/system"; do
    sudo mkdir -p "$d/multi-user.target.wants"
    sudo ln -sfn /usr/lib/systemd/system/sshd.service \
      "$d/multi-user.target.wants/sshd.service"
  done
  # 主机密钥由 sshdgenkeys.service 在首次开机生成（sshd.service 自己
  # Wants= 它），这里不预生成 —— 每台机器的主机密钥必须是自己的。

  # 自刷授权。alioth-write-boot 要 root（它写 boot_a/boot_b），而正式系统里
  # steamos 没有免密 sudo —— 真机实测 `sudo -n true` 要密码，而 Game Mode
  # 下没有地方输。放开的只有这一个命令，而且只在这个 opt-in 块里放开：
  # 不设 ALIOTH_SSH_PUBKEY 的镜像一条 sudoers 规则都不多。
  #
  # 为什么值得放开：改内核是这个项目里重复次数最多的循环，而每一轮本来都要
  # 人按住音量下 + 电源进 fastboot。有了它一轮是「送文件 + 普通重启」。
  # 能放开这一个命令是因为那个脚本自己把边界守住了 —— 只认 PARTLABEL 是
  # boot_a/boot_b 的块设备，别的分区（super、userdata，尤其是 abl）它一个
  # 字节都不写，而且写完会读回来比 sha256。
  #
  # 名字必须以 zz- 开头。@includedir 按文件名排序读，而 sudoers 里**后面
  # 的规则覆盖前面的** —— 镜像自带 /etc/sudoers.d/wheel 写着
  #   %wheel ALL=(ALL) ALL
  # 而 steamos 在 wheel 组里（真机实测 groups=…,998(wheel),…）。叫
  # 50-alioth-write-boot 的话它排在 wheel 前面，于是 wheel 那条带密码的规则
  # 最后生效，`sudo -n` 照样要密码（实测如此）。zz- 排在 wheel 后面。
  #
  # 第二条是 alioth-install-modules：boot 镜像里只有内核和设备树，模块在
  # userdata 上，而这个移植里一半的东西是 `=m`。只换 boot 的后果是「改动
  # 在构建机的模块里，设备上加载的还是旧那份，版本字符串一样所以什么都不
  # 报错」—— 2026-10-24 就这么丢掉了一轮。它的边界也在它自己里：归档每个
  # 成员的路径、类型、链接目标都先验过，只往 /usr/lib/modules/<版本> 写。
  #
  # 第三条命令是 `systemctl reboot`。写完 boot 槽要重启才生效，而 steamos
  # 自己重启不了 —— 真机实测 `systemctl reboot` 回
  #   Call to Reboot failed: Interactive authentication required.
  # （没有本地 seat 的 ssh 会话，polkit 不给过）。少了它，「不用碰手机」这件事
  # 就在最后一步断掉。放开它不扩大什么：能登进来的人本来就能让机器重启。
  sudo install -d -m0750 "$R/etc/sudoers.d"
  printf '%s\n' \
    'steamos ALL=(root) NOPASSWD: /usr/lib/steamos-arm/alioth-write-boot' \
    'steamos ALL=(root) NOPASSWD: /usr/lib/steamos-arm/alioth-install-modules' \
    'steamos ALL=(root) NOPASSWD: /usr/bin/systemctl reboot' \
    | sudo install -m0440 /dev/stdin "$R/etc/sudoers.d/zz-alioth-write-boot"
  # 同样要进 overlay 的 upperdir，否则开机后这条规则不存在（见上面那段注释）。
  sudo install -d -m0750 "$R/var/lib/overlays/etc/upper/sudoers.d"
  sudo install -m0440 "$R/etc/sudoers.d/zz-alioth-write-boot" \
    "$R/var/lib/overlays/etc/upper/sudoers.d/zz-alioth-write-boot"
  echo "!! 这个镜像开机就允许 ssh steamos@ 登录。只给自己的设备用。"
else
  echo "!! 没有 ALIOTH_SSH_PUBKEY —— 镜像里不装 ssh 公钥、不开 ssh 守护进程。"
  echo "!! 要开发者入口就设 ALIOTH_SSH_PUBKEY=<你的 .pub> 重跑；见 scripts/alioth-ssh.sh。"
fi

# 5. 首次开机哨兵。alioth-firstboot 见不到它就什么都不做，根文件系统会
#    永远停在几 GB —— 而 Steam 第一次装游戏才会报错。
sudo mkdir -p "$R/var/lib"
sudo touch "$R/var/lib/alioth-firstboot-pending"

# 6. 每台机器要有自己的 D-Bus / 网络身份。
sudo truncate -s 0 "$R/etc/machine-id"
[[ -f "$R/var/lib/overlays/etc/upper/machine-id" ]] \
  && sudo truncate -s 0 "$R/var/lib/overlays/etc/upper/machine-id"

# 7. 造 ext4。镜像只装得下内容 + 一点余量；首次开机长到整个分区。
root_uuid="$(uuidgen)"
used_mib="$(sudo du -sm --exclude=proc --exclude=sys --exclude=dev \
  --exclude=tmp --exclude=run "$R" | awk '{print $1}')"
root_mib=$((used_mib + 1024 + used_mib / 50 + 128))
raw="${STEAMOS_WORK:-${PORT_ROOT}/work}/.userdata-alioth.img"
echo "==> userdata: ${root_mib} MiB ext4 UUID=${root_uuid}（内容 ${used_mib} MiB，首次开机长到 106 GiB）"

rm -f "$raw"
truncate -s "${root_mib}M" "$raw"
sudo mkfs.ext4 -q -F -L steamos -U "$root_uuid" -m 1 "$raw"

MNT="${STEAMOS_WORK:-${PORT_ROOT}/work}/.alioth-img-mnt"
LOOPDEV=""
cleanup_img() {
  mountpoint -q "$MNT" 2>/dev/null && sudo umount "$MNT"
  [[ -n "$LOOPDEV" ]] && sudo losetup -d "$LOOPDEV" 2>/dev/null
  LOOPDEV=""
}
trap cleanup_img EXIT
sudo mkdir -p "$MNT"
LOOPDEV="$(sudo losetup -f --show "$raw")"
[[ -n "$LOOPDEV" ]] || die "losetup 失败"
sudo mount "$LOOPDEV" "$MNT"

echo "==> 复制根文件系统进镜像"
sudo rsync -aHAX --numeric-ids \
  --exclude='/dev/**' --exclude='/proc/**' --exclude='/sys/**' \
  --exclude='/tmp/**' --exclude='/run/**' \
  "${R}/" "${MNT}/"
sudo mkdir -p "$MNT/dev" "$MNT/proc" "$MNT/sys" "$MNT/tmp" "$MNT/run"

# fstab 用 UUID，不写死 /dev/sd*：UFS 的枚举顺序不保证。
# x-systemd.growfs 让 systemd 在挂载时就扩展；alioth-firstboot 里的
# resize2fs 是它的兜底（已经长满时那是个退出 0 的空操作），真正只属于
# alioth-firstboot 的是扩展成功之后的 successful 标记。
printf '%s\n' \
  "# SteamOS ARM (sm8250, Xiaomi alioth)：userdata 上一个 ext4 就是 /，" \
  "# /home 也在里面。没有 boot 分区 —— 内核在 boot_a/boot_b。" \
  "UUID=${root_uuid}  /  ext4  defaults,noatime,commit=30,x-systemd.growfs  0 1" \
  | sudo tee "$MNT/etc/fstab" >/dev/null
sudo mkdir -p "$MNT/var/lib/overlays/etc/upper"
sudo cp -a "$MNT/etc/fstab" "$MNT/var/lib/overlays/etc/upper/fstab"

sudo mkdir -p "$MNT/opt/steamos-alioth"
printf '%s\n' \
  "soc=sm8250" "device=Xiaomi Redmi K40 / POCO F3 (alioth)" \
  "kernel=${KREL}" "built=$(date -Iseconds)" \
  "root_uuid=${root_uuid}" "root=PARTLABEL=userdata" \
  "layout=ext4 userdata (root + home)，内核在 boot_a/boot_b" \
  | sudo tee "$MNT/opt/steamos-alioth/IMAGE.txt" >/dev/null

sync
cleanup_img
trap - EXIT
sudo e2fsck -fy "$raw" >/dev/null || true
sudo chown "$(id -u):$(id -g)" "$raw"

# 8. boot.img。和 boot-debug.img 同一个 cmdline：阶段 1 那条 cmdline 里
#    steamos.root=PARTLABEL=userdata 本来就指向这里，当时挂不上只是因为
#    那个分区还装着 Android 的加密 f2fs。usbshell 留着 —— 首次开机真出问题
#    时，它是唯一的观测通道（阶段 1 的教训）。
pack_boot boot.img

if command -v img2simg >/dev/null; then
  echo "==> sparse（img2simg）"
  img2simg "$raw" "${KIT}/userdata.img"
  rm -f "$raw"
else
  echo "==> 没有 img2simg，输出 raw userdata.img（fastboot 自己会转 sparse）"
  mv "$raw" "${KIT}/userdata.img"
fi

sums
echo
ls -lh "${KIT}"
echo
echo "刷机: ./flash-alioth.sh --install   （会擦掉 Android 的 /data）"
