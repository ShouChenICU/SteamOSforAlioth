#!/usr/bin/env bash
# 断言 alioth-overlay/usr/lib/steamos-arm/alioth-write-boot 该拒绝的时候
# 真的一个字节都没写。
#
# 用法: sudo scripts/assert-alioth-writeboot.sh
#
# 为什么要 root：被测的东西是一个往块设备上 dd 的脚本，它自己要 root，
# 而且这组断言的全部价值在于「它拒绝的时候分区的字节没变」—— 那必须对着
# 真的块设备验，mock 一个 dd 出来的只能证明 mock 写对了。
#
# 为什么不危险：测试自己造一个 GPT 分区表的回环盘（两个 2 MiB 分区，名字
# 分别是 boot_a 和 bogus），再把 ALIOTH_BOOT_DEV_DIR 指到自己的目录。
# 被测脚本在整个过程里看不到 /dev/disk/by-partlabel，所以构建机上任何
# 真的 boot_a（这个仓库刷过不止一台设备，SD 卡上就有同名分区）都碰不到。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W="${ROOT}/alioth-overlay/usr/lib/steamos-arm/alioth-write-boot"
T="$(mktemp -d)"
LOOP=""

cleanup() {
  [[ -n "$LOOP" ]] && losetup -d "$LOOP" 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT

fails=0
pass() { printf 'PASS  %s — %s\n' "$1" "$2"; }
fail() { printf 'FAIL  %s — %s\n' "$1" "$2"; fails=$((fails + 1)); }

[[ $EUID -eq 0 ]] || { echo "要 root（它测的是往块设备 dd 这件事）" >&2; exit 1; }
[[ -x "$W" ]] || { echo "找不到 $W" >&2; exit 1; }

# --- 造回环盘 ---
truncate -s 16M "$T/disk.img"
sfdisk -q "$T/disk.img" >/dev/null <<'SFD'
label: gpt
start=2048, size=4096, name="boot_a"
start=6144, size=4096, name="bogus"
SFD
LOOP="$(losetup -P --show -f "$T/disk.img")"
# 等 udev 把分区处理完。等节点出现是不够的：lsblk 的 PARTLABEL 来自 udev
# 数据库，节点已经在了但属性还没写进去的那一小段时间里它返回空字符串,
# 而被测脚本的 PARTLABEL 检查会因此把一个好分区判成坏的。所以直接等那个
# 属性本身，而不是等节点。
udevadm settle 2>/dev/null
for _ in $(seq 100); do
  [[ "$(lsblk -no PARTLABEL "${LOOP}p1" 2>/dev/null | tr -d ' ')" == boot_a ]] && break
  sleep 0.1
done
[[ -b "${LOOP}p1" && -b "${LOOP}p2" ]] || { echo "回环分区没出现: ${LOOP}p1" >&2; exit 1; }
[[ "$(lsblk -no PARTLABEL "${LOOP}p1" | tr -d ' ')" == boot_a ]] \
  || { echo "回环盘的 PARTLABEL 不对，测不下去" >&2; exit 1; }

mkdir -p "$T/devdir"
ln -sfn "${LOOP}p1" "$T/devdir/boot_a"
# boot_b 故意指向那个叫 bogus 的分区：模拟 by-partlabel 下的软链被人动过
# 手脚。上面的参数检查全都看不出这件事，只有重新解析 PARTLABEL 才能。
ln -sfn "${LOOP}p2" "$T/devdir/boot_b"

PART="${LOOP}p1"
BOGUS="${LOOP}p2"
# 两个分区都先填上可识别的底色，这样「没写」和「写了」分得开。
dd if=/dev/zero bs=1M count=2 2>/dev/null | tr '\0' 'A' | dd of="$PART" bs=1M count=2 status=none
dd if=/dev/zero bs=1M count=2 2>/dev/null | tr '\0' 'B' | dd of="$BOGUS" bs=1M count=2 status=none
VIRGIN_A="$(dd if="$PART" bs=1M count=2 status=none | sha256sum | cut -d' ' -f1)"
VIRGIN_B="$(dd if="$BOGUS" bs=1M count=2 status=none | sha256sum | cut -d' ' -f1)"

# 一个合法的（就结构而言）boot 镜像：魔数 + 随机负载。
{ printf 'ANDROID!'; head -c $((512 * 1024 - 8)) /dev/urandom; } > "$T/good.img"
printf 'NOTANDRD' > "$T/bad.img"; head -c 1024 /dev/urandom >> "$T/bad.img"
: > "$T/empty.img"
{ printf 'ANDROID!'; head -c $((3 * 1024 * 1024)) /dev/urandom; } > "$T/huge.img"

run() {  # run <参数...>  —— 不给 tty，模拟脚本调用
  ALIOTH_BOOT_DEV_DIR="$T/devdir" "$W" "$@" </dev/null 2>&1
}
sha_a() { dd if="$PART" bs=1M count=2 status=none | sha256sum | cut -d' ' -f1; }
sha_b() { dd if="$BOGUS" bs=1M count=2 status=none | sha256sum | cut -d' ' -f1; }

refuses() {  # refuses <标签> <期望输出里有的字串> <参数...>
  local label="$1" want="$2"; shift 2
  local out rc
  out="$(run "$@")"; rc=$?
  if [[ $rc -eq 0 ]]; then
    fail "$label" "退出 0 —— 它接受了本该拒绝的输入"
  elif ! grep -q "$want" <<<"$out"; then
    fail "$label" "退出 $rc 但理由不对: ${out//$'\n'/ }"
  elif [[ "$(sha_a)" != "$VIRGIN_A" || "$(sha_b)" != "$VIRGIN_B" ]]; then
    fail "$label" "拒绝了，但分区的字节变了 —— 写在检查之前发生了"
  else
    pass "$label" "退出 $rc，两个分区都没动（${out##*: })"
  fi
}

# 1. 不是 boot 镜像。写错文件的后果是下次普通重启起不来。
refuses "拒绝非 boot 镜像" "ANDROID" "$T/bad.img" --slot _a --yes

# 2. 空文件。dd 一个空文件不会报错，而分区会原样留着上一版内核 ——
#    「写成功了但什么都没变」是最难认的一种。拦住它的是魔数那条（空文件的
#    前 8 个字节不是 ANDROID!），所以期望的理由是魔数而不是长度。
refuses "拒绝空镜像" "不是 'ANDROID!'" "$T/empty.img" --slot _a --yes

# 3. 比分区大。这里 3 MiB 对 2 MiB 的分区，PART_SIZE 那条全局上界拦不住，
#    只有 blockdev --getsize64 这条能拦。
refuses "拒绝超过分区大小的镜像" "超过" "$T/huge.img" --slot _a --yes

# 4. 槽位名不是 _a/_b。
refuses "拒绝非法槽位" "不是 _a 或 _b" "$T/good.img" --slot _c --yes
refuses "拒绝非法槽位（少下划线）" "不是 _a 或 _b" "$T/good.img" --slot a --yes

# 5. 软链指向的分区 PARTLABEL 不对。这条是唯一挡得住「by-partlabel 下的
#    名字被换掉」的检查 —— 换成指向 userdata 的话，前面每一条都会通过。
refuses "拒绝 PARTLABEL 不匹配的分区" "PARTLABEL" "$T/good.img" --slot _b --yes

# 6. 非交互又没给 --yes。无人值守地往 boot 分区写要显式说出口。
refuses "非交互必须显式 --yes" "显式加 --yes" "$T/good.img" --slot _a

# 7. 两个镜像参数。
refuses "只接受一个镜像" "只接受一个" "$T/good.img" "$T/bad.img" --slot _a --yes

# 8. 正常写入：成功、分区前段等于镜像、而且另一个分区没被碰过。
out="$(run "$T/good.img" --slot _a --yes)"; rc=$?
size=$(stat -c %s "$T/good.img")
on_disk="$(dd if="$PART" bs=1M count=1 status=none | head -c "$size" | sha256sum | cut -d' ' -f1)"
want="$(sha256sum "$T/good.img" | cut -d' ' -f1)"
if [[ $rc -ne 0 ]]; then
  fail "正常写入" "退出 $rc: ${out//$'\n'/ }"
elif [[ "$on_disk" != "$want" ]]; then
  fail "正常写入" "分区上的前 $size 字节和镜像不同"
elif [[ "$(sha_b)" != "$VIRGIN_B" ]]; then
  fail "正常写入" "另一个分区被动了"
elif ! grep -q "读回校验通过" <<<"$out"; then
  fail "正常写入" "没有读回校验那一步: ${out//$'\n'/ }"
else
  pass "正常写入" "写进 boot_a 并读回校验通过（sha ${want:0:12}），boot_b 未动"
fi

# 9. 默认槽位问的是 alioth-mark-slot-successful --print-active，而不是在
#    这里再抄一遍 GPT 解析。假一个只会印 _a 的出来，确认它真被调用。
printf '#!/bin/sh\necho _a\n' > "$T/fake-mark"; chmod +x "$T/fake-mark"
dd if=/dev/zero bs=1M count=2 2>/dev/null | tr '\0' 'A' | dd of="$PART" bs=1M count=2 status=none
out="$(ALIOTH_MARK_SLOT="$T/fake-mark" ALIOTH_BOOT_DEV_DIR="$T/devdir" \
       "$W" "$T/good.img" --yes </dev/null 2>&1)"; rc=$?
if [[ $rc -eq 0 ]] && grep -q "boot_a" <<<"$out"; then
  pass "默认写活动槽" "没给 --slot 时问 --print-active，写到了 boot_a"
else
  fail "默认写活动槽" "退出 $rc: ${out//$'\n'/ }"
fi

# 10. 问不出活动槽时必须停下，不许猜一个。
printf '#!/bin/sh\nexit 3\n' > "$T/fake-mark-fail"; chmod +x "$T/fake-mark-fail"
dd if=/dev/zero bs=1M count=2 2>/dev/null | tr '\0' 'A' | dd of="$PART" bs=1M count=2 status=none
VIRGIN_A="$(sha_a)"
out="$(ALIOTH_MARK_SLOT="$T/fake-mark-fail" ALIOTH_BOOT_DEV_DIR="$T/devdir" \
       "$W" "$T/good.img" --yes </dev/null 2>&1)"; rc=$?
if [[ $rc -ne 0 ]] && grep -q "问不出活动槽" <<<"$out" \
   && [[ "$(sha_a)" == "$VIRGIN_A" && "$(sha_b)" == "$VIRGIN_B" ]]; then
  pass "问不出活动槽就停下" "退出 $rc，两个分区都没动"
else
  fail "问不出活动槽就停下" "退出 $rc: ${out//$'\n'/ }"
fi

echo
echo "--- B. PC 侧驱动 scripts/alioth-selfflash-boot.sh ---"

SF="${ROOT}/scripts/alioth-selfflash-boot.sh"

# 11. 静态：它一个字节都不该碰别的分区，也不该自己调 fastboot。
#     它唯一的写入动作是让设备跑 alioth-write-boot，而那个脚本只认 boot_a/
#     boot_b。这条拦的是将来「顺手加一句刷 userdata」。
#
#     先把注释和字符串字面量剔干净再找 —— 和 assert-alioth-boot-image.sh
#     A 组同一个道理，而这里不剔就立刻踩到：救砖说明里的「进 fastboot，用
#     ./flash-alioth.sh 重刷」是**必须留着**的文本，而按行 grep 分不出它和
#     一条真的 fastboot 命令。
#
#     放在单独的文件里跑而不是 python3 -c '...'：那种写法里的引号要和外层
#     的单引号打架，而打架的后果是 python 报 SyntaxError、输出为空、于是
#     「没找到违规」—— 一条永远 PASS 的断言（实测踩过）。所以还要查它的
#     退出码。
#
#     剔的是「整条 echo/printf/die 语句」，不是「所有字符串字面量」。第一版
#     剔字面量，结果是一条 `"$SSH" "sudo -n dd ... of=.../userdata"` injected
#     进去照样通过 —— 这个脚本发给设备的命令**本来就**在引号里，剔掉引号
#     正好把唯一该查的地方删掉了。所以按语句的第一个词分：echo/printf/die
#     是给人看的文本，别的都是真要跑的东西，连它们的引号里一起查。
cat > "$T/nopart.py" <<'PY'
import re, sys

raw = open(sys.argv[1], encoding="utf-8").read().splitlines()
raw = [l for l in raw if not l.lstrip().startswith("#")]

# 把跨行的语句拼成一条逻辑行：双引号数目成双才算结束（die 的文本就跨两行）。
stmts, buf = [], ""
for l in raw:
    buf = l if not buf else buf + "\n" + l
    if buf.count('"') % 2 == 0:
        stmts.append(buf)
        buf = ""
if buf:
    stmts.append(buf)

bad = []
for st in stmts:
    # 剥掉开头的 || / && / ; —— 救砖说明挂在 `|| die "..."` 上，不剥的话
    # 第一个词是 "||"，那条文本会被当成真命令报出来。
    body = re.sub(r"^\s*(\|\||&&|;|\|)\s*", "", st.strip())
    first = body.split(None, 1)[0] if body.strip() else ""
    if first in ("echo", "printf", "die") or first.startswith(("echo", "printf")):
        continue            # 给人看的文本，救砖说明就在这里
    if re.search(r"\bsuper\b|abl_[ab]|userdata|\bfastboot\b", st):
        bad.append(" ".join(st.split()))
print("; ".join(bad))
PY
hits="$(python3 -I "$T/nopart.py" "$SF")"; prc=$?
if [[ $prc -ne 0 ]]; then
  fail "驱动不碰别的分区" "检查本身没跑起来（python 退出 $prc）"
elif [[ -z "$hits" ]]; then
  pass "驱动不碰别的分区" "剔掉注释和给人看的文本后，不出现 super/abl/userdata/fastboot"
else
  fail "驱动不碰别的分区" "$hits"
fi

# 12. 静态：结构断言不能有绕过的路。少了它，一个 cmdline 写错的镜像会被
#     直接送上设备，而症状是黑屏。
if grep -qE '^[^#]*assert-alioth-boot-image\.sh' "$SF" \
   && grep -qE '^[^#]*\|\|\s*die' <<<"$(grep -A2 -E '^[^#]*assert-alioth-boot-image\.sh' "$SF")"; then
  pass "驱动跑结构断言" "调了 assert-alioth-boot-image.sh，不过就 die"
else
  fail "驱动跑结构断言" "找不到「调结构断言且不过就 die」"
fi

# 13. 功能：传输途中坏了一个字节，必须停在比对那一步，而不是接着让设备写。
#     假一个 ssh 出来，它把 `cat >` 收到的东西存下来，但报一个别的 sha256。
cat > "$T/fake-ssh-corrupt" <<'FS'
#!/usr/bin/env bash
case "$1" in
  'cat > /tmp/alioth-boot.img') cat > "$FAKE_SSH_SPOOL/img"; exit 0 ;;
  'sha256sum /tmp/alioth-boot.img')
      echo "0000000000000000000000000000000000000000000000000000000000000000  /tmp/alioth-boot.img"
      exit 0 ;;
  *)  echo "$1" >> "$FAKE_SSH_SPOOL/cmds"; exit 0 ;;
