#!/usr/bin/env bash
# alioth-game-tune 的断言。整套逻辑指到一棵假的 sysfs 上跑 —— 不在真机上
# 来回切调速器，理由和 assert-alioth-speaker-test.sh 用桩是同一条：
# 2026-10-24 那次，一个「验证护栏」的断言脚本自己走上了它要防的那条路。
#
# 这里每一条断言都对应一个会真的出事的情况：
#   - 没游戏却提频 -> 小核钉在 1.8 GHz 待机耗电，而且没有任何症状
#   - 有游戏却不提频 -> 就是它存在的全部理由
#   - Steam 客户端被当成游戏 -> 等于常开，同上
#   - 退出不恢复 -> 同上，而且是停服务之后还留着
#   - 碰亲和 -> 实测是负优化（36.79 vs 48.40 fps），绝不能偷偷加回来
set -uo pipefail

SP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TUNE="${ALIOTH_TUNE_BIN:-$SP/../alioth-overlay/usr/lib/steamos-arm/alioth-game-tune}"
UNIT="$SP/../alioth-overlay/usr/lib/systemd/system/alioth-game-tune.service"

fails=0
check() { # check <名字> <条件结果> <证据>
  if [[ "$2" == ok ]]; then
    printf 'PASS  %s\n' "$1"
  else
    printf 'FAIL  %s\n      %s\n' "$1" "$3"
    fails=$((fails + 1))
  fi
}

