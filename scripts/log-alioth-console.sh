#!/usr/bin/env bash
# Record alioth's kernel console (the ACM gadget console) to a file, across
# disconnects.
#
# This is the channel that actually captures a boot panic on this port, but
# only on an image whose cmdline names the gadget console: the console is
# registered without CON_ENABLED, so `console=ttyGS0` (cmdline.sh) is what
# makes printk send to it. Without that this file stays empty -- measured.
#
# ramoops cannot do this job: the region is reserved and the driver binds (verified on
# the phone), but nothing survives a reset, because the kernel reboots
# through PSHOLD (CONFIG_POWER_RESET_MSM) and mainline carries no IMEM
# restart_reason/warm-reset signalling, so XBL retrains DRAM on every boot
# and zeroes the area. Android's downstream kernel does signal it, which is
# why ramoops works there and not here. See docs/alioth.md.
#
# The console is /dev/ttyACM0 (acm.usb0, kernel console); /dev/ttyACM1 is
# the interactive shell. Both come and go with every reflash and every
# Type-C role switch, so this reopens in a loop rather than exiting.
#
# Usage: scripts/log-alioth-console.sh [device] [logfile]
#   Default: /dev/ttyACM0 -> work/logs/alioth-console-<date>.log
set -uo pipefail

dev="${1:-/dev/ttyACM0}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
log="${2:-${root}/work/logs/alioth-console-$(date +%Y%m%d).log}"
mkdir -p "$(dirname "$log")"

echo "log-alioth-console: $dev -> $log (Ctrl-C to stop)" >&2

# -echo matters: without it the host TTY echoes the phone's own output back
# at it, and the console feeds on itself.
while :; do
  if [[ -r "$dev" ]]; then
    stty -F "$dev" 115200 raw -echo 2>/dev/null || true
    printf '\n===== %s: attached to %s =====\n' "$(date -Is)" "$dev" >>"$log"
    # ts(1) is in moreutils and often absent; fall back to plain cat.
    if command -v ts >/dev/null 2>&1; then
      cat "$dev" | ts '[%Y-%m-%d %H:%M:%S]' >>"$log"
    else
      cat "$dev" >>"$log"
    fi
    printf '\n===== %s: %s went away =====\n' "$(date -Is)" "$dev" >>"$log"
  fi
  sleep 2
done