esac
FS
cat > "$T/fake-ssh-ok" <<'FS'
#!/usr/bin/env bash
case "$1" in
  'cat > /tmp/alioth-boot.img')          cat > "$FAKE_SSH_SPOOL/img"; exit 0 ;;
  'cat > /tmp/alioth-modules.tar.gz')    cat > "$FAKE_SSH_SPOOL/mods"; exit 0 ;;
  'sha256sum /tmp/alioth-boot.img')      sha256sum "$FAKE_SSH_SPOOL/img"; exit 0 ;;
  'sha256sum /tmp/alioth-modules.tar.gz') sha256sum "$FAKE_SSH_SPOOL/mods"; exit 0 ;;
  *)  echo "$1" >> "$FAKE_SSH_SPOOL/cmds"; exit 0 ;;
esac
FS
chmod +x "$T/fake-ssh-corrupt" "$T/fake-ssh-ok"

REAL_IMG="${STEAMOS_WORK:-${ROOT}/work}/steamos-alioth/boot-debug.img"
if [[ ! -s "$REAL_IMG" ]]; then
  fail "传输坏了就不写" "没有 $REAL_IMG —— 先跑 ./make-steamos-alioth.sh --kernel-only"
  fail "正常流程调设备侧写入器" "同上"
  fail "模块默认一起送" "同上"
  fail "--no-modules 不送模块" "同上"
