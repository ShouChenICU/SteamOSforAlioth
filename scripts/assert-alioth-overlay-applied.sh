#!/usr/bin/env bash
# 断言 scripts/apply-alioth-overlay.sh 把 alioth 的配置正确装进一棵 rootfs。
#
# 用一棵假的 rootfs 目录树：先把 sm8250-overlay 的 44 个文件照 apply-overlays.sh
# 的方式装进去，复现「掌机 overlay 刚装完」的真实局面，再跑我们的脚本。
# 不碰真镜像、不需要 root、几毫秒跑完。
#
# 照 scripts/assert-alioth-dtb.py 的样式：PASS/FAIL 加证据，结尾汇总，
# 任一失败退出非零。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPLY="${ROOT}/scripts/apply-alioth-overlay.sh"
OVL="${ROOT}/alioth-overlay"
S8250="${ROOT}/sm8250-overlay"

# DTB 的 model，与 scripts/assert-alioth-overlay.py 同一个值。
DT_MODEL="Xiaomi Poco F3"

fails=0
pass() { printf 'PASS  %s — %s\n' "$1" "$2"; }
fail() { printf 'FAIL  %s — %s\n' "$1" "$2"; fails=$((fails + 1)); }

R="$(mktemp -d)"
trap 'rm -rf "$R"' EXIT

# 假 rootfs = apply-overlays.sh 在 SOC=sm8250 下跑完的样子。
mkdir -p "$R/var/lib/overlays/etc/upper" "$R/usr/bin"
(cd "$S8250" && find etc usr -type f -print0) |
  while IFS= read -r -d '' f; do install -D -m0644 "$S8250/$f" "$R/$f"; done
echo "unrelated" >"$R/usr/bin/somebinary"

if [[ ! -x "$APPLY" ]]; then
  fail "脚本存在" "没有可执行的 $APPLY"
  echo; echo "${fails} 条断言失败"; exit 1
fi

out="$("$APPLY" "$R" 2>&1)"; rc=$?
[[ $rc -eq 0 ]] || fail "首次运行" "退出码 $rc: ${out:0:300}"

# 1. alioth-overlay 的 etc/ 与 usr/ 文件全部装进去了，README.md 不装。
missing=()
while IFS= read -r f; do
  [[ -f "$R/$f" ]] || missing+=("$f")
