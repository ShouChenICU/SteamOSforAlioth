#!/usr/bin/env bash
# 构建 alioth 的 sm8250 内核。
#
# 这个包装脚本存在的理由是六条在实施中发现、而上游不替我们保证的前提：
#
#  1. build.sh 读的是 WORK，不是镜像脚本用的 STEAMOS_WORK。
#  2. build-gcc15.sh 断言源码树在 $MOUNT 之下（默认 /work），我们的树不在。
#  3. build.sh 不会自动 clone ROCKNIX，且校验它停在固定 ref 上。
#  4. build.sh 只检查 /bin/busybox 是否 "statically linked"，**不检查架构**。
#     在 x86_64 宿主上，一个静态的 x86_64 busybox 能通过它的检查，却会产出
#     一个 aarch64 设备根本执行不了的 initramfs —— 表现为黑屏且调试 shell
#     起不来，而调试 shell 是阶段 1 唯一的观测手段，极易被误判成内核或 DTS
#     的问题。所以架构断言必须在这里做，每次构建都做。
#  5. 容器运行时只被 `command -v` 检查过，没有人确认守护进程连得上。
#  6. 容器里没有 --user，rootful docker 下产物归 root，之后的普通用户步骤会废。
set -euo pipefail

PORT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROCKNIX_REF=20261001

export MOUNT="${MOUNT:-$(dirname "$PORT_ROOT")}"
export WORK="${WORK:-$PORT_ROOT/work/kernel-sm8250}"
export BUSYBOX="${BUSYBOX:-$PORT_ROOT/work/busybox-aarch64-static}"

# 容器运行时：podman 优先（上游默认，rootless），否则 docker。
if [[ -z "${DOCKER:-}" ]]; then
  if command -v podman >/dev/null; then DOCKER=podman
  elif command -v docker >/dev/null; then DOCKER=docker
  else DOCKER=podman; fi
fi
export DOCKER

die() { echo "build-alioth-kernel: $*" >&2; exit 1; }

# 前提 4：busybox 必须同时是 aarch64 和静态链接
[[ -x "$BUSYBOX" ]] || die "没有 busybox: $BUSYBOX"
bb_desc=$(file -b "$BUSYBOX")
case "$bb_desc" in
  *"ARM aarch64"*) ;;
  *) die "busybox 不是 aarch64：$bb_desc" ;;
esac
case "$bb_desc" in
  *"statically linked"*) ;;
  *) die "busybox 不是静态链接：$bb_desc" ;;
esac

# 前提 3：ROCKNIX 检出存在且停在固定 ref 上
ROCKNIX_DIR="${ROCKNIX_DIR:-$MOUNT/rocknix-$ROCKNIX_REF}"
export ROCKNIX_DIR
[[ -e "$ROCKNIX_DIR/.git" ]] || die "没有 ROCKNIX 检出: $ROCKNIX_DIR"
[[ "$(git -C "$ROCKNIX_DIR" rev-parse HEAD)" == "$(git -C "$ROCKNIX_DIR" rev-parse "$ROCKNIX_REF^{commit}")" ]] \
  || die "ROCKNIX 检出不在 $ROCKNIX_REF 上"

# 前提 2：源码树、WORK、ROCKNIX 三者都要在 MOUNT 之下
for p in "$PORT_ROOT" "$WORK" "$ROCKNIX_DIR"; do
  [[ "$p" == "$MOUNT"/* ]] || die "$p 不在 MOUNT=$MOUNT 之下"
done

# 前提 5：光有二进制不够 —— 守护进程可能没启动，或当前用户不在 docker 组里。
# 此时 `command -v docker` 照样成功，而失败会发生在 build-gcc15.sh 深处（拉
# Fedora 镜像时），错误信息与真正的原因相距很远。
command -v "$DOCKER" >/dev/null || die "没有容器运行时 '$DOCKER'"
mkdir -p "$WORK"
SUDO_DOCKER=0
if ! "$DOCKER" info >/dev/null 2>&1; then
  if [[ "$DOCKER" == docker ]] && sudo -n docker info >/dev/null 2>&1; then
    # 守护进程要 root 才连得上。上游写的是 `exec "$DOCKER" run`（带引号），
    # 所以 DOCKER='sudo docker' 会被当成一个叫 "sudo docker" 的二进制去找。
    # 放一个 shim 在 PATH 最前面，上游脚本不用改。
    shim="$WORK/.shim"
    mkdir -p "$shim"
    printf '#!/bin/sh\nexec sudo -n docker "$@"\n' > "$shim/docker"
    chmod +x "$shim/docker"
    export PATH="$shim:$PATH"
    SUDO_DOCKER=1
  else
    die "'$DOCKER info' 失败 —— 守护进程没启动（sudo systemctl start docker），或当前用户不在 docker 组"
  fi
fi

echo "build-alioth-kernel: MOUNT=$MOUNT"
echo "build-alioth-kernel: WORK=$WORK"
echo "build-alioth-kernel: ROCKNIX_DIR=$ROCKNIX_DIR"
echo "build-alioth-kernel: BUSYBOX=$BUSYBOX ($bb_desc)"
echo "build-alioth-kernel: DOCKER=$DOCKER$([[ $SUDO_DOCKER == 1 ]] && echo ' (经 sudo shim)')"

# 前提 6：rootful docker 的容器内 root 就是宿主 root，产物会是 root 所有，
# 后续用普通用户跑 fdtget / ufs-bootimg.py / git add 全会失败。构建结束后无论
# 成败都把 WORK 的归属交回来 —— 失败时的中间产物同样需要能被读和删。
status=0
bash "$PORT_ROOT/external-and-mods/kernel-common/build-gcc15.sh" sm8250 "$@" || status=$?
if [[ $SUDO_DOCKER == 1 ]]; then
  sudo -n chown -R "$(id -u):$(id -g)" "$WORK" || echo "build-alioth-kernel: 警告 —— chown $WORK 失败" >&2
fi
exit $status
