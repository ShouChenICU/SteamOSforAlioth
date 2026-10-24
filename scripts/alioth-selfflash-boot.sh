#!/usr/bin/env bash
# 不碰手机地换一版内核：把 boot 镜像经 ssh 送上设备，让设备自己写进 boot 槽。
#
# 用法:
#   scripts/alioth-selfflash-boot.sh                       # 送 boot-debug.img + 模块
#   scripts/alioth-selfflash-boot.sh <镜像> [--slot _a|_b] [--reboot] [--no-modules]
#
# 默认连模块一起送。boot 镜像里只有内核和设备树，模块在 userdata 上，而这个
# 移植里一半的东西是 `=m`（snd-soc-sm8250、ath11k、pci-pwrctrl-pwrseq …）。
# 只换 boot 的后果是「改动在构建机的模块里，设备上加载的还是旧那份，而版本
# 字符串一样所以什么都不报错」—— 2026-10-24 就这么丢掉了一轮：machine driver
# 的补丁编进了 .ko，自刷了 boot，重启，一模一样的报错，而设备上那个 .ko 还是
# 几小时前的旧文件。内核镜像和它的模块是一件东西。
#
# 和 ./flash-alioth.sh 的区别只在「谁来写」：
#   flash-alioth.sh         设备在 fastboot 里，PC 用 fastboot 写。要人按住
#                           音量下 + 电源。
#   本脚本                  设备在正常运行的 SteamOS 里，设备自己用 dd 写。
#                           不用碰手机。
# 两者写的是同一个分区、同样的字节，所以 flash-alioth.sh 那套结构断言
#（scripts/assert-alioth-boot-image.sh 的 B 组）在这里一样要先过。
#
# 为什么这条路是安全的：写 boot 分区写坏了不会砖。退路和原来完全一样 ——
# 按住音量下 + 电源进 fastboot，再 ./flash-alioth.sh。这个脚本想省掉的恰好
# 就是那一步，所以它在下笔前把能在 PC 上查出来的全查一遍（结构断言、大小、
# 传输后的 sha256），而设备侧的 alioth-write-boot 还会再查一遍并读回比对。
#
# 前提：镜像是用 ALIOTH_SSH_PUBKEY=... 构建的。那个 opt-in 块同时装了公钥和
# 那条只放开 alioth-write-boot 的 sudoers 规则（见 make-steamos-alioth.sh）。
# 不是那样构建的系统上，这个脚本在 sudo 那一步会停住，而不会写坏什么。
set -uo pipefail

PORT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIT="${STEAMOS_WORK:-${PORT_ROOT}/work}/steamos-alioth"
# ALIOTH_SSH 只为了能测，真机上就是下面那个默认值。不留这个口子的话，
# 「传输坏了就不写」这条只能靠在真机上制造一次坏传输来验 —— 而那恰好是
# 最该在 PC 上就确定的一条。
SSH="${ALIOTH_SSH:-${PORT_ROOT}/scripts/alioth-ssh.sh}"
WRITER=/usr/lib/steamos-arm/alioth-write-boot
BOOT_PART_SIZE=$((0xC000000))

die() { echo "alioth-selfflash-boot: $*" >&2; exit 1; }

IMG=""; SLOT=""; REBOOT=0; MODULES=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --slot)       SLOT="$2"; shift ;;
    --reboot)     REBOOT=1 ;;
    --no-modules) MODULES=0 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    -*)       die "不认识的参数: $1" ;;
    *)        [[ -z "$IMG" ]] || die "只接受一个镜像"; IMG="$1" ;;
  esac
  shift
done

# 默认送 boot-debug.img：迭代内核的时候要的就是它（带 steamos.usbshell=1 和
# console=tty0，也就是出了问题还能看见、还能连进去的那一版）。
IMG="${IMG:-${KIT}/boot-debug.img}"
[[ -s "$IMG" ]] || die "没有 $IMG —— 先跑 ./make-steamos-alioth.sh --kernel-only"

