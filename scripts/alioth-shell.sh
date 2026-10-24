#!/usr/bin/env bash
# Open a root shell on alioth over the USB network gadget, or run one
# command on it.
#
# The phone's initramfs puts an unauthenticated root shell on
# 172.16.42.1:23 (initramfs/init, usb_shell) -- nc, not telnetd: the
# ROCKNIX busybox has no telnetd applet, which is why every earlier image
# answered RST there.
#
# Two things have to be true for this to work, and the second one keeps
# coming undone:
#
#  1. The phone has to be running an image with steamos.usbshell=1.
#  2. The PC's end of the usbnet link needs 172.16.42.2/24. The gadget
#     offers no DHCP, so NetworkManager finds nothing to configure, marks
#     the interface "disconnected" and strips any address that was put
#     there by hand -- repeatedly, minutes apart, with no provocation.
#     Every time it does, this link looks exactly like a dead phone:
#     connects time out and pings get 100% loss. It cost three
#     misdiagnoses in one session before being recognised.
#
# So this script finds the interface by driver (the name follows the USB
# port: enp0s20f0u3u4i4 and friends), re-adds the address if it is gone,
# and then connects. Run scripts/setup-host-usbnet.sh once to stop
# NetworkManager touching the interface at all.
#
# This shell belongs to the initramfs, not to the installed system. Once
# the real root takes over, 172.16.42.1 and the nc shell are both gone --
# the installed system's own entry point is scripts/alioth-ssh.sh, which
# connects to sshd at 10.86.200.233 over USB NCM.
#
# The device end is `nc -e /bin/sh` with no pty: no line editing, no job
# control, and a command's output arrives when the command is done. For
# interactive work use /dev/ttyACM1 instead, which is a real tty.
#
# Usage:
#   scripts/alioth-shell.sh                 # interactive (Ctrl-C to quit)
#   scripts/alioth-shell.sh -c 'dmesg | tail'
#   scripts/alioth-shell.sh -c 'cmd' -t 15  # wait 15s for output
set -uo pipefail

PHONE=172.16.42.1
HOST_CIDR=172.16.42.2/24
PORT=23

cmd=""
wait_s=5
while [ $# -gt 0 ]; do
  case "$1" in
    -c) cmd="${2-}"; shift 2 ;;
    -t) wait_s="${2-}"; shift 2 ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed 's/^# \?//;$d'; exit 0 ;;
    *) echo "alioth-shell: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

command -v ncat >/dev/null || {
  echo "alioth-shell: need ncat (pacman -S nmap); plain 'telnet' will not" >&2
  echo "  do -- its IAC negotiation bytes land in the shell's stdin." >&2
  exit 1
}

# The usbnet interface, by driver rather than by name.
iface=""
for d in /sys/class/net/*; do
  drv="$(basename "$(readlink -f "$d/device/driver" 2>/dev/null)" 2>/dev/null)"
  case "$drv" in cdc_ncm|cdc_ether|cdc_subset) iface="$(basename "$d")"; break ;; esac
done
[ -n "$iface" ] && echo "alioth-shell: usbnet is $iface" >&2 || {
  echo "alioth-shell: no usbnet interface (cdc_ncm) -- is the phone plugged" >&2
  echo "  in and booted into an image with steamos.usbshell=1?" >&2
  exit 1
}

if ! ip -o -4 addr show "$iface" | grep -q "${HOST_CIDR%/*}"; then
  echo "alioth-shell: adding $HOST_CIDR to $iface (it was not there)" >&2
  sudo ip link set "$iface" up
  sudo ip addr add "$HOST_CIDR" dev "$iface" || exit 1
fi

if [ -n "$cmd" ]; then
  # Hold stdin open after the command: with no pty the shell's output
  # comes back whenever it comes back, and closing stdin ends the session.
  { printf '%s\n' "$cmd"; sleep "$wait_s"; } | timeout $((wait_s + 5)) ncat "$PHONE" "$PORT"
else
  echo "alioth-shell: connected to $PHONE:$PORT -- Ctrl-C to quit" >&2
  exec ncat "$PHONE" "$PORT"
fi
