#!/usr/bin/env bash
# 断言 flash-alioth.sh 的 --install 与 --test 遵守 spec §6.5 的写入规则。
#
# 全程用一个假的 fastboot（记录收到的参数，不碰任何设备）和一棵假的镜像
# 目录。这个脚本是本项目里唯一会写 flash 的代码，而写错一次的代价是
# EDL 9008 —— 所以规则必须被**检查**，不能只是被记住。
#
# 交互确认走 script(1) 分配的 pty：那道「必须来自交互终端」的闸是真实的
# 安全属性，不给它开测试后门。
#
# 照 scripts/assert-alioth-dtb.py 的样式：PASS/FAIL 加证据，结尾汇总，
# 任一失败退出非零。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLASH="${ROOT}/flash-alioth.sh"

fails=0
pass() { printf 'PASS  %s — %s\n' "$1" "$2"; }
fail() { printf 'FAIL  %s — %s\n' "$1" "$2"; fails=$((fails + 1)); }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
BIN="$T/bin"; mkdir -p "$BIN"

# 假 fastboot。每次调用把完整 argv 追加到 $FASTBOOT_LOG。
cat >"$BIN/fastboot" <<'FB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FASTBOOT_LOG"
case "$1" in
  devices) echo "0123abcd	fastboot" ;;
  getvar)
    case "$2" in
      product)      echo "product: alioth" >&2 ;;
      unlocked)     echo "unlocked: yes" >&2 ;;
      current-slot) echo "current-slot: ${FAKE_SLOT-a}" >&2 ;;
    esac ;;
esac
exit 0
FB
chmod +x "$BIN/fastboot"

# 假的「结构断言」。真脚本会对真镜像跑 assert-alioth-boot-image.sh；
# 这里的镜像是假的，所以用这个 seam 顶掉。被顶掉时真脚本必须大声说出来。
cat >"$BIN/true-assert" <<'TA'
#!/usr/bin/env bash
exit 0
TA
chmod +x "$BIN/true-assert"

# 假镜像目录。
WORKDIR="$T/work"; IMGD="$WORKDIR/steamos-alioth"; mkdir -p "$IMGD"
head -c 1024 /dev/zero >"$IMGD/boot.img"
head -c 1024 /dev/zero >"$IMGD/boot-debug.img"
head -c 4096 /dev/zero >"$IMGD/userdata.img"
( cd "$IMGD" && sha256sum boot.img boot-debug.img userdata.img >SHA256SUMS )
# 固件出处凭据。--install 要求看到它才肯写 userdata（见 flash-alioth.sh 的
# check_firmware_provenance）。基准用例要跑通，所以这里先写上；下面有专门的
# 用例把它拿掉和换成 GENERIC-FIRMWARE。
echo "fake" >"$IMGD/DEVICE-FIRMWARE"

# 跑一次 flash-alioth.sh。
#   $1 模式  $2 喂给确认提示的内容  $3 current-slot 的值
# 回显写进 $T/out，fastboot 调用写进 $T/fblog，返回退出码。
run() {
  : >"$T/fblog"
  printf '%s\n' "$2" |
    FASTBOOT_LOG="$T/fblog" FAKE_SLOT="$3" \
    PATH="$BIN:$PATH" STEAMOS_WORK="$WORKDIR" \
    ALIOTH_ASSERT_BOOT_IMAGE="$BIN/true-assert" \
    ALIOTH_FW_GENERIC_OK="${EXTRA_GENERIC_OK:-}" \
    script -qec "'$FLASH' $1" /dev/null >"$T/out" 2>&1
  local rc=$?
  tr -d '\r' <"$T/out" >"$T/out.clean" && mv "$T/out.clean" "$T/out"
  return $rc
}

if [[ ! -x "$FLASH" ]]; then
  fail "脚本存在" "没有可执行的 $FLASH"
  echo; echo "${fails} 条断言失败"; exit 1
fi

# --- 0. 基准：一次正常的 --install 必须真的跑完并真的写东西 -----------
# 没有这一条，下面「没出现被禁分区」之类的断言会因为脚本在用法检查处
# 就退出而**空过** —— 一个为了错误的理由而通过的测试比没有测试更坏。
run --install ERASE a
ok_rc=$?
ok_writes="$(grep -cE '^(flash|erase) ' "$T/fblog")"
if [[ $ok_rc -eq 0 && "$ok_writes" -gt 0 ]]; then
  pass "基准 --install" "退出 0，执行了 $ok_writes 次写操作"
else
  fail "基准 --install" "退出 $ok_rc，写操作 $ok_writes 次 —— 下面几条据此判定，否则会空过"
fi

