#!/usr/bin/env bash
# Put the phase-1 debug boot image on alioth (Xiaomi Redmi K40 / POCO F3).
#
# This is the only script in the port that writes to flash, so the rules it
# enforces are narrow on purpose:
#
#   * It writes slot a and nothing else. Slot a is the spare; the phone's
#     working Android is in slot b and this script never names it.
#   * Before writing, it refuses if slot a is the active slot -- writing it
#     would then overwrite the slot the phone starts from. The value is read
#     from the phone on every run.
#   * It checks it is talking to an alioth. Several other phones' flash
#     scripts live in this same tree and an sm8250 boot image in any of
#     their boot partitions is a day of someone's life.
#   * It touches two partitions: boot_a and dtbo_a. Nothing else, ever.
#   * It never marks a slot successful.
#   * It refuses to run unless scripts/assert-alioth-boot-image.sh passes,
#     so those rules are checked rather than remembered.
#
# Two modes:
#
#   --boot   Hand the image straight to the bootloader (fastboot boot).
#            Writes NOTHING and changes no slot.
#
#            Measured on this phone on 2026-10-23: this mode cannot tell
#            you anything. ABL answered `Booting OKAY` and then stayed in
#            its fastboot command loop -- the host saw no USB disconnect
#            for the three minutes that followed, and `getvar` kept
#            answering, so the bootloader never jumped. In the fastboot
#            protocol the OKAY for `boot` is sent BEFORE the jump, so it
#            is not evidence of anything. Whether ABL rejected this
#            image's header or does not implement the command at all,
#            the outcome here is the same: no result.
#
#            Consistent with that, `fastboot boot` appears nowhere in
#            pmaports-alioth; its install guide is erase dtbo / flash boot
#            / set_active / reboot. The flash path is the proven one.
#
#            The mode is kept because it writes nothing and costs one
#            second. Do not read a failure here as a verdict on the
#            kernel, and do not spend a second attempt on it.
#
#   --test   Write slot a and start from it.
#
# RECOVERY -- read this before running --test:
#
#   `fastboot --set-active=b` from fastboot is the way back, short of the
#   9008 EDL package. Hold volume-down + power to reach fastboot; that
#   works regardless of what is in the slot written here.
#
#   Go there directly. This bootloader does fall back by itself, but that
#   is not a recovery plan. Measured on this phone on 2026-10-23, with
#   nothing written to any partition: a stray `fastboot boot` crashed the
#   SoC, the boot attempts that followed failed, and the bootloader then
#   marked the active slot b unbootable and switched the active slot to a
#   on its own. `getvar all` afterwards read slot-unbootable:b:yes, and
#   slot-retry-count a:7 against b:4 -- it had been counting failures on b.
#
#   Two things that costs you. It spends boot attempts and lands on
#   whatever the other slot holds, which here was an Android that did not
#   start either: splash, black screen, repeat, for as long as you let it.
#   And it damages the flags of the slot it abandons -- getting back to a
#   working phone took `fastboot --set-active=b`, which is also what clears
#   slot-unbootable and resets the retry count. Watching the phone loop
#   buys nothing that command does not.
#
#   (The UART captures in pmaports-alioth log "A/B retry count NOT
#   decremented" on every boot, and this file previously cited that line to
#   claim the fallback did not exist here. The line is real; the conclusion
#   drawn from it was not.)
set -euo pipefail

PORT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMG_DIR="${STEAMOS_WORK:-${PORT_ROOT}/work}/steamos-alioth"
# ALIOTH_ASSERT_BOOT_IMAGE 是测试接缝，scripts/assert-alioth-flash.sh 用假镜像
# 跑这个脚本时顶掉结构断言。被顶掉时下面会大声打印出来 —— 它是刷机前的闸，
# 不能悄悄绕过。
ASSERT="${ALIOTH_ASSERT_BOOT_IMAGE:-${PORT_ROOT}/scripts/assert-alioth-boot-image.sh}"

