#!/usr/bin/env bash
# ABL cmdline for SteamOS ARM. ABL picks the DTB by model, never put
# devicetree=/dtb= here. root must be PARTUUID (or /dev/…), the initramfs
# does not resolve root=UUID=.
#
# The SoC part (CMDLINE_SOC) comes from external-and-mods/kernel-<soc>/soc.env,
# source that first.
#
# Quiet by default: no kernel text, penguin logo or blinking cursor on the
# panel before Steam (the journal still has everything). CMDLINE_QUIET=0 gives
# the verbose console back (scripts/sd-debug-boot.sh sets it).

build_cmdline() {
  # A bare PARTUUID, or a full spec like PARTLABEL=userdata.
  local root="$1"
  [[ "$root" == *=* ]] || root="PARTUUID=${root}"
  [[ -n "${CMDLINE_SOC:-}" ]] || { echo "build_cmdline: source kernel-<soc>/soc.env first" >&2; return 1; }
  # No clk_ignore_unused / pd_ignore_unused: ROCKNIX boots without them and
  # they can upset display bring-up.
  local -a parts=(video=efifb:off)
  local -a soc
  read -ra soc <<<"${CMDLINE_SOC}"
  parts+=("${soc[@]}")
  if [[ "${CMDLINE_QUIET:-1}" == 1 ]]; then
    parts+=(quiet loglevel=0 systemd.show_status=0 rd.udev.log_level=0
            logo.nologo vt.global_cursor_default=0)
  else
    # loglevel=7, not 4. The comment above says the journal still has
    # everything -- true for phase 2, false for a phase-1 debug image,
    # which has no rootfs and therefore no journal at all. There the
    # console and the ramoops console record ARE the only record, and
    # loglevel=4 drops everything below KERN_ERR: a USB enumeration or a
    # driver probe (both KERN_INFO) never reaches either of them. That
    # was measured on alioth -- a USB-C keyboard attaching in host mode
    # printed nothing on the panel until /proc/sys/kernel/printk was
    # raised by hand.
    # console=ttyGS0 as well as the panel, and before it so that tty0
    # stays /dev/console.
    #
    # The USB gadget console is registered already -- f_acm's
    # gserial_alloc_line() auto-calls gs_console_init() for port 0, which
    # is acm.usb0 -- but gs_console_init sets only CON_PRINTBUFFER, never
    # CON_ENABLED, so printk sends it nothing unless the cmdline names it.
    # Measured on alioth: with console=tty0 alone the host's /dev/ttyACM0
    # stayed completely silent, and the only mention of it in a whole
    # boot's log was "printk: legacy console [ttyGS0] disabled" when the
    # configfs attribute was toggled off -- registered, never enabled.
    #
    # Naming it is what makes the host side a real log channel, and
    # CON_PRINTBUFFER then replays the entire ring buffer into it the
    # moment the gadget binds, so the host gets the boot log from
    # timestamp 0 even though the gadget only exists from about 1s. That
    # is the capability ramoops was supposed to provide here and cannot:
    # see docs/alioth.md on PSHOLD and DRAM retraining.
    #
    # A console= naming a device that never registers is a no-op, so this
    # costs nothing on a boot with no USB gadget.
    parts+=(console=ttyGS0 console=tty0 loglevel=7)
  fi
  parts+=(
    rw rootwait
    "root=${root}"
    rootfstype=ext4
    errors=remount-ro
  )
  if [[ -n "${KERNEL_CMDLINE_EXTRA:-}" ]]; then
    local -a extra
    read -ra extra <<<"${KERNEL_CMDLINE_EXTRA}"
    parts+=("${extra[@]}")
  fi
  printf '%s' "${parts[*]}"
}
