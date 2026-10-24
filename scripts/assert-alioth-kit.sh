#!/usr/bin/env bash
# 断言 make-steamos-alioth.sh 产出的 kit 能刷、能起、能长大。
#
# 分两组：
#   A. 不需要 kit —— 用法、--kernel-only 没有回归。永远能跑。
#   B. 需要 ${STEAMOS_KIT}/userdata.img —— 先跑 ./make-steamos-alioth.sh --install。
#      要挂载镜像，需要 sudo。
#
# 照 scripts/assert-alioth-dtb.py 的样式：PASS/FAIL 加证据，结尾汇总。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAKE="${ROOT}/make-steamos-alioth.sh"
WORKDIR="${STEAMOS_WORK:-${ROOT}/work}"
# make-steamos-alioth.sh 里 OUT 就是这个，没有单独的 STEAMOS_KIT ——
# 两边必须用同一个式子，否则 A 组构建的和 B 组检查的不是同一个目录。
KIT="${WORKDIR}/steamos-alioth"

# userdata 分区 106.3 GiB（spec §6.1，sda35）。取 106 GiB 作保守下界。
PART_BYTES=$((106 * 1024 * 1024 * 1024))

# 阶段 1 实测缺过的固件。缺了之后的症状都离原因很远：没有 a650_sqe.fw
# 是「GPU 不动」，没有 amss.bin 是「有网卡没有网」。
WANT_FW=(
  "qcom/a650_sqe.fw"
  "qcom/a650_gmu.bin"
  "qcom/sm8250/a650_zap.mbn"
  "ath11k/QCA6390/hw2.0/amss.bin"
  "ath11k/QCA6390/hw2.0/m3.bin"
  "ath11k/QCA6390/hw2.0/board-2.bin"
  "qca/htbtfw20.tlv"
  "qca/htnv20.bin"
)

fails=0
pass() { printf 'PASS  %s — %s\n' "$1" "$2"; }
fail() { printf 'FAIL  %s — %s\n' "$1" "$2"; fails=$((fails + 1)); }

echo "--- A. 不需要 kit ---"

# 1. 不带参数仍打印用法并退出非零。阶段 1 就是这个行为，不许回归。
out="$("$MAKE" 2>&1)"; rc=$?
if [[ $rc -ne 0 ]] && grep -q '用法' <<<"$out"; then
  pass "用法" "不带参数退出 $rc 并打印用法"
else
  fail "用法" "退出 $rc，输出: ${out:0:120}"
fi

# 1b. ssh 公钥必须是显式选择进来的，不能默认就装。--install 产出的是一台
#     联网设备的根文件系统；镜像里躺着一把别人的公钥、sshd 还默认开着，
#     就是个后门。所以装公钥这件事只在 ALIOTH_SSH_PUBKEY 被显式设置时发生，
#     而且这条断言是静态查脚本本身 —— 跑一次完整 --install 才能发现这种事
#     就太晚了。
# 装公钥、开 sshd、放开 sudoers 的每一行，都必须落在
# `if ... ALIOTH_SSH_PUBKEY ...` 这个块里面（块外一行都不许有）。
#
# sudoers 也在这张名单上，理由和公钥一样：alioth-write-boot 要 root 才能写
# boot 分区，而放开它的那条规则一旦装进默认镜像，就等于默认镜像里躺着一条
# 「任何能登进来的人都能改下次开机的内核」。公钥和这条规则必须同生同死 ——
# 没有公钥就没人登得进来，这条规则也就不该存在。
counts="$(awk '
  /^if .*ALIOTH_SSH_PUBKEY/ { inblk = 1 }
  inblk && /^fi$/           { inblk = 0; next }
  /authorized_keys|sshd\.(service|socket)|sudoers/ { if (inblk) i++; else o++ }
  END { print i + 0, o + 0 }
' "$MAKE")"
read -r n_in n_out <<<"$counts"
if [[ "$n_out" -eq 0 && "$n_in" -gt 0 ]]; then
  pass "ssh 公钥与 sudoers 默认不装" "$n_in 行 authorized_keys/sshd/sudoers 全在 ALIOTH_SSH_PUBKEY 块内，块外 0 行"
elif [[ "$n_out" -eq 0 && "$n_in" -eq 0 ]]; then
  fail "ssh 公钥与 sudoers 默认不装" "脚本里根本没有装公钥这件事（期望有，但被 ALIOTH_SSH_PUBKEY 守卫）"
else
  fail "ssh 公钥与 sudoers 默认不装" "ALIOTH_SSH_PUBKEY 块外还有 $n_out 行在动 authorized_keys/sshd/sudoers"