# The slot this script is allowed to write, and the only one it will.
TARGET=a
# From this phone's own `fastboot getvar all`.
EXPECT_PRODUCT=alioth
BOOT_PART_SIZE=$((0xC000000))

die() { echo "flash-alioth: $*" >&2; exit 1; }

mode="${1:-}"
case "$mode" in
  --boot|--test|--install) ;;
  *) die "用法: $0 --boot | --test | --install   （先读脚本开头的说明，尤其是 RECOVERY）" ;;
esac

# --install 刷的是正式镜像，--boot/--test 刷的是阶段 1 的调试镜像。
if [[ "$mode" == --install ]]; then
  IMG="${IMG_DIR}/boot.img"
  CONFIRM_WORD=ERASE
else
  IMG="${IMG_DIR}/boot-debug.img"
  CONFIRM_WORD=YES
fi

# 1. Tools and image.
command -v fastboot >/dev/null || die "没有 fastboot"
[[ -s "$IMG" ]] || die "没有 $IMG —— 先跑 ./make-steamos-alioth.sh --kernel-only"

# 2. The image has to fit. Better to say so here than have the transfer
#    stop halfway through.
size=$(stat -c %s "$IMG")
(( size <= BOOT_PART_SIZE )) \
  || die "镜像 $size 字节，超过分区的 $BOOT_PART_SIZE 字节"

# 3. The structural gate. These assertions are the only thing standing
#    between a typo in the packer and a boot image this phone cannot start,
#    so they run here rather than being something to remember to run.
[[ -x "$ASSERT" ]] || die "没有 $ASSERT"
[[ -n "${ALIOTH_ASSERT_BOOT_IMAGE:-}" ]] \
  && echo "!! 结构断言被 ALIOTH_ASSERT_BOOT_IMAGE 顶成 $ASSERT —— 只应出现在测试里"
echo "=> $ASSERT"
ALIOTH_BOOT_IMAGE="$IMG" "$ASSERT" >"${IMG_DIR}/assert.log" 2>&1 || {
  tail -n 30 "${IMG_DIR}/assert.log" >&2
  die "断言不通过（完整输出在 ${IMG_DIR}/assert.log），不刷"
}
echo "   断言通过"

# 4. The checksum the packer wrote. This catches a truncated or corrupt
#    copy. It cannot catch a stale image -- the packer rewrites SHA256SUMS
#    on every build, so an old image and its own sums agree. Step 3 is what
#    covers staleness, by checking the image's actual contents.
[[ -s "${IMG_DIR}/SHA256SUMS" ]] || die "没有 ${IMG_DIR}/SHA256SUMS"
( cd "$IMG_DIR" && sha256sum -c --quiet SHA256SUMS ) || die "SHA256 校验不过"

# 5. The phone has to be in fastboot.
[[ -n "$(fastboot devices 2>/dev/null)" ]] || die "fastboot 看不到设备（手机要在 fastboot 模式）"

# Read one bootloader variable.
#
# Pure shell on purpose: no sed script built from the variable name, and no
# pipeline, so `set -o pipefail` has no SIGPIPE to turn into a silent exit.
# Two output shapes are accepted -- "name: value", which host fastboot
# prints for a single getvar, and "(bootloader) name:value", the raw INFO
# line this bootloader produces (that is the shape in this phone's own
# `getvar all` capture, with no space after the colon). A failure returns
# non-zero so the caller reports it instead of dying with no message.
getvar() {
  local name="$1" out line val
  out="$(fastboot getvar "$name" 2>&1)" || return 1
  while IFS= read -r line; do
    line="${line%$'\r'}"
    line="${line#"(bootloader) "}"
    case "$line" in
      "$name":*)
        val="${line#"$name":}"
        val="${val#"${val%%[![:space:]]*}"}"   # 去掉前导空白
        val="${val%"${val##*[![:space:]]}"}"   # 去掉尾随空白
        if [[ -n "$val" ]]; then printf '%s' "$val"; return 0; fi
        ;;
    esac
  done <<<"$out"
  return 1
}

