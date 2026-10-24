#!/usr/bin/env bash
# 真机听音测试。存在的理由是一次事故：我用
#   speaker-test -D hw:0,0 -c 2 -t sine -f 440 -l 0
# 放了几分钟，用户闻到了烧糊味。那条命令错在三处，每一处单独都够糟：
#
#   1. `-D hw:0,0` 绕过 PipeWire，走的是功放的满刻度。UCM 里的增益是
#      「系统音量 100% 时的上限」，不是「测试音量」。
#   2. 正弦波的波峰因数是 1.41，粉噪约 4 —— 同样峰值电压下，正弦波送进音圈
#      的平均功率高得多，而音圈**没有任何温度传感器**。CS35L41 的 TEMP_WARN
#      保护的是芯片结温，不是扬声器。
#   3. `-l 0` 是无限循环。开了就去做别的事，没人盯着。
#
# 所以：只走 PipeWire、只用粉噪、时长硬上限 5 秒（由 timeout 兜底，不靠播放
# 器自己停）、放之前放之后各读一次功放中断状态，并把故障位解码出来。
#
# 2026-10-24 独立审查又补上两条，各自都能让事故原封不动重演：
#
#   4. 原来只查时长，**电平一个字都没查**。而 wpctl 接受大于 1.0 的值（当天
#      在设备上实测：`set-volume 1.5` 读回来就是 1.50），PipeWire 会老老实实
#      加上那段软增益 —— `alioth-speaker-test.sh 5 1.5` 是把已经 0.25 满刻度
#      的粉噪推上去削波，五秒削波宽带信号送进一个没有限幅器的 D 类功放。
#      和当初 `-D hw:0,0` 到达的是同一个地方，只是这次**穿过** PipeWire。
#      真正危险的量是电平×时长，所以两个都得拦。电平硬上限 1.0。
#   5. 故障解码原来嵌在这里的一个 heredoc 里，没法喂输入，于是它的失败模式
#      一直没人验过 —— 空输入、半截输入、`sudo: a password is required`，
#      一律退出 0，也就是「没有故障位」。已拆成 scripts/alioth-amp-faults.py，
#      两颗功放的寄存器缺一个就退出非零。
#      scripts/assert-alioth-speaker-test.sh 把这些情况逐个喂进去。
#
# 还有一个坑，表现和「扬声器坏了」一模一样：Frame 镜像带一套 Valve 的
# PipeWire 权限管理器（/etc/wireplumber/wireplumber.conf.d/10-access.conf）。
# access = "default" 的客户端只要不在白名单里，链接就会被拒：
#
#   link-factory: can't link ports 67 and 34: Operation not permitted
#
# 白名单是 pipewire / org.valvesoftware.steam / org.kde.plasma-pa /
# SteamVR Audio / pavucontrol。speaker-test 和 pw-play 都不在里面 —— 流进了
# 图、sink 也在、路由也开着，但一个 Link 对象都建不出来，声卡从头到尾没有被
# 打开过。所以下面用 PIPEWIRE_PROPS 把自己报成白名单里的应用。
set -uo pipefail

SECS="${1:-3}"
VOL="${2:-0.35}"
SP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# ALIOTH_SSH 可覆盖，这样 scripts/assert-alioth-speaker-test.sh 能用一个桩去
# 验参数校验，而不必（像 2026-10-24 那次一样）真的往设备上放一遍音。
SSH="${ALIOTH_SSH:-$SP/alioth-ssh.sh}"
FAULTS="$SP/alioth-amp-faults.py"

if ! [[ "$SECS" =~ ^[0-9]+$ ]] || (( SECS < 1 || SECS > 5 )); then
  echo "时长必须是 1..5 秒（给的是 '$SECS'）。想放更久，先解决音圈测温，别改这里。" >&2
  exit 2
fi