fi

# 1b-2. 那三行 sudoers 必须是合法的 sudoers 语法。sudoers.d 里任何一个文件
#     有语法错，sudo 就**整体**罢工（"syntax error ... sudo: parse error in
#     /etc/sudoers.d/zz-alioth-write-boot"），而不是只忽略坏的那条 —— 于是
#     正式系统里 steamos 连 `sudo true` 都跑不了，自刷和重启一起断掉，而
#     这台机器上没有别的拿 root 的途径（Game Mode 没有终端）。
#     内容是 printf 拼出来的字面量，所以这条查得起静态：把它们抠出来喂给
#     visudo -c。真机上装完也查过一次（visudo -c -q 过）。
GRANT_LINES="$(mktemp)"
sed -n "s/^[[:space:]]*'\(steamos ALL=.*\)'[[:space:]]*\\\\\?$/\1/p" "$MAKE" >"$GRANT_LINES"
n_grant="$(wc -l <"$GRANT_LINES")"
if (( n_grant == 0 )); then
  fail "sudoers 语法" "从 $MAKE 里抠不出 'steamos ALL=…' 行 —— 要么规则没了，要么写法变了，这条断言失去作用"
elif visudo -c -q -f "$GRANT_LINES" >/dev/null 2>&1; then
  pass "sudoers 语法" "$n_grant 行规则 visudo -c 通过"
else
  fail "sudoers 语法" "visudo -c 拒绝了这 $n_grant 行 —— 装进镜像会让 sudo 整体罢工: $(visudo -c -f "$GRANT_LINES" 2>&1 | head -2 | tr '\n' ' ')"
fi
rm -f "$GRANT_LINES"

# 1b-3. 那个文件还必须进 /etc 的 overlayfs upperdir。SteamOS 的 /etc 是
#     overlayfs 且挂得很晚，只写下层的话开机后这条规则**不存在** —— 症状是
#     「sudo 要密码」，和「名字排序不对被 wheel 覆盖」（2026-10-24 踩过）
#     长得一模一样，而两者的修法完全不同。
#     scripts/assert-alioth-overlay-applied.sh 的第 2 条给 alioth-overlay
#     下的文件守了这件事，但 sudoers 不在 overlay 里 —— 它是这个脚本在
#     ALIOTH_SSH_PUBKEY 块里现生成的，所以得单独守。
if grep -q 'var/lib/overlays/etc/upper/sudoers\.d' "$MAKE"; then
  pass "sudoers 进 overlay upper" "$(basename "$MAKE") 把它也装进 /etc 的 upperdir"
else
  fail "sudoers 进 overlay upper" "只写了 etc/sudoers.d —— 开机后 /etc 被 overlayfs 盖住，这条规则不存在"
fi

# 2. --kernel-only 仍然可复现。脚本靠 SOURCE_DATE_EPOCH 刻意做到同样的
#    输入得同样的字节；失去这点，SHA256SUMS 就没法用来分辨两次构建。
if "$MAKE" --kernel-only >/dev/null 2>&1 && [[ -s "${KIT}/boot-debug.img" ]]; then
  s1="$(sha256sum "${KIT}/boot-debug.img" | cut -d' ' -f1)"
  "$MAKE" --kernel-only >/dev/null 2>&1
  s2="$(sha256sum "${KIT}/boot-debug.img" | cut -d' ' -f1)"
  [[ "$s1" == "$s2" ]] \
    && pass "--kernel-only 可复现" "两次构建同一个 sha ${s1:0:12}" \
    || fail "--kernel-only 可复现" "两次构建不同: ${s1:0:12} vs ${s2:0:12}"
else
  fail "--kernel-only 可复现" "--kernel-only 跑不出 boot-debug.img"
fi

echo
echo "--- B. 需要 kit（${KIT}）---"

UD="${KIT}/userdata.img"
if [[ ! -s "$UD" ]]; then
  fail "kit 已构建" "没有 $UD —— 先跑 ./make-steamos-alioth.sh --install"
  echo; echo "${fails} 条断言失败"; exit 1
fi

# 3. 文件系统格式。fastboot 认 raw ext4 和 Android sparse 两种；别的都刷不进去。
desc="$(file -b "$UD")"
case "$desc" in
  *"Android sparse image"*|*"ext4 filesystem"*|*"ext2 filesystem"*)
    pass "文件系统格式" "${desc:0:70}" ;;
  *) fail "文件系统格式" "既不是 ext4 也不是 Android sparse: ${desc:0:70}" ;;