# >>> INSTALL-ONLY REGION (spec §6.5 物理隔离) >>>
#
# 只有 --install 会走到这个区段。写 userdata 的代码、以及 slot b 的分区名，
# 都只许出现在这里 —— scripts/assert-alioth-boot-image.sh 按这两个标记切开
# 源码来检查这件事。spec §6.5 的「两个模式的代码路径物理隔离」就是这个意思：
# 迭代内核时走的是 --test，那条路径上根本不存在能擦掉系统的代码。
#
# 这个区段里**没有**标记槽位 successful 的动作。fastboot 也没有这种命令 ——
# 按 spec §6.3，那是系统起来之后由机上的 qbootctl 服务做的（Task 7 的
# alioth-firstboot）。先确认系统真的起来了，再停掉 bootloader 的自动回退。

# 不可逆的那一步之前，确认这个 kit 的固件是这台手机自己的。
#
# 2026-10-24 的独立审查指出的不对称：boot 镜像的规则接线进了写入路径
# （下面那个 assert-alioth-boot-image.sh 的闸），而「固件是机内签名版」只靠
# 记性 —— make-steamos-alioth.sh 原来在没有 ALIOTH_FW_DIR 时只打印警告然后
# 继续，照样产出完整的 kit。于是可能发生这件事：警告滚出屏幕、十几分钟后
# 跑这个脚本、输入 ERASE、**Android 的 /data 就此消失**，然后设备黑屏无声
# （小米的 TrustZone 拒收 linux-firmware 的通用签名 a650_zap.mbn），而重新
# 取固件要从一台 Android 已经被擦掉的手机上取。
#
# 要的是**正面**凭据：构建时写下的 DEVICE-FIRMWARE。不是「没有 GENERIC 标记
# 就放行」—— 那样在这个检查存在之前构建的 kit、手工拷过来的 kit，都会被当成
# 好的。不可逆的一步要有人签过字，不是没人反对。
check_firmware_provenance() {
  if [[ "${ALIOTH_FW_GENERIC_OK:-}" == 1 ]]; then
    echo "!! ALIOTH_FW_GENERIC_OK=1 —— 跳过固件出处检查。"
    echo "!! 如果这个 kit 用的是通用签名固件，装出来是黑屏加没声音。"
    return 0
  fi
  if [[ -f "${IMG_DIR}/GENERIC-FIRMWARE" ]]; then
    die "这个 kit 是用 linux-firmware 的通用签名固件构建的（见
     ${IMG_DIR}/GENERIC-FIRMWARE）。刷了它 Android 的 /data 没了，而装出来的
     系统是黑屏加没声音。先取机内固件重新构建：
       scripts/extract-alioth-firmware.sh <modem目录> <vendor目录> <产物目录>
       ALIOTH_FW_DIR=<产物目录> ./make-steamos-alioth.sh --install"
  fi
  [[ -f "${IMG_DIR}/DEVICE-FIRMWARE" ]] \
    || die "${IMG_DIR} 里没有 DEVICE-FIRMWARE —— 这个 kit 没有留下「固件取自
     这台手机」的凭据，所以不能确定它不是黑屏镜像。带 ALIOTH_FW_DIR 重跑一次
     ./make-steamos-alioth.sh --install 就会写上。
     明知它是通用签名固件、就是要刷：ALIOTH_FW_GENERIC_OK=1"
}

install_summary() {
  local u="${IMG_DIR}/userdata.img"
  [[ -s "$u" ]] || die "没有 $u —— 先跑 ./make-steamos-alioth.sh --install"
  check_firmware_provenance
  cat <<EOF
  rootfs  $u ($(stat -c %s "$u") 字节)
  动作    erase dtbo_a + dtbo_b
          flash boot_a + boot_b（两槽同一个镜像，spec §6.5）
          flash userdata   <-- 不可逆，Android 的 /data 就此消失
          --set-active=${active}（清掉可能残留的 unbootable 与重试计数）
  保留    Android 的系统分区不动 —— 格掉 userdata 就能把 Android 装回来
EOF
}