else
  mkdir -p "$T/spool"
  out="$(FAKE_SSH_SPOOL="$T/spool" ALIOTH_SSH="$T/fake-ssh-corrupt" \
         "$SF" "$REAL_IMG" --slot _a 2>&1)"; rc=$?
  if [[ $rc -ne 0 ]] && grep -q "传过去的不一样" <<<"$out" \
     && ! grep -q "alioth-write-boot" "$T/spool/cmds" 2>/dev/null; then
    pass "传输坏了就不写" "退出 $rc，没有调过设备侧写入器"
  else
    fail "传输坏了就不写" "退出 $rc；设备侧收到的命令: $(cat "$T/spool/cmds" 2>/dev/null)"
  fi

  # 14. 正常流程：内核和模块两样都送，而且送的字节和本地一致。
  rm -rf "$T/spool"; mkdir -p "$T/spool"
  out="$(FAKE_SSH_SPOOL="$T/spool" ALIOTH_SSH="$T/fake-ssh-ok" \
         "$SF" "$REAL_IMG" --slot _a 2>&1)"; rc=$?
  cmds="$(cat "$T/spool/cmds" 2>/dev/null)"
  if [[ $rc -eq 0 ]] \
     && grep -q "sudo -n /usr/lib/steamos-arm/alioth-write-boot /tmp/alioth-boot.img --slot _a --yes" <<<"$cmds" \
     && cmp -s "$REAL_IMG" "$T/spool/img"; then
    pass "正常流程调设备侧写入器" "送过去的字节和本地镜像相同，命令带 --slot _a --yes"
  else
    fail "正常流程调设备侧写入器" "退出 $rc；命令: ${cmds//$'\n'/ ; }"
  fi

  # 15. 模块默认一起送。少了这条，一个 `=m` 的改动会悄悄不生效 ——
  #     设备上的 .ko 还是旧的，而版本字符串一样所以什么都不报错。
  # grep -c 而不是 `| grep -q`：-q 一匹配就关掉管道，tar 吃 SIGPIPE，于是在
  # set -o pipefail 下整条管道以 141 退出 —— 归档明明是对的，断言却 FAIL
  # （实测踩过，和 alioth-write-boot 里读回校验那条是同一个坑）。-c 会把
  # 输入读完，不会提前关管道。
  nko="$(tar tzf "$T/spool/mods" 2>/dev/null | grep -c '\.ko')"
  if grep -q "sudo -n /usr/lib/steamos-arm/alioth-install-modules /tmp/alioth-modules.tar.gz --yes" <<<"$cmds" \
     && [[ -s "$T/spool/mods" ]] && [[ "${nko:-0}" -gt 0 ]]; then
    pass "模块默认一起送" "归档里 $nko 个 .ko，设备侧调了 alioth-install-modules"
  else
    fail "模块默认一起送" "没看到模块归档或安装命令；命令: ${cmds//$'\n'/ ; }"
  fi

  # 16. --no-modules 时一个模块字节都不送，而且说出来。
  rm -rf "$T/spool"; mkdir -p "$T/spool"
  out="$(FAKE_SSH_SPOOL="$T/spool" ALIOTH_SSH="$T/fake-ssh-ok" \
         "$SF" "$REAL_IMG" --slot _a --no-modules 2>&1)"; rc=$?
  cmds="$(cat "$T/spool/cmds" 2>/dev/null)"
  if [[ $rc -eq 0 ]] && [[ ! -e "$T/spool/mods" ]] \
     && ! grep -q "alioth-install-modules" <<<"$cmds" \
     && grep -q "no-modules" <<<"$out"; then
    pass "--no-modules 不送模块" "没有模块归档、没有安装命令，并且提示了后果"
  else
    fail "--no-modules 不送模块" "退出 $rc；命令: ${cmds//$'\n'/ ; }"
  fi
fi

echo
if (( fails )); then echo "${fails} 条断言失败"; exit 1; fi
echo "全部断言通过"
