#!/usr/bin/env bash
# 断言机内签名固件树（scripts/extract-alioth-firmware.sh 的产物）能用。
#
# 用法: scripts/assert-alioth-firmware.sh <firmware-dir>
#
# 每一条都对应一个会在真机上静默失败、而且症状离原因很远的事：
# 固件不对不会报「固件不对」，只会报 "error -22 initializing firmware"，
# 然后 GPU 不起、Turnip 找不到设备、gamescope 找不到物理设备、sddm 死循环，
# 看起来就是一块黑屏。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FW="${1:-}"
[[ -n "$FW" ]] || { echo "用法: $0 <firmware-dir>" >&2; exit 2; }

# linux-firmware 的那两份通用签名镜像。alioth 的 TrustZone **拒收**它们
# （qcom_scm_pas_init_image 返 -EINVAL = Invalid firmware metadata），所以
# 「和 linux-firmware 的那份一样」就等于「没用」。拿构建树里现成的那份比，
# 不写死 md5：linux-firmware 一升级 md5 就变，而要表达的要求没变。
LF="$(ls -d "${ROOT}/work/kernel-sm8250/cache/linux-firmware-"* 2>/dev/null | tail -1)"

fails=0
pass() { printf 'PASS  %s — %s\n' "$1" "$2"; }
fail() { printf 'FAIL  %s — %s\n' "$1" "$2"; fails=$((fails + 1)); }

# 1. 两份镜像都在，而且是 ELF。squash 出来的东西必须还是个 ELF ——
#    phdr 表是从 .mdt 原样抄回去的，抄错偏移就不是 ELF 了。
for f in qcom/sm8250/a650_zap.mbn qcom/sm8250/adsp.mbn; do
  p="$FW/$f"
  if [[ ! -s "$p" ]]; then
    fail "$f 存在" "没有 $p"
  elif [[ "$(head -c4 "$p" | od -An -tx1 | tr -d ' \n')" != "7f454c46" ]]; then
    fail "$f 是 ELF" "$p 前四字节不是 7f 45 4c 46"
  else
    pass "$f" "$(stat -c %s "$p") 字节，ELF"
  fi
done

# 2. a650_zap 必须**不是** linux-firmware 的那份。这是黑屏四条链里的第二条，
#    也是唯一一条光看文件名完全看不出来的 —— 两边文件名一样、大小也一样
#    （都 13964 字节），只有签名不同。
# cmp 对一个不存在的文件也返回非零 —— 直接拿 cmp 的返回值当「不同」，
# 文件缺失时这条断言会空过。先要求两边都在。
if [[ ! -s "$FW/qcom/sm8250/a650_zap.mbn" ]]; then
  fail "a650_zap 不是通用签名版" "没有 $FW/qcom/sm8250/a650_zap.mbn，无从比较"
elif [[ -z "$LF" ]]; then
  fail "a650_zap 不是通用签名版" "找不到 work/kernel-sm8250/cache/linux-firmware-* 来比"
elif [[ ! -f "$LF/qcom/sm8250/a650_zap.mbn" ]]; then
  fail "a650_zap 不是通用签名版" "$LF 里没有 qcom/sm8250/a650_zap.mbn"
elif cmp -s "$FW/qcom/sm8250/a650_zap.mbn" "$LF/qcom/sm8250/a650_zap.mbn"; then
  fail "a650_zap 不是通用签名版" "和 $(basename "$LF") 的那份逐字节相同 —— TZ 会拒收"
else
  pass "a650_zap 不是通用签名版" "和 $(basename "$LF") 的那份不同"
fi

# 3. adsp 同理。没有它 q6afe 起不来，表现是「只有 Dummy Output」。
if [[ ! -s "$FW/qcom/sm8250/adsp.mbn" ]]; then
  fail "adsp 不是通用签名版" "没有 $FW/qcom/sm8250/adsp.mbn，无从比较"
elif [[ -n "$LF" && -f "$LF/qcom/sm8250/adsp.mbn" ]]; then
  cmp -s "$FW/qcom/sm8250/adsp.mbn" "$LF/qcom/sm8250/adsp.mbn" \
    && fail "adsp 不是通用签名版" "和 $(basename "$LF") 的那份逐字节相同" \
    || pass "adsp 不是通用签名版" "和 $(basename "$LF") 的那份不同"
else
  fail "adsp 不是通用签名版" "找不到 linux-firmware 的 qcom/sm8250/adsp.mbn 来比"
fi

# 4. 不许混进来别的东西。这棵树会被原样盖到 /usr/lib/firmware 上，
#    多出来的文件会无声地覆盖 linux-firmware 的同名文件。
if [[ ! -d "$FW" ]]; then
  fail "树里只有这两份" "$FW 不是目录"
  extra=SKIP
else
extra="$(cd "$FW" && find . -type f ! -name a650_zap.mbn ! -name adsp.mbn | sed 's|^\./||')"
[[ -z "$extra" ]] \
  && pass "树里只有这两份" "没有多余文件" \
  || fail "树里只有这两份" "多出: $(tr '\n' ' ' <<<"$extra")"
fi

echo
[[ $fails -eq 0 ]] && echo "全部通过。" || echo "$fails 条断言失败"
exit $((fails > 0))
