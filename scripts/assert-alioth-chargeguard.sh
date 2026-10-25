#!/usr/bin/env bash
# alioth-charge-guard 的断言。全部指到假的 sysfs 上跑 —— 不在真机上折腾
# 电池，理由和 assert-alioth-speaker-test.sh 用桩一样。
#
# 这个看门狗存在的前提是：DTS 把充电电流从 2A 提到了 3A，而
# qcom_pm8150b_charger 不实现 JEITA。所以下面每一条都对应一个「它失效了但
# 看不出来」的情况：
#   - 热了不降档            -> 提到 3A 的那层余量白花了
#   - 读不到温度当成不热    -> 和功放那次一模一样的错误（没读到 != 没故障）
#   - 退出不恢复            -> 充电永远慢，而且没人知道为什么
#   - 阈值写反              -> 越热充得越猛
set -uo pipefail

SP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="${ALIOTH_GUARD_BIN:-$SP/../alioth-overlay/usr/lib/steamos-arm/alioth-charge-guard}"
UNIT="$SP/../alioth-overlay/usr/lib/systemd/system/alioth-charge-guard.service"
DTS="$SP/../external-and-mods/kernel-sm8250/dts/sm8250-xiaomi-alioth.dts"

fails=0
check() {
  if [[ "$2" == ok ]]; then printf 'PASS  %s\n' "$1"
  else printf 'FAIL  %s\n      %s\n' "$1" "$3"; fails=$((fails + 1)); fi
}

[[ -x "$GUARD" ]] || { echo "找不到可执行的 $GUARD"; exit 2; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

mkfake() { # mkfake <电池温度 0.1C；给 "none" 则不建温度节点>
  rm -rf "$T/batt" "$T/chg"
  mkdir -p "$T/batt" "$T/chg"
  echo 3300000 >"$T/chg/current_max"
  [[ "$1" == none ]] || echo "$1" >"$T/batt/temp"
}

icl() { cat "$T/chg/current_max"; }

once() {
  ALIOTH_GUARD_BATT="$T/batt" ALIOTH_GUARD_CHG="$T/chg" \
    "$GUARD" --once >"$T/log" 2>&1
}

# 1..4 四个温度档
mkfake 330; once
check "常温（33.0°C）不限流" "$([[ "$(icl)" == 3300000 ]] && echo ok)" "icl=$(icl)"

mkfake 405; once
check "40.5°C 降到 1.5A" "$([[ "$(icl)" == 1500000 ]] && echo ok)" "icl=$(icl)"

mkfake 435; once
check "43.5°C 降到 1.0A" "$([[ "$(icl)" == 1000000 ]] && echo ok)" "icl=$(icl)"

mkfake 460; once
check "46.0°C 降到 0.5A" "$([[ "$(icl)" == 500000 ]] && echo ok)" "icl=$(icl)"

# 5. 读不到温度必须按最热档处理。「没读到」不等于「不热」。
mkfake none; once
check "温度节点缺失时按最热档处理" "$([[ "$(icl)" == 500000 ]] && echo ok)" \
  "icl=$(icl) log=$(tail -1 "$T/log")"

mkfake 330; echo "摄氏度很高" >"$T/batt/temp"; once
check "温度不是数字时按最热档处理" "$([[ "$(icl)" == 500000 ]] && echo ok)" "icl=$(icl)"

# 6. 迟滞：从热档回落，39.0°C 还在 HOT1(40.0) 与 RESTORE(38.0) 之间，
#    应当保持降档而不是立刻放开。
mkfake 405
ALIOTH_GUARD_BATT="$T/batt" ALIOTH_GUARD_CHG="$T/chg" ALIOTH_GUARD_INTERVAL=1 \
  "$GUARD" >"$T/dlog" 2>&1 &
d=$!
sleep 2
hot="$(icl)"
echo 390 >"$T/batt/temp"; sleep 3
mid="$(icl)"
echo 360 >"$T/batt/temp"; sleep 3
cool="$(icl)"
kill -TERM "$d" 2>/dev/null; wait "$d" 2>/dev/null
check "常驻模式：热了降档" "$([[ "$hot" == 1500000 ]] && echo ok)" "icl=$hot"
check "迟滞：39.0°C 不立刻恢复" "$([[ "$mid" == 1500000 ]] && echo ok)" "icl=$mid"
check "降到 36.0°C 之后恢复" "$([[ "$cool" == 3300000 ]] && echo ok)" "icl=$cool"

# 7. SIGTERM 之后必须恢复 —— 哪怕退出时还是热的。
mkfake 460
ALIOTH_GUARD_BATT="$T/batt" ALIOTH_GUARD_CHG="$T/chg" ALIOTH_GUARD_INTERVAL=1 \
  "$GUARD" >"$T/dlog2" 2>&1 &
d=$!
sleep 2
kill -TERM "$d" 2>/dev/null; wait "$d" 2>/dev/null
check "SIGTERM 之后把输入上限放回去" "$([[ "$(icl)" == 3300000 ]] && echo ok)" "icl=$(icl)"

# 8. 阈值必须单调递增、对应的限流必须单调递减。写反了就是「越热充得越猛」。
eval "$(grep -E '^(HOT|ICL)[0-9]=' "$GUARD" | sed 's/[";]//g; s/\${ALIOTH[^:]*:-//g; s/}//g' | tr -s ' ' '\n' | grep -E '^(HOT|ICL)[0-9]=')" 2>/dev/null || true
check "温度阈值单调递增" \
  "$([[ ${HOT1:-0} -lt ${HOT2:-0} && ${HOT2:-0} -lt ${HOT3:-0} ]] && echo ok)" \
  "HOT1=${HOT1:-?} HOT2=${HOT2:-?} HOT3=${HOT3:-?}"
