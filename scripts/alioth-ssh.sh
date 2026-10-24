#!/usr/bin/env bash
# 在**正式系统**（--install 装出来的那个）上跑命令，走 USB NCM 的 ssh。
#
# 和 scripts/alioth-shell.sh 的区别是连的是两套完全不同的东西 —— 同一个
# 地址上的两个服务：
#   alioth-shell.sh  -> initramfs 的 usb_shell，172.16.42.1:23 上一个
#                       **无认证的 root** shell（nc，没有 pty）。
#   本脚本           -> 正式系统里的 sshd，22 端口，steamos 用户，有 pty。
# 两者并存：initramfs 的那个进程 switch_root 之后还活着（scripts 里的
# ns.sh 就是靠它借真根的加载器跑 nsenter 拿 root 的），usb0 和它的地址也
# 没人拆。要 root 用前者，要正常的交互和二进制安全的管道用后者。
#
# 地址：用 172.16.42.1，也就是 initramfs 给 usb0 配的那个。
#
# 一开始写的是 Frame 自己的 NCM 方案（/usr/share/deckard/usb-ncm-dnsmasq.sh
# 的注释：网络 10.86.200.232、设备 .233、宿主 .234、DHCP 池 .235-238），
# 那是错的 —— 真机实测 Valve 的镜像**自己**就把那个 unit masked 掉了：
#   /etc/systemd/system/usb-ncm-dnsmasq@usb0.service -> /dev/null  (Feb 24 2026)
# 也就是说 .233 在一次干净的开机之后根本不会出现（之前能连上，是因为那个
# 地址是手工加的）。而这种错法的症状是最难认的一种：ping 100% 丢包、ssh
# 超时，和「设备挂了」一模一样。
#
# 172.16.42.1 则是 initramfs/init 在 steamos.usbshell=1 时无条件配上的，
# 而我们的 boot.img 的 cmdline 里一直带着这个开关，所以它在每次开机之后都在。
# switch_root 之后这个接口和地址都还留着（gadget 是 initramfs 建的，没人拆），
# 正式系统里的 sshd 监听全部地址，所以直接连它就行。
# .233 留作备选：手工配过、或者将来 unmask 了那个 unit 的话也能连上。
#
# 每次 USB gadget 重枚举，宿主端都会出现一个新的 netdev，地址随之丢掉 ——
# 表现同样和「设备挂了」一模一样。所以每次连接前都重新确认一遍，而不是
# 假设上次配好的还在。
#
# 前提：镜像里装了 sshd 的公钥。--install 只在设置了 ALIOTH_SSH_PUBKEY 时
# 才装，默认不装（见 make-steamos-alioth.sh）。
#
# 用法:
#   scripts/alioth-ssh.sh                      # 交互式
#   scripts/alioth-ssh.sh 'dmesg | tail'       # 跑一条命令
set -uo pipefail

# 候选地址，按可靠性排序：第一个是 initramfs 无条件配的，第二个是 Frame 的
# NCM 方案（本机上那个 unit 被 Valve 自己 masked 了，所以通常不在）。
CANDIDATES=(
  "172.16.42.1    172.16.42.2/24"
  "10.86.200.233  10.86.200.234/29"
)
USER_AT=steamos

usb_ifaces() {
  local i
  for i in $(ls /sys/class/net); do
    # gadget 的接口名跟着 USB 端口走（enp0s20f0u3u4i4 之类），所以按前缀认，
    # 不按固定名字。
    case "$i" in enp*u*|usb*) echo "$i" ;; esac
  done
}

try_addr() {  # try_addr <设备 IP> <宿主 CIDR>
  local dev="$1" cidr="$2" i found=0
  ping -c1 -W2 "$dev" >/dev/null 2>&1 && { DEV_IP="$dev"; return 0; }
  for i in $(usb_ifaces); do
    found=1
    sudo ip link set "$i" up 2>/dev/null
    ip -br addr show "$i" | grep -q "${cidr%/*}" \
      || sudo ip addr add "$cidr" dev "$i" 2>/dev/null
  done
  [[ $found -eq 1 ]] || return 1
  sleep 2
  ping -c1 -W2 "$dev" >/dev/null 2>&1 && { DEV_IP="$dev"; return 0; }
  return 1
}

DEV_IP=""
if [[ -n "${ALIOTH_SSH_HOST:-}" ]]; then
  DEV_IP="$ALIOTH_SSH_HOST"
else
  [[ -n "$(usb_ifaces)" ]] || { echo "没找到 USB 网口 —— 线插着吗？" >&2; exit 1; }
  for c in "${CANDIDATES[@]}"; do
    # read 而不是 `set -- $c`：后者把调用者的位置参数覆盖掉，于是最后那条
    # exec 把候选地址当成要在设备上执行的命令发过去 ——
    #   bash: line 1: 172.16.42.1: command not found
    # 而要跑的那条命令一个字都没跑。实测踩过，症状是「ssh 连上了、退出 0
    # 的样子、但什么都没发生」。
    read -r cand_ip cand_cidr <<<"$c"
    try_addr "$cand_ip" "$cand_cidr" && break
  done
fi
[[ -n "$DEV_IP" ]] || {
  echo "设备不可达（试过 ${CANDIDATES[*]%% *}）。" >&2
  echo "正式系统起来了吗？sshd enable 了吗？（镜像里只在设了" >&2
  echo "ALIOTH_SSH_PUBKEY 时才装公钥、才 enable sshd）" >&2
  exit 1
}

exec ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o ConnectTimeout=8 -o LogLevel=ERROR "${USER_AT}@${DEV_IP}" "$@"
