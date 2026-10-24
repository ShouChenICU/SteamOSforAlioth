#!/usr/bin/env bash
# 断言听音测试的两道闸还在。
#
# 这个脚本守的是一次真实硬件损伤的复发条件（docs/alioth.md「事故：把听筒
# 烧出了糊味」）。独立审查在 2026-10-24 指出原来那版的两处漏洞，各自都能让
# 事故原封不动地重演：
#
#   1. 时长查了 1..5 秒，**电平一个字都没查**。而 wpctl 接受大于 1.0 的值
#      （PipeWire 会加软增益），`alioth-speaker-test.sh 5 1.5` 就是把已经
#      0.25 满刻度的粉噪再推上去削波，五秒钟的削波宽带信号送进一个没有
#      限幅器的 D 类功放 —— 和当初 `-D hw:0,0` 到达的是同一个地方，只是
#      这次是**穿过** PipeWire 到的。脚本自己的拒绝话术（「想放更久，先解决
#      音圈测温」）说明作者知道真正危险的量是电平×时长，却只拦了时长。
#      而且那个值是不加引号拼进远端命令的。
#   2. 故障位检查**读不到寄存器时会「无故障」通过**。bad 初值 0，而解析不出
#      两个字段的行一律 continue —— 空输入、半截输入都 exit 0，于是操作者
#      被告知「功放没记下故障」，而事实是一个字节都没读到。和第 1 条凑在
#      一起是最坏的组合：电平没有上限，而故障报告不会失败。
#
# 不需要设备：故障解码被拆成 scripts/alioth-amp-faults.py，可以直接喂输入；
# 电平校验在碰 ssh 之前就退出。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST="${ROOT}/scripts/alioth-speaker-test.sh"
FAULTS="${ROOT}/scripts/alioth-amp-faults.py"

fails=0
pass() { printf 'PASS  %s — %s\n' "$1" "$2"; }
fail() { printf 'FAIL  %s — %s\n' "$1" "$2"; fails=$((fails + 1)); }

# --- 故障解码 ---------------------------------------------------------------

if [[ ! -x "$FAULTS" ]]; then
  fail "解码器存在" "没有可执行的 $FAULTS —— 解码还嵌在听音脚本里，喂不了输入"
  echo; echo "${fails} 条断言失败"; exit 1
fi

# 两颗都干净 -> 0
ok_in=$'3-0040 00000000\n3-0041 00000000\nbattery 380\n'
out="$(printf '%s' "$ok_in" | "$FAULTS" 2>&1)"; rc=$?
[[ $rc -eq 0 ]] \
  && pass "干净的输入通过" "两颗都没有故障位时退出 0" \
  || fail "干净的输入通过" "退出 $rc: ${out:0:200}"

# 任一故障位 -> 非零。逐位查，别只查一个。
#   6 BST_OVP / 7 BST_DCM_UVP / 8 BST_SHORT / 15 TEMP_WARN / 17 TEMP_ERR
#   / 31 AMP_SHORT
missed=()
for b in 6 7 8 15 17 31; do
  v="$(printf '%08x' $(( 1 << b )))"
  printf '3-0040 %s\n3-0041 00000000\n' "$v" | "$FAULTS" >/dev/null 2>&1 \
    && missed+=("bit$b")