done < <(cd "$OVL" && find etc usr -type f | sort)
[[ ${#missing[@]} -eq 0 ]] \
  && pass "alioth 文件已装" "etc/ 与 usr/ 下的文件都在" \
  || fail "alioth 文件已装" "缺少: ${missing[*]}"
[[ ! -e "$R/README.md" ]] \
  && pass "README 不入镜像" "rootfs 根目录没有 README.md" \
  || fail "README 不入镜像" "README.md 被装进了 rootfs 根目录"

# 2. /etc 的 overlayfs upper 也要有一份。SteamOS 的 /etc 是 overlayfs 且挂载
#    很晚，只写下层的文件开机时看不到 —— 症状是「配置装了却不生效」。
upper_missing=()
while IFS= read -r f; do
  [[ -f "$R/var/lib/overlays/etc/upper/${f#etc/}" ]] || upper_missing+=("${f#etc/}")
done < <(cd "$OVL" && find etc -type f | sort)
[[ ${#upper_missing[@]} -eq 0 ]] \
  && pass "/etc overlay upper" "etc/ 下的文件在 upper 里都有一份" \
  || fail "/etc overlay upper" "upper 里缺少: ${upper_missing[*]} —— 开机不生效"

# 2b. 可执行位要保住。alioth-firstboot 由 systemd 的 ExecStart 执行，装成
#     0644 会以 203/EXEC 失败 —— 而症状是「首次开机没扩展根文件系统」，
#     离原因很远。
badmode=()
while IFS= read -r f; do
  [[ -x "$R/$f" ]] || badmode+=("$f")
done < <(cd "$OVL" && find etc usr -type f -perm -u+x | sort)
[[ ${#badmode[@]} -eq 0 ]] \
  && pass "可执行位保住了" "overlay 里可执行的文件装进去仍然可执行" \
  || fail "可执行位保住了" "装成了不可执行: ${badmode[*]}"

# 2c. 符号链接要原样装进去（unit 的 enable 链接靠它）。install 会跟过去
#     复制目标文件，于是 systemd 看到的是一个重复的 unit 而不是 enable。
badlink=()
while IFS= read -r f; do
  [[ -L "$R/$f" ]] || badlink+=("$f")
done < <(cd "$OVL" && find etc usr -type l | sort)
[[ ${#badlink[@]} -eq 0 ]] \
  && pass "符号链接仍是链接" "overlay 里的符号链接装进去仍是符号链接" \
  || fail "符号链接仍是链接" "变成了普通文件: ${badlink[*]}"

# 3. 互斥：除了我们自己的 profile，不能有第二个 InputPlumber CompositeDevice
#    认领 alioth 的 DT model。掌机的 5 个 profile 都 gate 在各自的 model 上，
#    所以它们是惰性的 —— 这条断言守的是「以后谁加了个 catch-all」。
claimers=()
for f in "$R"/etc/inputplumber/devices.d/*.yaml; do
  [[ -e "$f" ]] || continue
  [[ "$(basename "$f")" == 02-xiaomi-alioth.yaml ]] && continue
  grep -qF "$DT_MODEL" "$f" && claimers+=("$(basename "$f")")
done
[[ ${#claimers[@]} -eq 0 ]] \
  && pass "profile 互斥" "只有 02-xiaomi-alioth.yaml 认领 ${DT_MODEL}" \
  || fail "profile 互斥" "还有 ${claimers[*]} 也认领 ${DT_MODEL}"

# 4. steamos-powerbuttond.service 必须活着，而且必须是 sm8250 的替代版。
#    我们的 99-zz-alioth-powerbuttond.conf 只写了 Wants= —— systemd 对指不到
#    任何单元的 Wants= 一声不吭，电源键就这么静默失灵。Frame 自带的那个
#    单元是 Requisite=steamvr.service（本镜像里 steamvr 被 mask），同样没用。
PBD="$R/etc/systemd/user/steamos-powerbuttond.service"
if [[ ! -f "$PBD" ]]; then
  fail "powerbuttond 单元" "没有 etc/systemd/user/steamos-powerbuttond.service —— Wants= 悬空"
elif grep -qE '^[[:space:]]*Requisite=.*steamvr' "$PBD"; then
  fail "powerbuttond 单元" "装的是 Frame 自带版（Requisite=steamvr.service），不会启动"
else
  pass "powerbuttond 单元" "etc/systemd/user/steamos-powerbuttond.service 可用"
fi

# 4d. 时钟下限。alioth 的 PMIC RTC 在首次开机时读出垃圾值 —— 真机实测是
#     2091-01-25，于是 systemd 判定「比内置 epoch 超前 15 年以上」并把系统
#     时间拍回它编译时的内置 epoch（2026-02-23），比 rootfs 的构建日期早了
#     八个月。后果不是「时间显示不对」：PAM 立刻报
#     "account steamos has password changed in future"，而 HTTPS 证书全部
#     「尚未生效」，Steam 登不上。
#     systemd 把 /usr/lib/clock-epoch 的 mtime 当作 epoch（优先于内置值），
#     所以装一个 mtime = 构建时刻的空文件，开机时间就至少是构建日期；
#     联网后 NTP 再校准，内核的 11 分钟模式会把 RTC 写回去（RTC 实测可写）。
EPOCH="$R/usr/lib/clock-epoch"
if [[ ! -f "$EPOCH" ]]; then
  fail "时钟下限" "没有 usr/lib/clock-epoch —— 垃圾 RTC 会让系统时间回到 systemd 的内置 epoch"
else
  age=$(( $(date +%s) - $(stat -c %Y "$EPOCH") ))
  if (( age >= 0 && age < 86400 )); then
    pass "时钟下限" "usr/lib/clock-epoch 的 mtime 是构建时刻（${age} 秒前）"
  else
    fail "时钟下限" "usr/lib/clock-epoch 的 mtime 距今 ${age} 秒 —— 不是构建时刻"
  fi
fi

# 5. 不碰无关文件。
[[ -f "$R/usr/bin/somebinary" ]] \
  && pass "不误伤无关文件" "usr/bin/somebinary 仍在" \
  || fail "不误伤无关文件" "usr/bin/somebinary 被删了"

# 6. 幂等。构建流程会重跑它，第二次不得报错或改变结果。
before="$(cd "$R" && find . -type f | sort | md5sum)"
out2="$("$APPLY" "$R" 2>&1)"; rc2=$?
after="$(cd "$R" && find . -type f | sort | md5sum)"
if [[ $rc2 -eq 0 && "$before" == "$after" ]]; then
  pass "幂等" "第二次运行退出 0，文件清单不变"
else
  fail "幂等" "第二次运行退出 $rc2，文件清单变了: ${out2:0:200}"
fi

echo
if ((fails)); then
  echo "${fails} 条断言失败"
  exit 1
fi
echo "全部断言通过"
