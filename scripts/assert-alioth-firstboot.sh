#!/usr/bin/env bash
# 断言 alioth-firstboot 在首次开机时把根文件系统扩展到整个分区、标记 A/B
# successful，并且中断之后能重来。
#
# 在一个 loop 挂载的小 ext4 上真跑，不碰真设备、不碰真 userdata。需要 sudo
# （losetup / mount / resize2fs）。
#
# 最要紧的是第 3 条：掉电落在 resize2fs 中间时，绝不能把半扩展的文件系统
# 当成正常。哨兵文件在扩展**之前**就在、成功**之后**才删，所以任何中断都
# 必然落在「哨兵还在」的状态。
#
# 照 scripts/assert-alioth-dtb.py 的样式：PASS/FAIL 加证据，结尾汇总。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FB="${ROOT}/alioth-overlay/usr/lib/steamos-arm/alioth-firstboot"
UNIT="${ROOT}/alioth-overlay/usr/lib/systemd/system/alioth-firstboot.service"
SENTINEL_REL="var/lib/alioth-firstboot-pending"

DEV_BYTES=$((64 * 1024 * 1024))
FS_BLOCKS=16384          # 1 KiB 块 × 16384 = 16 MiB，远小于设备

fails=0
pass() { printf 'PASS  %s — %s\n' "$1" "$2"; }
fail() { printf 'FAIL  %s — %s\n' "$1" "$2"; fails=$((fails + 1)); }