# 1. 结构断言。这是 flash-alioth.sh 在写之前跑的同一套，针对同一个镜像 ——
#    页大小、载入地址、cmdline、只追加了 alioth 自己那一个 DTB。每一条对应
#    的失败在真机上都只表现为「黑屏」或「15 秒后弹回 fastboot」。
echo "==> 结构断言: $IMG"
ALIOTH_BOOT_IMAGE="$IMG" "${PORT_ROOT}/scripts/assert-alioth-boot-image.sh" \
  || die "结构断言没过 —— 不送。"

size=$(stat -c %s "$IMG")
(( size > 0 && size <= BOOT_PART_SIZE )) \
  || die "镜像 $size 字节，不在 (0, $BOOT_PART_SIZE] 内"
want="$(sha256sum "$IMG" | cut -d' ' -f1)"

# 2. 送过去。/tmp 在设备上是 tmpfs，镜像几十 MB，8 GB 内存放得下。
#    用 `cat >` 而不是 scp：scp 在这个镜像里不一定装了（Valve 的 rootfs 很瘦），
#    而 ssh 的管道是二进制安全的。
echo "==> 送 $((size / 1024 / 1024)) MiB 到设备 /tmp/alioth-boot.img"
"$SSH" 'cat > /tmp/alioth-boot.img' < "$IMG" || die "传输失败"

# 3. 在设备上比 sha256。传输途中坏掉的字节，到这里就现形；不比的话会一路
#    写进分区，然后表现为一次起不来的重启。
got="$("$SSH" 'sha256sum /tmp/alioth-boot.img' | cut -d' ' -f1)"
[[ "$got" == "$want" ]] \
  || die "传过去的不一样：本地 ${want:0:12}，设备上 ${got:0:12}"
echo "==> 传输校验通过（sha256 ${want:0:12}）"

# 4. 让设备自己写。真正的边界检查都在那边：只认 PARTLABEL 是 boot_a/boot_b
#    的块设备、写完读回来比 sha256。--yes 是因为这里没有 tty 能确认。
echo "==> 设备自己写 boot${SLOT:-（活动槽）}"
# shellcheck disable=SC2086
"$SSH" "sudo -n $WRITER /tmp/alioth-boot.img ${SLOT:+--slot $SLOT} --yes" \
  || die "设备侧写入失败 —— 上面的输出说了原因。看到「不要重启」就别重启，
     按住音量下 + 电源进 fastboot，用 ./flash-alioth.sh 重刷。"

"$SSH" 'rm -f /tmp/alioth-boot.img' >/dev/null 2>&1

# 5. 模块。放在 boot 之后：先把内核落到盘上，再换模块 —— 反过来的话，一次
#    在中间失败会留下「新模块 + 旧内核」，而那个组合里新模块可能加载不上。
if (( MODULES )); then
  ALIOTH_SSH="$SSH" "${PORT_ROOT}/scripts/alioth-push-modules.sh" \
    || die "模块没送上去。boot 已经写好了，但模块还是旧的 —— 别用这次的结果
     下结论，先解决上面的报错再重跑（重跑是安全的，两步都是幂等的）。"
else
  echo "!! --no-modules：只换了内核和设备树。任何 =m 的改动这次不会生效。"
fi

if (( REBOOT )); then
  echo "==> 重启设备"
  # sudo -n 而不是直接 systemctl reboot：steamos 的 ssh 会话没有本地 seat，
  # polkit 要交互认证（真机实测 "Call to Reboot failed: Interactive
  # authentication required."，而 systemctl 退出 0，看着像成功了）。
  # 那条 sudoers 规则把 `systemctl reboot` 一并放开了。
  # 连接会在重启时断掉，ssh 因此可能返回非零 —— 那是预期的，不是失败。
  "$SSH" 'sudo -n systemctl reboot' >/dev/null 2>&1 || true
  echo "已发出重启。起不来就按住音量下 + 电源进 fastboot，用 ./flash-alioth.sh 救。"
else
  echo "写好了。重启生效：scripts/alioth-ssh.sh 'sudo -n systemctl reboot'"
  echo "（或者下次加 --reboot。起不来的退路是音量下 + 电源进 fastboot + ./flash-alioth.sh）"
fi
