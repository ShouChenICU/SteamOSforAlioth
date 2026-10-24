#!/usr/bin/env bash
# 一次性采集阶段 2 验收所需的机上证据（spec §8）。
#
# 走 scripts/alioth-shell.sh 的 USB 网络 shell。目的是把十几条命令压成一条，
# 因为每次刷机都要重来一遍 —— 而「减少手动刷机次数」是本项目的硬要求。
#
# 只采集，不判定。能自动判的在输出里直接给结论，需要人眼的（横屏、触摸
# 登录、手柄图标、游戏跑通、浮层）留给操作者。
#
# 用法: scripts/alioth-phase2-evidence.sh [输出文件]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHELL_SH="${ROOT}/scripts/alioth-shell.sh"
OUT="${1:-${ROOT}/work/phase2-evidence-$(date +%Y%m%d-%H%M%S).txt}"

[[ -x "$SHELL_SH" ]] || { echo "没有 $SHELL_SH" >&2; exit 1; }

run() { "$SHELL_SH" -t 20 -c "$1" 2>&1; }

section() { printf '\n===== %s\n' "$1"; }

{
  echo "alioth 阶段 2 证据采集 $(date -Iseconds)"

  section "DT model / 内核"
  run 'cat /sys/firmware/devicetree/base/model; echo; uname -a'

  section "根文件系统是否已扩展（期望 ~106 GiB，不是几 GB）"
  run 'df -h / ; echo "--- 哨兵（不该还在）:"; ls -l /var/lib/alioth-firstboot-pending 2>&1'

  section "A/B successful 标记"
  run 'qbootctl -h 2>&1 | head -20; echo "--- 状态:"; qbootctl -c 2>&1; qbootctl 2>&1 | head'

  section "firstboot 服务日志"
  run 'systemctl status alioth-firstboot.service --no-pager 2>&1 | head -20; echo "---"; journalctl -u alioth-firstboot -b --no-pager 2>&1 | tail -20'

  section "关键模块是否加载（PCIe pwrctrl / WiFi / 蓝牙 / 音频）"
  run 'for m in pci_pwrctrl_pwrseq ath11k_pci ath11k bluetooth hci_uart btqca snd_soc_sm8250 snd_soc_cs35l41_i2c; do printf "%-24s %s\n" "$m" "$(grep -qw "^$m" /proc/modules && echo loaded || echo "-")"; done'

  section "WiFi"
  run 'ip -br link; echo "--- lspci:"; lspci 2>/dev/null | head; echo "--- dmesg:"; dmesg | grep -iE "ath11k|qca6390" | tail -15'

  section "蓝牙 BD_ADDR（Step 3：重启前后必须相同）"
  run 'hciconfig hci0 2>&1 | grep -i "BD Address"; echo "--- dmesg:"; dmesg | grep -iE "hci_uart|qca|Bluetooth" | tail -10'

  section "声卡与 UCM（Task 4 待核实：控件名）"
  run 'cat /proc/asound/cards 2>&1; echo "--- 控件:"; amixer -c 0 controls 2>&1 | head -40'

  section "UCM 是否真的被加载"
  run 'journalctl -b --no-pager 2>&1 | grep -iE "ucm|alsa-lib|pipewire.*card" | tail -20'

  section "输入设备 / InputPlumber"
  run 'cat /proc/bus/input/devices 2>&1 | grep -E "^N:|^P:"; echo "--- InputPlumber:"; systemctl status inputplumber --no-pager 2>&1 | head -12'

  section "gamescope / Game Mode"
  run 'systemctl --user status gamescope-session --no-pager 2>&1 | head -15; echo "--- 分辨率:"; cat /sys/class/drm/*/modes 2>/dev/null | head -5'

  section "电池与温度（spec §8：边充边玩 < 45°C）"
  run 'for f in /sys/class/power_supply/*/; do echo "== $f"; cat "$f/type" 2>/dev/null; cat "$f/capacity" 2>/dev/null; cat "$f/status" 2>/dev/null; cat "$f/temp" 2>/dev/null; done; echo "--- thermal:"; for z in /sys/class/thermal/thermal_zone*/; do printf "%s %s %s\n" "$(cat $z/type 2>/dev/null)" "$(cat $z/temp 2>/dev/null)" ""; done | sort -k2 -rn | head -10'

  section "启动期的报错"
  run 'journalctl -b -p err --no-pager 2>&1 | tail -30'

  echo
  echo "===== 需要人眼判定的（spec §8）"
  cat <<'HUMAN'
  □ 开机直接进 Game Mode，横屏，2400x1080
  □ 纯触摸能完成 Steam 登录（Steam 自带屏幕键盘）
  □ 蓝牙手柄配对后 Steam 识别为 Deck 手柄，按键图标正确
  □ 一个 Windows 独立游戏经 Proton 11 ARM64 跑通
  □ mangoapp 性能浮层能显示
  □ 音量上 = Steam 键，音量下 = 快捷菜单；电源键待机/唤醒
  □ s2idle 待机一夜掉电在可接受范围
  □ Game Mode 里能看到电量
HUMAN
} 2>&1 | tee "$OUT"

echo
echo "证据已存到 $OUT"