done
[[ ${#missed[@]} -eq 0 ]] \
  && pass "每个故障位都报" "六位逐个置位，每次都退出非零" \
  || fail "每个故障位都报" "这几位被漏掉了: ${missed[*]}"

# PUP_DONE / PDN_DONE 不是故障。事故那天我正是把 bit 23 当成了可疑信号。
printf '3-0040 00c00000\n3-0041 00c00000\n' | "$FAULTS" >/dev/null 2>&1 \
  && pass "上下电完成位不算故障" "bit 22/23 置位仍然退出 0" \
  || fail "上下电完成位不算故障" "bit 22/23 被当成了故障"

# 这是审查发现的那条：读不到就必须失败，不能「无故障」通过。
vac=()
printf '' | "$FAULTS" >/dev/null 2>&1 && vac+=("空输入")
printf '3-0040 00000000\n' | "$FAULTS" >/dev/null 2>&1 && vac+=("只有一颗")
printf '3-0040 \n3-0041 \n' | "$FAULTS" >/dev/null 2>&1 && vac+=("值是空的")
printf '3-0040 zz\n3-0041 00000000\n' | "$FAULTS" >/dev/null 2>&1 && vac+=("值不是十六进制")
printf 'sudo: a password is required\n' | "$FAULTS" >/dev/null 2>&1 && vac+=("sudo 报错")
[[ ${#vac[@]} -eq 0 ]] \
  && pass "读不到就失败" "空/半截/不可解析的输入全部退出非零" \
  || fail "读不到就失败" "这些情况被当成了「无故障」: ${vac[*]} —— 操作者会以为功放是干净的"

# --- 电平与时长 -------------------------------------------------------------

# 用一个桩代替 alioth-ssh.sh。2026-10-24 这个脚本的第一版没有桩，直接拿真
# 设备跑这些用例 —— 于是 `电平 1.5` 那条**真的在设备上放了三秒**（事后读了
# 两颗的 IRQ1_STATUS1，只有 bit 22 PUP_DONE，没有故障位）。验护栏的测试自己
# 把护栏越过去了，这就是为什么现在有这个桩。
STUB="$(mktemp -d)"
trap 'rm -rf "$STUB"' EXIT
cat >"$STUB/ssh" <<'STUBEOF'
#!/usr/bin/env bash
# 吃掉 stdin（送生成器那一步会用），回一组干净的功放寄存器。
# 调用方必须给 </dev/null，否则 probe() 那两次没有管道的调用会把这里的 cat
# 挂在继承来的 stdin 上 —— 症状是整个断言脚本 timeout。
cat >/dev/null 2>&1 || true
printf '3-0040 00000000\n3-0041 00000000\nbattery 320\n'
STUBEOF
chmod +x "$STUB/ssh"

bad_args=()
try_reject() { # try_reject <说明> <参数...>
  local why="$1"; shift
  local o; o="$(ALIOTH_SSH="$STUB/ssh" timeout 20 "$TEST" "$@" 2>&1 </dev/null)"; local r=$?
  [[ $r -eq 2 ]] || bad_args+=("$why(退出 $r)")
}
try_reject "时长 0"        0
try_reject "时长 6"        6
try_reject "时长不是数字"  abc
try_reject "电平 1.5"      3 1.5
try_reject "电平 2"        3 2
try_reject "电平 -1"       3 -1
try_reject "电平不是数字"  3 loud
try_reject "电平里带命令"  3 '1.0; pw-play /x.wav'
try_reject "电平里带反引号" 3 '0.3`id`'
[[ ${#bad_args[@]} -eq 0 ]] \
  && pass "越界的时长和电平都被拒" "9 种写法全部以退出码 2 拒绝，没有碰设备" \
  || fail "越界的时长和电平都被拒" "这些被放过了: ${bad_args[*]}"

# 合法电平不该被拒。拦得太宽等于这个脚本没法用，于是下一个人绕过它。
bad_ok=()
for v in 0.1 0.35 0.5 1 1.0; do
  o="$(ALIOTH_SSH="$STUB/ssh" timeout 20 "$TEST" 1 "$v" 2>&1 </dev/null)"; r=$?
  [[ $r -eq 0 ]] || bad_ok+=("$v(退出 $r)")
done
[[ ${#bad_ok[@]} -eq 0 ]] \
  && pass "合法电平不被拒" "0.1/0.35/0.5/1/1.0 都走完了全程" \
  || fail "合法电平不被拒" "这些合法值没走通: ${bad_ok[*]}"

# 校验必须排在第一次用 $SSH 之前。退出码分不出「拒了」和「连不上」，而且
# 桩不会告诉你它有没有被调用 —— 静态查一次顺序。
first_check="$(grep -n 'exit 2' "$TEST" | head -1 | cut -d: -f1)"
first_ssh="$(grep -n '"\$SSH"' "$TEST" | head -1 | cut -d: -f1)"
if [[ -n "$first_check" && -n "$first_ssh" ]] && (( first_check < first_ssh )); then
  pass "校验在碰设备之前" "参数校验在第 ${first_check} 行，第一次用 ssh 在第 ${first_ssh} 行"
else
  fail "校验在碰设备之前" "exit 2 在 ${first_check:-无}，第一次 ssh 在 ${first_ssh:-无}"
fi

# 电平是拼进远端 shell 命令的，所以它必须被引号括住。
grep -qE "wpctl set-volume [^\"']*@DEFAULT_AUDIO_SINK@ '" "$TEST" \
  && pass "电平在远端被引号括住" "wpctl 的参数是单引号括起来的" \
  || fail "电平在远端被引号括住" "VOL 不加引号拼进远端命令 —— 一个分号就是任意命令"

# 放完要把系统音量放回去，否则这次测试的电平会留到 Game Mode 里。
grep -q 'ORIG_VOL\|恢复音量' "$TEST" \
  && pass "放完恢复系统音量" "脚本里有恢复音量的动作" \
  || fail "放完恢复系统音量" "改了 @DEFAULT_AUDIO_SINK@ 的音量却不放回去"

echo
if ((fails)); then
  echo "${fails} 条断言失败"
  exit 1
fi
echo "全部断言通过"