# --- 1. 禁止分区 -------------------------------------------------------
# super 保留着（格掉 userdata 就能复活 Android），abl 是 bootloader，
# 写坏了只能走 EDL 9008。--install 的任何 fastboot 调用都不许提到它们。
banned=()
for p in super abl_a abl_b; do
  grep -qw "$p" "$T/fblog" && banned+=("$p")
done
if [[ "$ok_writes" -eq 0 ]]; then
  fail "禁止分区" "--install 一次都没写，这条无从判定（见「基准 --install」）"
elif [[ ${#banned[@]} -eq 0 ]]; then
  pass "禁止分区" "$ok_writes 次写操作里没有 super / abl_a / abl_b"
else
  fail "禁止分区" "出现了被禁分区: ${banned[*]}"
fi

# --- 2. 两槽都刷 boot（spec §6.5）-------------------------------------
# 只刷一个槽，bootloader 回退到另一槽时那里没有能启动的内核。
missing=()
grep -qE 'flash boot_a' "$T/fblog" || missing+=(boot_a)
grep -qE 'flash boot_b' "$T/fblog" || missing+=(boot_b)
[[ ${#missing[@]} -eq 0 ]] \
  && pass "两槽都刷 boot" "flash boot_a 与 flash boot_b 都在" \
  || fail "两槽都刷 boot" "缺少: ${missing[*]}"

# --- 3. --install 确实刷 userdata --------------------------------------
grep -qE 'flash userdata' "$T/fblog" \
  && pass "刷 userdata" "--install 写了 userdata" \
  || fail "刷 userdata" "--install 没有 flash userdata"

# --- 3b. 固件出处 ------------------------------------------------------
# 不可逆的那一步之前必须看到「固件取自这台手机」的凭据。
#
# 独立审查 2026-10-24 指出的不对称：boot 镜像的规则接线进了写入路径，而
# 「固件是机内签名版」只靠记性 —— make-steamos-alioth.sh 原来在没有
# ALIOTH_FW_DIR 时只打印四行警告然后继续，照样产出完整的 kit。于是：警告滚出
# 屏幕、十几分钟后刷机、输入 ERASE，**Android 的 /data 就此消失**，而装出来的
# 系统是黑屏加没声音（小米的 TrustZone 拒收 linux-firmware 的通用签名
# a650_zap.mbn），重新取固件得从一台 Android 已经被擦掉的手机上取。
#
# 要的是正面凭据，不是「没人反对」—— 否则这个检查存在之前构建的 kit、手工
# 拷过来的 kit，都会被当成好的。
mv "$IMGD/DEVICE-FIRMWARE" "$T/DEVICE-FIRMWARE.keep"
run --install ERASE a
rc=$?
wrote="$(grep -cE '^(flash|erase) ' "$T/fblog")"
if [[ $rc -ne 0 && "$wrote" -eq 0 ]]; then
  pass "固件出处：没凭据就拒" "没有 DEVICE-FIRMWARE 时退出 $rc，0 次写操作"
else
  fail "固件出处：没凭据就拒" "退出 $rc，写了 $wrote 次 —— 一个来历不明的 kit 能擦掉 userdata"
fi

echo "generic" >"$IMGD/GENERIC-FIRMWARE"
run --install ERASE a
rc=$?
wrote="$(grep -cE '^(flash|erase) ' "$T/fblog")"
if [[ $rc -ne 0 && "$wrote" -eq 0 ]]; then
  pass "固件出处：通用签名就拒" "有 GENERIC-FIRMWARE 时退出 $rc，0 次写操作"
else
  fail "固件出处：通用签名就拒" "退出 $rc，写了 $wrote 次 —— 明知黑屏的镜像照样刷进去了"
fi

# 逃生门要真的能用，否则下一个人会去改脚本而不是设这个变量。
EXTRA_GENERIC_OK=1 run --install ERASE a
rc=$?
wrote="$(grep -cE '^(flash|erase) ' "$T/fblog")"
if [[ $rc -eq 0 && "$wrote" -gt 0 ]]; then
  pass "固件出处：逃生门可用" "ALIOTH_FW_GENERIC_OK=1 时照常执行（$wrote 次写操作）"
else
  fail "固件出处：逃生门可用" "退出 $rc，写了 $wrote 次 —— 逃生门不通"
fi
rm -f "$IMGD/GENERIC-FIRMWARE"

# --test 不受这道闸约束：迭代内核的那条路径不写 userdata，拦它只是添麻烦。
run --test YES b
rc=$?
# 活动槽是 b，所以 --test 的目标槽是 a。
if grep -qE 'flash boot_a' "$T/fblog"; then
  pass "固件出处不拦 --test" "没有 DEVICE-FIRMWARE 时 --test 照常刷目标槽 boot_a"
else
  fail "固件出处不拦 --test" "退出 $rc —— 这道闸把内核迭代也拦了"
fi

mv "$T/DEVICE-FIRMWARE.keep" "$IMGD/DEVICE-FIRMWARE"

# --- 4. 确认字 ---------------------------------------------------------
# 没输入 ERASE 就不许有任何写操作。
run --install YES a
rc=$?
wrote="$(grep -cE '^(flash|erase) ' "$T/fblog")"
if [[ $rc -ne 0 && "$wrote" -eq 0 ]]; then
  pass "确认字" "没输入 ERASE 时退出 $rc，且 0 次写操作"
else
  fail "确认字" "退出 $rc，写操作 $wrote 次（应当退出非零且 0 次）"
fi

# --- 5. getvar 异常（Review Focus）------------------------------------
# 把异常输出当默认值继续，就是不可逆地写错分区。
for bogus in "" unknown; do
  run --install ERASE "$bogus"
  rc=$?
  wrote="$(grep -cE '^(flash|erase) ' "$T/fblog")"
  label="getvar 异常 current-slot='${bogus:-<空>}'"
  if [[ $rc -ne 0 && "$wrote" -eq 0 ]]; then
    pass "$label" "拒绝执行，退出 $rc，0 次写操作"
  else
    fail "$label" "退出 $rc，写操作 $wrote 次（应当退出非零且 0 次）"
  fi
done

# --- 6. 活动槽保护（--test）-------------------------------------------
# --test 只刷非活动槽。活动槽是 a 时写 a 就没有回退余地了。
# （--install 不受这条约束：spec §6.5 要求它两槽都刷，那时两边装的是
#  同一个 SteamOS，没有「另一边还留着 Android」可言。）
run --test YES a
rc=$?
if [[ $rc -ne 0 ]] && ! grep -qE 'flash boot_a' "$T/fblog"; then
  pass "活动槽保护" "活动槽为 a 时 --test 拒绝执行（退出 $rc），没有 flash boot_a"
else
  fail "活动槽保护" "活动槽为 a 时 --test 仍然执行了（退出 $rc）"
fi

# --- 6b. 「必须来自交互终端」只拦写入的那两个模式 ---------------------
# 那道闸的理由（源码注释里写着）是「the last gate in front of the only
# writes in the project」。--boot 是 `fastboot boot`，零写入、不改槽位 ——
# 对它来说那个理由不成立，而拦住它的代价是每次验证内核都要人去手敲一次
# YES。所以：--boot 接受管道喂进来的确认字，--test 与 --install 必须拒绝。
#
# 两个方向都测。只测「--boot 能过」的话，哪天有人把这道闸整个删了，
# 这条断言照样绿。
run_piped() {  # run_piped <模式> <确认字>：故意不给 pty
  : >"$T/fblog"
  printf '%s\n' "$2" |
    FASTBOOT_LOG="$T/fblog" FAKE_SLOT=a \
    PATH="$BIN:$PATH" STEAMOS_WORK="$WORKDIR" \
    ALIOTH_ASSERT_BOOT_IMAGE="$BIN/true-assert" \
    "$FLASH" "$1" >"$T/out" 2>&1
}

run_piped --boot YES
rc=$?
if [[ $rc -eq 0 ]] && grep -q '^boot ' "$T/fblog"; then
  pass "--boot 可非交互" "管道喂 YES 即可，调用了 fastboot boot"
else
  fail "--boot 可非交互" "退出 $rc，fblog: $(tr '\n' ';' <"$T/fblog" | head -c 80)"
fi

for m in --test --install; do
  word=YES; [[ "$m" == --install ]] && word=ERASE
  run_piped "$m" "$word"
  rc=$?
  wrote="$(grep -cE '^(flash|erase) ' "$T/fblog")"
  if [[ $rc -ne 0 && "$wrote" -eq 0 ]]; then
    pass "$m 仍需交互终端" "管道输入被拒，退出 $rc，0 次写操作"
  else
    fail "$m 仍需交互终端" "退出 $rc，写操作 $wrote 次（应当退出非零且 0 次）"
  fi
done

# --- 7. --test 代码路径里没有 userdata（物理隔离）---------------------
# 静态检查源码，不是检查某一次运行：spec §6.5 要求「物理隔离」，
# 使得迭代内核期间不可能手滑擦掉系统。区段由源码里的显式标记划定。
outside="$(awk '
  /INSTALL-ONLY REGION/ { inreg = !inreg; next }
  !inreg && /userdata/ { print NR ": " $0 }
' "$FLASH")"
if [[ -z "$outside" ]]; then
  pass "--test 隔离" "userdata 只出现在 INSTALL-ONLY 区段里"
else
  fail "--test 隔离" "区段外出现了 userdata —— $(echo "$outside" | head -2 | tr '\n' ' ')"
fi

echo
if ((fails)); then
  echo "${fails} 条断言失败"
  exit 1
fi
echo "全部断言通过"