[[ -x "$TUNE" ]] || { echo "找不到可执行的 $TUNE"; exit 2; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

mkfake() { # mkfake -> 重建一棵干净的假 sysfs，CPU 三个 policy + 一个 GPU devfreq
  rm -rf "$T/sys" "$T/cg"
  local p
  for p in 0 4 7; do
    mkdir -p "$T/sys/cpufreq/policy$p"
    echo schedutil >"$T/sys/cpufreq/policy$p/scaling_governor"
  done
  mkdir -p "$T/sys/devfreq"
  echo simple_ondemand >"$T/sys/devfreq/governor"
  mkdir -p "$T/cg/user.slice/user-1000.slice/user@1000.service/app.slice"
  mkdir -p "$T/cg/user.slice/user-1000.slice/user@1000.service/session.slice"
}

govs() { cat "$T/sys/cpufreq"/policy*/scaling_governor | sort -u | tr '\n' ' '; }
gpugov() { cat "$T/sys/devfreq/governor"; }

run_once() {
  ALIOTH_TUNE_CGROUP_ROOT="$T/cg" \
  ALIOTH_TUNE_CPUFREQ="$T/sys/cpufreq" \
  ALIOTH_TUNE_DEVFREQ="$T/sys/devfreq" \
    "$TUNE" --once >/dev/null 2>&1
}

APP="$T/cg/user.slice/user-1000.slice/user@1000.service/app.slice"
SESS="$T/cg/user.slice/user-1000.slice/user@1000.service/session.slice"

# 1. 什么都没跑 -> 保持省电档
mkfake
run_once
check "没有游戏时不提频" \
  "$([[ "$(govs)" == "schedutil " && "$(gpugov)" == simple_ondemand ]] && echo ok)" \
  "cpu=$(govs) gpu=$(gpugov)"

# 2. Steam 客户端自己不算游戏。它在 session.slice/steam.service，而不是
#    app.slice 下的 scope —— 认错的话等于 performance 常开。
mkfake
mkdir -p "$SESS/steam.service" "$APP/steamos-manager.service" \
         "$APP/xdg-desktop-portal-gamescope.service"
run_once
check "Steam 客户端本身不触发提频" \
  "$([[ "$(govs)" == "schedutil " ]] && echo ok)" \
  "cpu=$(govs)"

# 3. 游戏 scope 出现 -> 提频
mkfake
mkdir -p "$APP/app-steam-app3020347378-24239.scope"
run_once
check "有游戏时 CPU 与 GPU 都切到 performance" \
  "$([[ "$(govs)" == "performance " && "$(gpugov)" == performance ]] && echo ok)" \
  "cpu=$(govs) gpu=$(gpugov)"

# 4. 游戏退出 -> 切回去
rm -rf "$APP/app-steam-app3020347378-24239.scope"
run_once
check "游戏退出后恢复省电档" \
  "$([[ "$(govs)" == "schedutil " && "$(gpugov)" == simple_ondemand ]] && echo ok)" \
  "cpu=$(govs) gpu=$(gpugov)"

# 5. 常驻模式收到 SIGTERM 要恢复。这条是最重要的一条：服务被停掉之后还留着
#    performance，没有任何界面会告诉你。
mkfake
mkdir -p "$APP/app-steam-app12345-1.scope"
ALIOTH_TUNE_CGROUP_ROOT="$T/cg" \
ALIOTH_TUNE_CPUFREQ="$T/sys/cpufreq" \
ALIOTH_TUNE_DEVFREQ="$T/sys/devfreq" \
ALIOTH_TUNE_INTERVAL=1 \
  "$TUNE" >"$T/daemon.log" 2>&1 &
daemon=$!
sleep 3
mid="$(govs)"
kill -TERM "$daemon" 2>/dev/null
wait "$daemon" 2>/dev/null
check "常驻模式：游戏在跑时确实提了频" \
  "$([[ "$mid" == "performance " ]] && echo ok)" "cpu=$mid"
check "常驻模式：SIGTERM 之后恢复省电档" \
  "$([[ "$(govs)" == "schedutil " && "$(gpugov)" == simple_ondemand ]] && echo ok)" \
  "cpu=$(govs) gpu=$(gpugov)"

# 6. GPU 节点不存在也不能崩 —— 换内核/换设备时这个路径是会变的，而 CPU
#    那半边仍然应该生效。
mkfake
rm -rf "$T/sys/devfreq"
mkdir -p "$APP/app-steam-app777-2.scope"
run_once
rc=$?
check "GPU 节点缺失时不崩，CPU 仍然生效" \
  "$([[ $rc -eq 0 && "$(govs)" == "performance " ]] && echo ok)" \
  "rc=$rc cpu=$(govs)"

# 7. 绝不碰 CPU 亲和。实测绑大核是负优化（见脚本头部的表），所以这不是
#    「还没做」，是「量过之后决定不做」。
check "脚本里没有任何设置 CPU 亲和的代码" \
  "$(grep -qE '(^|[^-[:alnum:]_])(taskset|sched_setaffinity|cpuset\.cpus|AllowedCPUs)' "$TUNE" \
     && echo no || echo ok)" \
  "$(grep -nE '(taskset|sched_setaffinity|cpuset\.cpus|AllowedCPUs)' "$TUNE" | head -3)"

# 8. unit 不能让 systemd 用 SIGKILL 收尾，否则第 5 条的恢复路径根本不会执行。
check "unit 用 SIGTERM 停止并留了停止超时" \
  "$(grep -q '^KillSignal=SIGTERM' "$UNIT" && grep -q '^TimeoutStopSec=' "$UNIT" \
     && echo ok)" \
  "$(grep -E 'KillSignal|TimeoutStopSec' "$UNIT" | tr '\n' ' ')"

# 9. unit 要真的被 enable（overlay 里那条 wants 符号链接）。
WANTS="$SP/../alioth-overlay/usr/lib/systemd/system/multi-user.target.wants/alioth-game-tune.service"
check "overlay 里有 multi-user.target.wants 的 enable 链接" \
  "$([[ -L "$WANTS" ]] && echo ok)" "$WANTS"

echo
if [[ $fails -eq 0 ]]; then echo "全部通过"; else echo "$fails 条失败"; fi
exit $(( fails > 0 ? 1 : 0 ))