esac

# 4. 装得进分区。镜像本身要小（首次开机才长到整个分区），而且它声明的
#    总大小绝不能超过 userdata。
ud_bytes="$(stat -c %s "$UD")"
if (( ud_bytes < PART_BYTES )); then
  pass "装得进 userdata" "$((ud_bytes / 1024 / 1024)) MiB < $((PART_BYTES / 1024 / 1024 / 1024)) GiB"
else
  fail "装得进 userdata" "$((ud_bytes / 1024 / 1024)) MiB 超过分区"
fi

# 挂载镜像看内容。sparse 的先转回 raw。
T="$(mktemp -d)"
MNT="$T/mnt"; mkdir -p "$MNT"
LOOP=""
cleanup() {
  mountpoint -q "$MNT" 2>/dev/null && sudo umount "$MNT"
  [[ -n "$LOOP" ]] && sudo losetup -d "$LOOP" 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT

raw="$UD"
if [[ "$desc" == *"Android sparse image"* ]]; then
  if command -v simg2img >/dev/null; then
    simg2img "$UD" "$T/raw.img" && raw="$T/raw.img"
  else
    fail "能挂载检查" "镜像是 sparse 但没有 simg2img，B 组后续无法检查"
    echo; echo "${fails} 条断言失败"; exit 1
  fi
fi

LOOP="$(sudo losetup --find --show --read-only "$raw" 2>/dev/null)"
if [[ -z "$LOOP" ]] || ! sudo mount -o ro "$LOOP" "$MNT" 2>/dev/null; then
  fail "能挂载检查" "挂不上 $raw"
  echo; echo "${fails} 条断言失败"; exit 1
fi

# 5. root 不能写死成 /dev/sd*。UFS 的枚举顺序不保证，写死一个节点名就是
#    「换个内核版本就起不来」。靠 UUID 或 PARTLABEL。
if [[ -f "$MNT/etc/fstab" ]]; then
  if grep -qE '^\s*/dev/sd' "$MNT/etc/fstab"; then
    fail "fstab 不写死设备名" "出现了 /dev/sd*: $(grep -E '^\s*/dev/sd' "$MNT/etc/fstab" | head -1)"
  elif grep -qE '^\s*(UUID=|PARTLABEL=|LABEL=)' "$MNT/etc/fstab"; then
    pass "fstab 不写死设备名" "$(grep -E '^\s*(UUID=|PARTLABEL=|LABEL=)' "$MNT/etc/fstab" | head -1 | cut -c1-60)"
  else
    fail "fstab 不写死设备名" "fstab 里既没有 /dev/sd* 也没有 UUID/PARTLABEL —— 根本没有根条目？"
  fi
else
  fail "fstab 不写死设备名" "镜像里没有 /etc/fstab"
fi

# 6. 首次开机哨兵。Task 7 的 alioth-firstboot 见不到它就什么都不做，
#    于是根文件系统永远停在几 GB，而 Steam 第一次装游戏才报错。
[[ -e "$MNT/var/lib/alioth-firstboot-pending" ]] \
  && pass "首次开机哨兵" "/var/lib/alioth-firstboot-pending 在镜像里" \
  || fail "首次开机哨兵" "缺 /var/lib/alioth-firstboot-pending —— 首次开机不会扩展根文件系统"

# 6b. 被 sudoers 放开的那个命令必须是 root 的，而且 steamos 不能改它。
#     放开一条 NOPASSWD 规则指向一个调用者自己能重写的脚本，等于把 root
#     白送出去 —— 那条规则允许 steamos 以 root 跑它，而 steamos 能先把它的
#     内容换成任何东西。这不是假设：2026-10-24 手工往设备上装的时候，
#     tar 把归档里的 uid 原样还了出来，于是文件是 steamos:steamos 的。
#     构建路径本身是对的（apply-alioth-overlay.sh 在 sudo 下跑，install -D
#     给的是 root:root），这条断言是为了让它一直是对的。
SUDOERS="$MNT/etc/sudoers.d/zz-alioth-write-boot"
# 规则里放开的每一个脚本都要查，不只是第一个。
GRANTED=(
  "$MNT/usr/lib/steamos-arm/alioth-write-boot"
  "$MNT/usr/lib/steamos-arm/alioth-install-modules"
)
if [[ ! -e "$SUDOERS" ]]; then
  # 没有那条规则就没有这个风险。镜像是不带 ALIOTH_SSH_PUBKEY 构建的。
  pass "自刷授权（未开）" "镜像里没有 sudoers 规则 —— 不是用 ALIOTH_SSH_PUBKEY 构建的"
else
  bad=()
  dirmode="$(stat -c %a "$MNT/usr/lib/steamos-arm" 2>/dev/null || echo 777)"
  dirown="$(stat -c '%U:%G' "$MNT/usr/lib/steamos-arm" 2>/dev/null || echo '?:?')"
  [[ "$dirown" == "root:root" && $(( 0$dirmode & 022 )) -eq 0 ]] \
    || bad+=("目录 usr/lib/steamos-arm $dirown $dirmode")
  for g in "${GRANTED[@]}"; do
    if [[ ! -x "$g" ]]; then
      bad+=("$(basename "$g") 不在或不可执行")
      continue
    fi
    gown="$(stat -c '%U:%G' "$g")"; gmode="$(stat -c %a "$g")"
    [[ "$gown" == "root:root" && $(( 0$gmode & 022 )) -eq 0 ]] \
      || bad+=("$(basename "$g") $gown $gmode")
  done
  # 反过来也要查：规则里放开的命令必须都在上面那张单子上，否则新加一条
  # 规则就能绕过这条断言。
  while read -r cmd; do
    [[ -n "$cmd" ]] || continue
    [[ "$cmd" == /usr/bin/systemctl* ]] && continue
    printf '%s\n' "${GRANTED[@]}" | grep -qx "$MNT$cmd" \
      || bad+=("sudoers 放开了 $cmd，但这条断言没查它")
  done < <(sed -n 's/.*NOPASSWD:[[:space:]]*//p' "$SUDOERS")
  if [[ ${#bad[@]} -eq 0 ]]; then
    pass "自刷授权的命令是 root 的" "${#GRANTED[@]} 个命令和目录都是 root:root 且组/其他不可写"
  else
    fail "自刷授权的命令是 root 的" "${bad[*]} —— steamos 改得了它就等于能拿 root"
  fi

  # 6c. 那条规则必须是 sudoers.d 里排最后的。@includedir 按文件名排序读，
  #     而 sudoers 里后面的规则覆盖前面的：镜像自带的 sudoers.d/wheel 写着
  #     `%wheel ALL=(ALL) ALL`，而 steamos 在 wheel 组里。排在它前面的话，
  #     wheel 那条带密码的规则最后生效，`sudo -n` 要密码 —— 2026-10-24 实测，
  #     叫 50-alioth-write-boot 时就是这样，而症状（"sudo: a password is
  #     required"）看着像规则没装上，不像装对了但被覆盖。
  last="$(ls "$MNT/etc/sudoers.d" | LC_ALL=C sort | tail -1)"
  [[ "$last" == "zz-alioth-write-boot" ]] \
    && pass "自刷授权排在最后" "sudoers.d 里排序最后的是 $last" \
    || fail "自刷授权排在最后" "排最后的是 $last —— 它会覆盖我们这条；改个排在它后面的名字"
fi

# 7. 固件。阶段 1 一个一个试出来的那几个。
missing_fw=()
for f in "${WANT_FW[@]}"; do
  [[ -e "$MNT/usr/lib/firmware/$f" || -e "$MNT/lib/firmware/$f" ]] || missing_fw+=("$f")
done
[[ ${#missing_fw[@]} -eq 0 ]] \
  && pass "固件齐全" "${#WANT_FW[@]} 个全部在镜像里" \
  || fail "固件齐全" "缺少: ${missing_fw[*]}"

# 7b. 镜像里的 a650_zap.mbn / adsp.mbn 必须是机内签名那两份，不能是
#     linux-firmware 的通用签名版 —— 上面第 7 条只看「文件在不在」，而这两份
#     文件和 linux-firmware 的同名文件连大小都一样（zap 两边都 13964 字节），
#     只有签名不同。alioth 的 TZ 拒收通用签名版，后果是黑屏加没声音。
LF="$(ls -d "${WORKDIR}/kernel-sm8250/cache/linux-firmware-"* 2>/dev/null | tail -1)"
if [[ -z "$LF" ]]; then
  fail "固件是机内签名版" "找不到 linux-firmware 检出来比"
else
  generic=()
  for f in qcom/sm8250/a650_zap.mbn qcom/sm8250/adsp.mbn; do
    img="$MNT/usr/lib/firmware/$f"
    [[ -e "$img" ]] || img="$MNT/lib/firmware/$f"
    if [[ ! -s "$img" ]]; then
      generic+=("$f(缺)")
    elif cmp -s "$img" "$LF/$f"; then
      generic+=("$f")
    fi
  done
  [[ ${#generic[@]} -eq 0 ]] \
    && pass "固件是机内签名版" "a650_zap.mbn 与 adsp.mbn 都和 $(basename "$LF") 的不同" \
    || fail "固件是机内签名版" "还是通用签名版或缺失: ${generic[*]} —— 设 ALIOTH_FW_DIR 重跑 --install"
fi

# 8. modules-load.d 里列的模块，镜像里真的有对应的 .ko。清单和镜像对不上
#    的话 modprobe 静默失败 —— 没有 WiFi、没有声卡，都没有提示。
ml="$MNT/usr/lib/modules-load.d/alioth.conf"
if [[ -f "$ml" ]]; then
  # 只把真实存在的目录交给 find：这个脚本开了 pipefail，find 遇到不存在的
  # 路径会返回非零，于是哪怕 grep 匹配上了整条管道还是失败 —— 症状是「每个
  # 模块都说找不到」，而模块其实好好地在镜像里。
  moddirs=()
  for d in "$MNT/usr/lib/modules" "$MNT/lib/modules"; do
    [[ -d "$d" ]] && moddirs+=("$d")
  done
  missing_ko=()
  if [[ ${#moddirs[@]} -eq 0 ]]; then
    missing_ko=("<镜像里根本没有 modules 目录>")
  else
    while IFS= read -r m; do
      [[ -z "$m" || "$m" == \#* ]] && continue
      found="$(find "${moddirs[@]}" -name "${m//_/?}.ko*" -print -quit 2>/dev/null)"
      [[ -n "$found" ]] || missing_ko+=("$m")
    done <"$ml"
  fi
  [[ ${#missing_ko[@]} -eq 0 ]] \
    && pass "模块都在镜像里" "modules-load.d/alioth.conf 列的都找得到" \
    || fail "模块都在镜像里" "找不到: ${missing_ko[*]}"
else
  fail "模块都在镜像里" "镜像里没有 usr/lib/modules-load.d/alioth.conf"
fi

# 8b. /etc overlayfs 的 upper 和 work 都要在。overlayfs 要求两者都已存在，
#     systemd 的 mount unit 不会替你建，而 Valve 的 rootfs.img 里一个都没有。
#     少了的话 etc.mount 失败，/etc 退回下层，镜像到 upper 的配置全不生效。
ovl_missing=()
for d in upper work; do
  [[ -d "$MNT/var/lib/overlays/etc/$d" ]] || ovl_missing+=("$d")
done
[[ ${#ovl_missing[@]} -eq 0 ]] \
  && pass "/etc overlay 目录齐全" "var/lib/overlays/etc/{upper,work} 都在" \
  || fail "/etc overlay 目录齐全" "缺少 ${ovl_missing[*]} —— etc.mount 会失败"

# 8c. InputPlumber 的守护进程。Valve 的镜像里没有，由 --install 装。
#     没有它，spec §7.1 的整套输入设计都不成立 —— 手柄在 Steam 里还是
#     Xbox 图标，音量键呼不出快捷菜单。
if [[ -x "$MNT/usr/bin/inputplumber" ]]; then
  if [[ -e "$MNT/usr/lib/systemd/system/multi-user.target.wants/inputplumber.service" ]]; then
    pass "InputPlumber" "usr/bin/inputplumber，且已 enable"
  else
    fail "InputPlumber" "装了但没 enable —— 不会启动"
  fi
else
  fail "InputPlumber" "镜像里没有 usr/bin/inputplumber"
fi

# 8d. steamos-powerbuttond 的二进制。sm8250-overlay 的 unit 的 ExecStart
#     指向它；它来自 Valve 的基础镜像。
[[ -x "$MNT/usr/lib/hwsupport/steamos-powerbuttond" ]] \
  && pass "powerbuttond 二进制" "usr/lib/hwsupport/steamos-powerbuttond" \
  || fail "powerbuttond 二进制" "没有 usr/lib/hwsupport/steamos-powerbuttond —— unit 的 ExecStart 指空"

# 9. alioth-overlay 真的装进去了（Task 3 的脚本跑过了）。
[[ -f "$MNT/etc/inputplumber/devices.d/02-xiaomi-alioth.yaml" ]] \
  && pass "alioth-overlay 已装" "02-xiaomi-alioth.yaml 在镜像里" \
  || fail "alioth-overlay 已装" "镜像里没有 02-xiaomi-alioth.yaml"

echo
if ((fails)); then
  echo "${fails} 条断言失败"
  exit 1
fi
echo "全部断言通过"