# 电平和时长是同一道闸的两半。上限 1.0 不是「PipeWire 的最大值」—— wpctl
# 接受 1.5、2.0，PipeWire 会照着加软增益，那条路通向的就是削波后的满刻度。
# 先用正则把它限成「数字和一个小数点」，这样它拼进远端命令里也不可能是别的
# 东西；再用 awk 比大小（bash 不做浮点）。
if ! [[ "$VOL" =~ ^[0-9]+(\.[0-9]+)?$ ]] \
   || ! awk -v v="$VOL" 'BEGIN { exit !(v > 0 && v <= 1.0) }'; then
  echo "电平必须是 0 到 1.0 之间的小数（给的是 '$VOL'）。" >&2
  echo "大于 1.0 的值 PipeWire 会当成软增益加上去 —— 那是削波，不是「大声一点」。" >&2
  exit 2
fi

# 功放中断位，来自 include/sound/cs35l41.h。bit 22/23 是 PUP_DONE / PDN_DONE，
# 是正常的上下电完成标志，不是故障 —— 事故那天我正是把 bit 23 的出现当成了
# 可疑信号，而真正的六个故障位一个都没亮。
probe() { # probe <标签> ; 把 "<i2c 地址> <IRQ1_STATUS1>" 打到 stdout
  echo "--- $1 ---" >&2
  "$SSH" '
    for r in 3-0040 3-0041; do
      printf "%s %s\n" "$r" "$(sudo sed -n "s/^0*10010: *//p" \
        /sys/kernel/debug/regmap/$r/registers)"
    done
    printf "battery %s\n" "$(cat /sys/class/power_supply/battery/temp)"
  '
}

report() { # 从 stdin 读 probe 的输出，解码并在有故障**或读不到**时返回非零
  "$FAULTS"
}

echo "==> 粉噪 ${SECS}s，音量 ${VOL}，经 PipeWire"
probe "放之前" | report || { echo "放之前就有故障位 —— 先查那个。" >&2; exit 1; }

# 不用 speaker-test：它只会开 ALSA 设备，而 -D 一旦写成 hw:* 就绕过了所有
# 音量。粉噪现场生成成 WAV，用 pw-play 经 PipeWire 放。
# timeout --signal=KILL 是硬上限：播放器卡住也会被杀掉。
GEN=$(cat <<'GENPY'
import random, struct, sys, wave
secs = int(sys.argv[1])
rate = 48000
# Voss-McCartney。粉噪的波峰因数约 4，正弦波是 1.41 —— 同样峰值电压下送进
# 音圈的平均功率差一个量级，而音圈没有温度传感器。
rows = [0.0] * 16
w = wave.open(sys.stdout.buffer, "wb")
w.setnchannels(2); w.setsampwidth(2); w.setframerate(rate)
buf = bytearray()
for n in range(rate * secs):
    k = (n ^ (n - 1)) if n else 1
    for i in range(16):
        if k >> i & 1:
            rows[i] = random.uniform(-1.0, 1.0)
    # 0.25 = 峰值留 12 dB 余量。真正到喇叭上的电平还要叠上 UCM 那两档增益。
    v = int(sum(rows) / 16 * 0.25 * 32767)
    buf += struct.pack("<hh", v, v)
w.writeframes(bytes(buf)); w.close()
GENPY
)

printf '%s\n' "$GEN" | "$SSH" 'cat > /tmp/alioth-gen.py'

"$SSH" "
  python3 -I /tmp/alioth-gen.py ${SECS} > /tmp/alioth-pink.wav
  # 测完要把系统音量放回去，否则这次测试的电平会留在 Game Mode 里 ——
  # 下一次有人点开游戏，听到的是这里设的值。
  ORIG_VOL=\$(wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null | awk '{print \$2}')
  wpctl set-volume @DEFAULT_AUDIO_SINK@ '${VOL}' >/dev/null 2>&1
  PIPEWIRE_PROPS='{ application.id = org.kde.plasma-pa }' \\
    timeout --signal=KILL $((SECS + 3)) pw-play /tmp/alioth-pink.wav \\
    >/dev/null 2>&1
  [ -n "\$ORIG_VOL" ] && wpctl set-volume @DEFAULT_AUDIO_SINK@ "\$ORIG_VOL" >/dev/null 2>&1
  rm -f /tmp/alioth-pink.wav /tmp/alioth-gen.py
  true
"

if probe "放之后" | report; then
  echo
  echo "没有故障位。"
else
  echo
  echo "功放记下了故障位 —— 不要继续放，先查上面那几项。" >&2
  exit 1
fi