do_install() {
  local u="${IMG_DIR}/userdata.img"
  [[ -s "$u" ]] || die "没有 $u"

  # dtbo 先清空。留着有效的 overlay，bootloader 会把厂商板级树叠到我们的
  # 主线树上，然后失败；空分区它直接跳过（这台机器自己的 bootloader 日志
  # 里就是 "Dtbo hdr magic mismatch 0" 然后继续启动）。
  local sl
  for sl in a b; do
    echo "=> fastboot erase dtbo_${sl}"
    fastboot erase "dtbo_${sl}"
  done

  # 两槽刷同一个 boot（spec §6.5）。只刷一个槽的话，bootloader 一旦回退到
  # 另一槽，那里是阶段 1 的调试内核或者旧 Android，都起不来。
  for sl in a b; do
    echo "=> fastboot flash boot_${sl}"
    fastboot flash "boot_${sl}" "$IMG"
  done

  echo "=> fastboot flash userdata"
  fastboot flash userdata "$u"

  # 不改变活动槽，只是重新声明一次：这会清掉 slot-unbootable 和阶段 1
  # 测试期间花掉的重试计数。两个槽内容相同，刷哪个都一样。
  echo "=> fastboot --set-active=${active}"
  fastboot --set-active="${active}"

  echo "=> fastboot reboot"
  fastboot reboot
}
# <<< INSTALL-ONLY REGION <<<

# 6. The right phone. This tree also holds flash scripts for the REDMAGIC 6
#    and several other handhelds; any of them sitting in fastboot would pass
#    every other check here.
product="$(getvar product)" || die "读不到 product，不继续"
[[ "$product" == "$EXPECT_PRODUCT" ]] \
  || die "接的不是 $EXPECT_PRODUCT，而是 '$product' —— 拒绝执行"

# 7. An unlocked bootloader. A locked one rejects the image anyway, but it
#    is better to stop before changing which slot the phone starts from.
unlocked="$(getvar unlocked)" || die "读不到 unlocked，不继续"
[[ "$unlocked" == yes ]] || die "bootloader 没解锁（unlocked=$unlocked）"

# 8. Which slot the phone starts from. Read live: the value changes every
#    time anyone runs --set-active, including this script on its last run.
active="$(getvar current-slot)" || die "读不到 current-slot，不继续"
# 把异常输出当默认值继续，就是不可逆地写错分区。这台机器只有 a 和 b。
case "$active" in
  a|b) ;;
  *) die "current-slot 读到 '$active'，不是 a 或 b —— 拒绝执行" ;;
esac

# 9. The check this whole script exists for. Only --test writes, so only
#    --test is gated: --boot changes nothing and is exactly what you want
#    when slot a is already active.
if [[ "$mode" == --test && "$active" == "$TARGET" ]]; then
  cat >&2 <<EOF
flash-alioth: 拒绝执行。

  当前活动槽已经是 $TARGET，而这个脚本只写 $TARGET —— 现在写就是覆盖手机
  正在用来启动的那个槽，没有回退余地了。

  先切回去，再来：

      fastboot --set-active=b
      $0 $mode

  （或者用 $0 --boot，它不写任何东西，这种状态下照样能用。）
EOF
  exit 1
fi

cat <<EOF

  镜像    $IMG ($size 字节)
  设备    $product
  活动槽  $active
  模式    $mode
EOF
[[ "$mode" == --install ]] || echo "  目标槽  $TARGET   （活动槽 $active 不碰）"
case "$mode" in
  --boot) echo "  动作    直接交给 bootloader 启动，不写任何分区，不改槽位" ;;
  --test) echo "  动作    erase dtbo_${TARGET}; flash boot_${TARGET}; --set-active=${TARGET}" ;;
  --install) install_summary ;;