T="$(mktemp -d)"
LOOP=""
cleanup() {
  mountpoint -q "$T/mnt" 2>/dev/null && sudo umount "$T/mnt"
  [[ -n "$LOOP" ]] && sudo losetup -d "$LOOP" 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT

BIN="$T/bin"; mkdir -p "$BIN" "$T/mnt"
cat >"$BIN/qbootctl" <<'QB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$QBOOTCTL_LOG"
exit 0
QB
chmod +x "$BIN/qbootctl"

# 造一个「分区比文件系统大」的局面，正是刷进 userdata 之后的样子。
make_fs() {
  mountpoint -q "$T/mnt" && sudo umount "$T/mnt"
  [[ -n "$LOOP" ]] && sudo losetup -d "$LOOP" 2>/dev/null
  rm -f "$T/disk.img"
  truncate -s "$DEV_BYTES" "$T/disk.img"
  LOOP="$(sudo losetup --find --show "$T/disk.img")"
  sudo mkfs.ext4 -q -F -b 1024 "$LOOP" "$FS_BLOCKS"
  sudo mount "$LOOP" "$T/mnt"
  sudo mkdir -p "$T/mnt/$(dirname "$SENTINEL_REL")"
  sudo touch "$T/mnt/$SENTINEL_REL"
}

fs_bytes() {
  local bs bc
  bs="$(sudo dumpe2fs -h "$LOOP" 2>/dev/null | awk -F: '/^Block size:/{gsub(/ /,"",$2);print $2}')"
  bc="$(sudo dumpe2fs -h "$LOOP" 2>/dev/null | awk -F: '/^Block count:/{gsub(/ /,"",$2);print $2}')"
  echo $((bs * bc))
}

run_fb() {  # run_fb [额外的 PATH 前缀]
  sudo env PATH="${1:+$1:}$BIN:$PATH" QBOOTCTL_LOG="$T/qb.log" \
    ALIOTH_FIRSTBOOT_ROOT="$T/mnt" "$FB"
}

if [[ ! -x "$FB" ]]; then
  fail "脚本存在" "没有可执行的 $FB"
  echo; echo "${fails} 条断言失败"; exit 1
fi

# --- 1. 扩展 -----------------------------------------------------------
make_fs
before="$(fs_bytes)"
: >"$T/qb.log"
run_fb >"$T/out1" 2>&1; rc=$?
after="$(fs_bytes)"
blk=1024
if [[ $rc -eq 0 ]] && (( after > before )) && (( DEV_BYTES - after < blk )); then
  pass "扩展" "$((before / 1024 / 1024)) MiB → $((after / 1024 / 1024)) MiB，占满 $((DEV_BYTES / 1024 / 1024)) MiB 分区"
else
  fail "扩展" "退出 $rc，$before → $after，分区 $DEV_BYTES: $(tail -2 "$T/out1" | tr '\n' ' ')"
fi

# --- 2. 标记 successful ------------------------------------------------
if [[ -s "$T/qb.log" ]]; then
  pass "标记 successful" "调用了 qbootctl: $(tr '\n' ';' <"$T/qb.log")"
else
  fail "标记 successful" "没有调用 qbootctl"
fi

# --- 3. 哨兵已清 -------------------------------------------------------
[[ ! -e "$T/mnt/$SENTINEL_REL" ]] \
  && pass "哨兵已清" "成功之后删掉了 $SENTINEL_REL" \
  || fail "哨兵已清" "$SENTINEL_REL 还在 —— 每次开机都会重跑"

# --- 3b. 没有 qbootctl 时走备用路径 ------------------------------------
#  Valve 的 rootfs 里就是没有 qbootctl（真机实测），所以这条分支才是真正会
#  跑的那条。两个方向都要测：成功要清哨兵，失败要保住哨兵 —— 后者更要紧，
#  标记失败却把哨兵删了，就等于永远不会再有人去标记它。
cat >"$T/mark-ok" <<'MK'
#!/usr/bin/env bash
printf 'marked\n' >>"$MARK_LOG"
exit 0
MK
cat >"$T/mark-fail" <<'MK'
#!/usr/bin/env bash
printf 'tried\n' >>"$MARK_LOG"
exit 1
MK
chmod +x "$T/mark-ok" "$T/mark-fail"

run_fb_nq() {  # run_fb_nq <mark 脚本>：PATH 里没有 qbootctl
  sudo env PATH=/usr/bin:/bin:/usr/sbin:/sbin MARK_LOG="$T/mark.log" \
    ALIOTH_MARK_SLOT="$1" ALIOTH_FIRSTBOOT_ROOT="$T/mnt" "$FB"
}

make_fs
: >"$T/mark.log"
run_fb_nq "$T/mark-ok" >"$T/out3b" 2>&1; rc3b=$?
if [[ $rc3b -eq 0 && -s "$T/mark.log" && ! -e "$T/mnt/$SENTINEL_REL" ]]; then
  pass "备用标记路径" "没有 qbootctl 时调了 alioth-mark-slot-successful，哨兵已清"
else
  fail "备用标记路径" "退出 $rc3b，mark.log $(wc -l <"$T/mark.log") 行，哨兵 $([[ -e "$T/mnt/$SENTINEL_REL" ]] && echo 在 || echo 没了)"
fi

make_fs
: >"$T/mark.log"
run_fb_nq "$T/mark-fail" >"$T/out3c" 2>&1; rc3c=$?
if [[ $rc3c -ne 0 && -e "$T/mnt/$SENTINEL_REL" ]]; then
  pass "备用标记失败时保住哨兵" "退出 $rc3c，$SENTINEL_REL 还在"
else
  fail "备用标记失败时保住哨兵" "退出 $rc3c，哨兵 $([[ -e "$T/mnt/$SENTINEL_REL" ]] && echo 在 || echo 没了)"
fi

# 后面几条还按「有 qbootctl」的那条路径跑，而第 4 条测的是「已经跑完一次
# 之后再跑」—— 所以这里先把状态恢复成「跑完了」。
make_fs
: >"$T/qb.log"
run_fb >/dev/null 2>&1

# --- 4. 幂等 -----------------------------------------------------------
: >"$T/qb.log"
run_fb >"$T/out2" 2>&1; rc2=$?
if [[ $rc2 -eq 0 && ! -s "$T/qb.log" ]]; then
  pass "幂等" "第二次退出 0，且没有再调 qbootctl"
else
  fail "幂等" "第二次退出 $rc2，qbootctl 调用 $(wc -l <"$T/qb.log") 次"
fi

# --- 5. 中断可恢复（Review Focus）-------------------------------------
# 在 resize2fs 正在跑的时候 SIGKILL 掉整个进程组，模拟掉电。
make_fs
small="$(fs_bytes)"
mkdir -p "$T/slow"
cat >"$T/slow/resize2fs" <<'SL'
#!/usr/bin/env bash
sleep 30
SL
chmod +x "$T/slow/resize2fs"
: >"$T/qb.log"
setsid sudo env PATH="$T/slow:$BIN:$PATH" QBOOTCTL_LOG="$T/qb.log" \
  ALIOTH_FIRSTBOOT_ROOT="$T/mnt" "$FB" >"$T/out3" 2>&1 &
fbpid=$!
for _ in $(seq 1 50); do
  pgrep -f "$T/slow/resize2fs" >/dev/null && break
  sleep 0.1
done
# 按 PID 杀，不用 pkill -f：那个模式会匹配到 pkill 自己的 sudo 命令行，
# 这个项目已经被它坑过三次。
for p in $(pgrep -f "$T/slow/resize2fs"); do sudo kill -9 "$p" 2>/dev/null; done
kill -9 -- "-$fbpid" 2>/dev/null; kill -9 "$fbpid" 2>/dev/null
wait "$fbpid" 2>/dev/null
killed_size="$(fs_bytes)"
if [[ -e "$T/mnt/$SENTINEL_REL" ]] && (( killed_size == small )) && [[ ! -s "$T/qb.log" ]]; then
  pass "中断时哨兵仍在" "被 SIGKILL 后 $SENTINEL_REL 还在，文件系统没变，也没标 successful"
else
  fail "中断时哨兵仍在" "哨兵 $([[ -e "$T/mnt/$SENTINEL_REL" ]] && echo 在 || echo 没了)，大小 $small→$killed_size，qbootctl $(wc -l <"$T/qb.log") 次"
fi

# 下次开机：用真的 resize2fs 重来，必须完成。
: >"$T/qb.log"
run_fb >"$T/out4" 2>&1; rc4=$?
retried="$(fs_bytes)"
if [[ $rc4 -eq 0 ]] && (( DEV_BYTES - retried < blk )) && [[ -s "$T/qb.log" ]] \
   && [[ ! -e "$T/mnt/$SENTINEL_REL" ]]; then
  pass "下次开机重试并完成" "$((small / 1024 / 1024)) MiB → $((retried / 1024 / 1024)) MiB，标记了 successful，哨兵已清"
else
  fail "下次开机重试并完成" "退出 $rc4，大小 $retried，qbootctl $(wc -l <"$T/qb.log") 次: $(tail -2 "$T/out4" | tr '\n' ' ')"
fi

# --- 6. systemd unit ---------------------------------------------------
if [[ -f "$UNIT" ]]; then
  u="$(cat "$UNIT")"
  miss=()
  grep -q "alioth-firstboot" <<<"$u" || miss+=(ExecStart)
  grep -qE 'ConditionPathExists=.*alioth-firstboot-pending' <<<"$u" || miss+=(ConditionPathExists)
  grep -qE 'WantedBy=' <<<"$u" || miss+=(WantedBy)
  [[ ${#miss[@]} -eq 0 ]] \
    && pass "systemd unit" "ExecStart / ConditionPathExists / WantedBy 齐全" \
    || fail "systemd unit" "缺少 ${miss[*]}"
else
  fail "systemd unit" "没有 $UNIT"
fi

echo
if ((fails)); then
  echo "${fails} 条断言失败"
  exit 1
fi
echo "全部断言通过"