check "限流值单调递减" \
  "$([[ ${ICL1:-0} -gt ${ICL2:-0} && ${ICL2:-0} -gt ${ICL3:-0} ]] && echo ok)" \
  "ICL1=${ICL1:-?} ICL2=${ICL2:-?} ICL3=${ICL3:-?}"

# 9. unit 不能被 SIGKILL 收尾，否则第 7 条的恢复路径不会执行。
check "unit 用 SIGTERM 停止并留了停止超时" \
  "$(grep -q '^KillSignal=SIGTERM' "$UNIT" && grep -q '^TimeoutStopSec=' "$UNIT" && echo ok)" \
  "$(grep -E 'KillSignal|TimeoutStopSec' "$UNIT" | tr '\n' ' ')"

WANTS="$SP/../alioth-overlay/usr/lib/systemd/system/multi-user.target.wants/alioth-charge-guard.service"
check "overlay 里有 enable 链接" "$([[ -L "$WANTS" ]] && echo ok)" "$WANTS"

# 10. 这个看门狗的存在理由挂在 DTS 的 3A 上。两者必须同时在，否则就是
#     「提了电流但没人看温度」或者「看门狗守着一个并不存在的改动」。
ua="$(grep -oE 'constant-charge-current-max-microamp = <[0-9]+>' "$DTS" | grep -oE '[0-9]+' | tail -1)"
check "DTS 的充电电流仍是看门狗假设的 3A" \
  "$([[ "$ua" == 3000000 ]] && echo ok)" \
  "constant-charge-current-max-microamp=$ua —— 改了它就要同时重新审视这个看门狗"

# 11. 浮充电压绝不能被顺手改动。决定过充风险的是电压，不是电流。
uv="$(grep -oE 'voltage-max-design-microvolt = <[0-9]+>' "$DTS" | grep -oE '[0-9]+' | tail -1)"
check "浮充电压仍是 4.45V" "$([[ "$uv" == 4450000 ]] && echo ok)" \
  "voltage-max-design-microvolt=$uv"

echo
if [[ $fails -eq 0 ]]; then echo "全部通过"; else echo "$fails 条失败"; fi
exit $(( fails > 0 ? 1 : 0 ))