esac
if [[ "$mode" == --test ]]; then
  cat <<'EOF'

  退路：按住音量下 + 电源进 fastboot，执行 `fastboot --set-active=b`。
  这台手机的 bootloader 会自己回退（实测它把连续启动失败的槽标成
  unbootable、再把活动槽切到另一边），但别把它当退路：它会花掉启动
  尝试、落到另一个槽里的旧系统上，而且会把被它放弃的那个槽标成不可
  启动，最后仍然要靠上面那条命令清掉。直接进 fastboot 更快。
EOF
fi
echo

# A human has to be here for the modes that write. Without this,
# `echo YES | ./flash-alioth.sh --test` flashes unattended, and this prompt
# is the last gate in front of the only writes in the project.
#
# --boot is exempt, and only --boot: it is `fastboot boot`, which writes no
# partition and does not touch the slot flags. The tty requirement exists
# to guard writes, so applying it here buys nothing and costs a hand-typed
# YES on every kernel iteration -- the loop this project spends most of its
# time in. The confirmation word is still required, so a bare
# `./flash-alioth.sh --boot </dev/null` still refuses.
# scripts/assert-alioth-flash.sh 6b pins both halves: piped input works for
# --boot and is refused for --test and --install.
if [[ "$mode" != --boot ]]; then
  [[ -t 0 ]] || die "确认必须来自交互终端，不接受管道或重定向输入（--boot 例外，它零写入）"
fi
printf '输入大写 %s 继续: ' "$CONFIRM_WORD"
read -r confirm
[[ "$confirm" == "$CONFIRM_WORD" ]] || die "没有确认，退出"

if [[ "$mode" == --install ]]; then
  do_install
elif [[ "$mode" == --boot ]]; then
  echo "=> fastboot boot（零写入）"
  fastboot boot "$IMG"
else
  # Erase the overlays first. With a valid set there, the bootloader
  # overlays the vendor's board tree onto ours and that fails on a mainline
  # tree; with the partition empty it just skips them -- this phone's own
  # bootloader log shows it do exactly that ("Dtbo hdr magic mismatch 0"),
  # and then start.
  echo "=> fastboot erase dtbo_${TARGET}"
  fastboot erase "dtbo_${TARGET}"
  echo "=> fastboot flash boot_${TARGET}"
  fastboot flash "boot_${TARGET}" "$IMG"
  # No vbmeta write: this bootloader logs
  # "avb_slot_verify.c:577: ERROR: vbmeta_... OK_NOT_SIGNED", sets the boot
  # state to orange and starts anyway, so the kit's vbmeta step for other
  # phones would be a write with nothing to show for it. (The captured logs
  # only ever show the active slot's vbmeta being checked, never the one
  # written here -- but on an unlocked phone a mismatch is non-fatal either
  # way, which is what makes skipping it safe rather than lucky.)
  echo "=> fastboot --set-active=${TARGET}"
  fastboot --set-active="${TARGET}"
  # Deliberately no "mark successful". It would be a write we do not need,
  # and it would throw away the ability to tell a tested slot from an
  # untested one.
  echo "=> fastboot reboot"
  fastboot reboot
fi

cat <<'EOF'

现在看两条通道：

  屏幕    内核日志应该直接出现在面板上（simpledrm 接管 bootloader 的
          splash framebuffer，然后是真正的面板驱动）。
  USB     插到电脑上，应该多出两个 ttyACM 串口和一个网卡。
          ttyACM0 是内核控制台（cmdline 里的 console=ttyGS0），
          ttyACM1 是交互 shell；网卡上的 root shell 用
          scripts/alioth-shell.sh 进（不是 telnet —— 手机侧是 nc，
          而且 PC 侧的地址常被 NetworkManager 抹掉，脚本会补回）。

挂根会失败，这是预期的 —— 阶段 1 还没有 rootfs，init 会落到一个 shell。

大约 15 秒内直接弹回 fastboot = bootloader 拒绝了这个镜像，
不是内核的问题。
EOF
