#!/usr/bin/env bash
# Stop NetworkManager from stripping the PC's address off alioth's USB
# debug link. Run once per PC; needs sudo.
#
# The problem: the phone's NCM gadget runs no DHCP server, so
# NetworkManager has nothing to configure on that interface. It settles on
# state "disconnected" and removes any address added by hand -- not once,
# but again and again, minutes apart. Every time it does, the link is
# indistinguishable from a phone that has stopped responding: 100% ping
# loss, connects time out. That misreading has eaten real debugging time.
#
# The fix: tell NetworkManager this one interface is not its business. The
# match is by MAC, not by name -- the name encodes the USB port path and
# changes when the cable moves, while the MAC is pinned by the phone's
# initramfs (initramfs/init, usb_shell, ncm.usb0/host_addr). Matching by
# driver instead would also catch USB tethering from any other phone.
#
# Needs an image built after the MAC pinning went in; on an older one the
# gadget still picks a random MAC each boot and this rule will not match.
# scripts/alioth-shell.sh re-adds the address either way.
set -euo pipefail

HOST_MAC=02:16:42:00:00:02
CONF=/etc/NetworkManager/conf.d/99-alioth-usbnet.conf

command -v nmcli >/dev/null || {
  echo "setup-host-usbnet: no NetworkManager here -- nothing to do." >&2
  echo "  If something else manages the interface, give it a static" >&2
  echo "  172.16.42.2/24 or leave the interface unmanaged." >&2
  exit 0
}

sudo tee "$CONF" >/dev/null <<EOF
# alioth USB debug gadget (SteamOSforAlioth). No DHCP on this link, so
# NetworkManager would mark it disconnected and strip the static address
# the debug tooling puts there. Matched by the gadget's pinned host-side
# MAC so no other USB-net device is affected.
[device-alioth-usbnet]
match-device=mac:$HOST_MAC
managed=0
EOF

echo "setup-host-usbnet: wrote $CONF"
sudo nmcli general reload conf
echo "setup-host-usbnet: NetworkManager reloaded; it will leave $HOST_MAC alone."
