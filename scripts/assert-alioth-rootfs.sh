#!/usr/bin/env bash
# 断言 Valve Frame rootfs 满足 alioth 阶段 2 的硬性前提。
#
# 阶段 2 把 Valve 的 aarch64 rootfs 原样拿来用（spec §4「一行不动」），所以
# 这里断言的不是我们写的东西，而是**上游给了我们什么**。每条都对应一个
# 「缺了它阶段 2 就走不下去」的组件，而且缺失时的症状都离原因很远：
# 没有 FEX 表现为「游戏点了没反应」，没有 Turnip 表现为「黑屏」，
# /etc 不是 overlayfs 则表现为「配置装了却不生效」。
#
# 照 scripts/assert-alioth-dtb.py 的样式：每条打印 PASS/FAIL 加证据，
# 结尾汇总，任一失败退出非零。本仓库没有 tests/ 也没有 pytest ——
# 断言脚本就是这个项目的测试载体。
#
# 用法: scripts/assert-alioth-rootfs.sh <rootfs-dir>
set -uo pipefail

R="${1:-}"
[[ -n "$R" ]] || { echo "用法: $0 <rootfs-dir>" >&2; exit 2; }

fails=0
pass() { printf 'PASS  %s — %s\n' "$1" "$2"; }
fail() { printf 'FAIL  %s — %s\n' "$1" "$2"; fails=$((fails + 1)); }

# 1. 架构。x86_64 的 rootfs 在 aarch64 上一个字节都跑不起来，而这种搞错
#    在阶段 1 的 busybox 上真实发生过（见 build-alioth-kernel.sh 前提 4）。
if [[ -f "$R/usr/bin/bash" ]]; then
  desc="$(file -b "$R/usr/bin/bash")"
  case "$desc" in
    *"ARM aarch64"*) pass "aarch64" "usr/bin/bash: ${desc:0:60}" ;;
    *) fail "aarch64" "usr/bin/bash 不是 aarch64: ${desc:0:60}" ;;
  esac
else
  fail "aarch64" "没有 $R/usr/bin/bash（rootfs 没解开？）"
fi

# 2. gamescope —— Game Mode 的合成器，没有它开机到不了任何界面。
if [[ -x "$R/usr/bin/gamescope" ]]; then
  pass "gamescope" "usr/bin/gamescope"
else
  fail "gamescope" "没有 usr/bin/gamescope"
fi

# 3. FEX 的 x86 客户机根文件系统。这是 spec §7.3 真正的依赖，也是
#    Task 1 Step 4 要回答的问题：Valve 自己带不带 x86 Mesa。
#    带 —— /usr/share/guestos/fex-mesa 是一整棵 x86 根，x86-64 和 i386 都有。
G="$R/usr/share/guestos/fex-mesa"
if [[ -d "$G" ]]; then
  arch64="$(file -b "$G/lib64/ld-linux-x86-64.so.2" 2>/dev/null)"
  arch32="$(file -b "$G/usr/lib32/libc.so.6" 2>/dev/null)"
  if [[ "$arch64" == *"x86-64"* && "$arch32" == *"ELF 32-bit"* ]]; then
    pass "FEX x86 客户机根" "usr/share/guestos/fex-mesa（x86-64 + i386，$(du -sh "$G" 2>/dev/null | cut -f1)）"
  else
    fail "FEX x86 客户机根" "有目录但架构不对: 64=${arch64:0:30} 32=${arch32:0:30}"
  fi
else
  fail "FEX x86 客户机根" "没有 usr/share/guestos/fex-mesa —— x86 游戏没有 Mesa 可用"
fi

# 4. FEX 的入口。注意 FEXInterpreter **不在**镜像里：它随 Steam ARM 客户端
#    一起来（FEXBash 里引用的是 /home/steamos/.steam/… 的路径）。所以这里
#    只断言入口脚本在，FEXInterpreter 归 kit 断言（装完 Steam 之后）。
if [[ -x "$R/usr/bin/FEXBash" ]]; then
  pass "FEXBash" "usr/bin/FEXBash（FEXInterpreter 随 Steam 客户端安装）"
else
  fail "FEXBash" "没有 usr/bin/FEXBash"
fi

# 5. Turnip —— A650 的 Vulkan 驱动。缺了就是黑屏，不是降级到软件渲染。
tu="$(find "$R/usr/lib" -name 'libvulkan_freedreno.so' 2>/dev/null | head -1)"
if [[ -n "$tu" ]]; then
  pass "Turnip" "${tu#$R}"
else
  fail "Turnip" "找不到 libvulkan_freedreno.so"
fi

# 6. /etc 的 overlayfs 机制。镜像里**没有** upper/work 两个目录 —— 它们由
#    镜像构建时创建（make-steamos-alioth.sh --install）。overlayfs 要求两者
#    都已存在，systemd 的 mount unit 不会替你建；少了的话 etc.mount 失败，
#    /etc 退回下层，镜像到 upper 的配置全不生效。这里断言的是机制在，
#    目录由 scripts/assert-alioth-kit.sh 对成品镜像断言。
em="$R/usr/lib/systemd/system/etc.mount"
if [[ -f "$em" ]] && grep -q 'upperdir=/var/lib/overlays/etc/upper' "$em"; then
  pass "/etc overlayfs 机制" "etc.mount: upperdir=/var/lib/overlays/etc/upper"
else
  fail "/etc overlayfs 机制" "没有 etc.mount 或它的 upperdir 不是预期路径"
fi

# 注意这里**不**断言 InputPlumber 和 Proton：Valve 的 Frame 镜像两个都没有。
# InputPlumber 由 make-steamos-alioth.sh --install 装（官方预编译 aarch64
# release），Proton 由 Steam 客户端带来。两者都归 scripts/assert-alioth-kit.sh。

echo
if ((fails)); then
  echo "${fails} 条断言失败"
  exit 1
fi
echo "全部断言通过"
