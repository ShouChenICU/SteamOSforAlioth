<h1 align="center">SteamOS for alioth</h1>

<p align="center"><strong>Valve's ARM SteamOS, running on a Redmi K40 / POCO F3</strong></p>

<p align="center">
  A Snapdragon 870 phone from 2021 booting straight into Steam Game Mode —
  mainline kernel, Adreno 650 on Turnip, x86 games through FEX and Proton,
  and the stock bootloader left exactly where it was.
</p>

<p align="center">
  <a href="#status"><img alt="status" src="https://img.shields.io/badge/status-Game%20Mode%20works-2ea043?style=flat"></a>
  <img alt="device" src="https://img.shields.io/badge/device-alioth%20(K40%20%2F%20POCO%20F3)-7c5cf0?style=flat">
  <img alt="SoC" src="https://img.shields.io/badge/SoC-Snapdragon%20870%20%C2%B7%20sm8250-18181a?style=flat">
  <img alt="kernel" src="https://img.shields.io/badge/kernel-7.2.8%20mainline-18181a?style=flat">
  <a href="LICENSE"><img alt="license" src="https://img.shields.io/badge/license-GPL--2.0-18181a?style=flat"></a>
  <a href="README.zh-CN.md"><img alt="中文" src="https://img.shields.io/badge/README-%E4%B8%AD%E6%96%87-blue?style=flat"></a>
</p>

<p align="center">
  <a href="#for-agents">For AI agents</a> ·
  <a href="#what-works">What works</a> ·
  <a href="#screenshots">Screenshots</a> ·
  <a href="#build-it">Build it</a> ·
  <a href="docs/custom-games.md">Your own games</a> ·
  <a href="#install-it">Install it</a> ·
  <a href="#how-it-was-done">How it was done</a> ·
  <a href="#credits">Credits</a>
</p>

<p align="center">
  <img src="docs/images/game-mode.jpg" alt="Steam Game Mode running on a Redmi K40" width="100%">
</p>

<p align="center"><sub>
  Game Mode on the phone's own panel. The Steam UI is 16:9, so gamescope's
  <code>fit</code> scaler leaves 240&nbsp;px of black on each side of the
  2400×1080 screen — that is what the device really looks like.
</sub></p>

---

> [!WARNING]
> **Installing this destroys everything on the phone's `userdata` partition**,
> which is Android's `/data` — apps, photos, messages, all of it. The install
> also writes the kernel to both A/B slots and erases both `dtbo` partitions,
> so Android will not boot afterwards even with a fresh `/data`
> ([getting Android back](#getting-android-back)).
>
> Not affiliated with, endorsed by, or supported by Valve or Xiaomi. There is
> no warranty and no support promise. Read [`docs/alioth.md`](docs/alioth.md)
> before you flash anything.

## About

Valve ships an ARM64 build of SteamOS for the Steam Frame, a VR headset. This
project takes that image, puts a mainline Linux kernel underneath it for the
Xiaomi `alioth` (Redmi K40 / POCO F3, Snapdragon 870), and makes the phone boot
into Steam's Game Mode as a handheld — screen, touch, speakers, Bluetooth
controller, battery, Wi-Fi, GPU.

What makes `alioth` an interesting target is that none of it is a given. The
Frame image expects a VR headset's hardware and a VR session manager; the phone
has an AMOLED panel wired for portrait, two Cirrus amplifiers hanging off a TDM
bus nobody had configured in mainline, and a Qualcomm bootloader that is picky
about boot images. Each of those is a bug with a long distance between its cause
and its symptom, and every one of them is written up in the docs.

**Three choices shape this port:**

- **The stock Xiaomi bootloader stays.** No OpenABL, no ROCKNIX ABL, no
  `abl_a`/`abl_b` writes of any kind. Those partitions are the one thing on
  this phone that can only be repaired over EDL 9008, so the port never names
  them. Recovery is always `volume-down + power` → fastboot.
- **Android's system partitions stay.** `super` (8.5 GiB) is never written.
  SteamOS lives in `userdata`, which is where the boot command line was
  pointing all along.
- **Everything is asserted, not remembered.** 14 assertion scripts in
  [`scripts/`](scripts) check the DTB, the boot image, the overlay, the flash
  script, the module set and the kernel config. `flash-alioth.sh` refuses to
  run if they fail, refuses to write the slot the phone currently boots from,
  and keeps every line of code that can touch `userdata` inside one marked
  region that the kernel-iteration path cannot reach.

<a id="status"></a>

## Status

**Phase 1 (kernel bring-up) and phase 2 (system) are both done.** The phone
boots into Game Mode, signs into Steam over touch, and runs Windows indie games
through Proton. 11 of the 12 phase-2 acceptance items pass; the twelfth needs an
overnight test.

This is a personal port of one phone, not a distribution. **There are no
prebuilt images** — the Valve rootfs and the Xiaomi-signed firmware blobs it
needs are not mine to redistribute, so the only path is to
[build it yourself](#build-it) from your own phone's firmware.

<a id="for-agents"></a>

## If you are an AI agent

Read **[`AGENTS.md`](AGENTS.md)** first, before any other file and before you
run anything. It is written for you specifically, and it covers:

- the three partitions that must never be written, and why one of them costs an
  EDL recovery
- the amplifier gains that must never be raised — the earpiece has already been
  burned once, with every fault bit clear
- the exact flashing sequence, where the irreversible step is, and why you must
  not type the confirmation on the user's behalf
- the order to port this to a different phone, and the three rules this port
  paid for: verify the premise on the device first, `=m` means absent in phase
  1, and when two guesses miss, print the data instead of guessing a third time
- what each of the 14 assertion scripts gates, and why working around a failing
  one is the only thing here that is forbidden

The rest of the documentation is in Chinese. `AGENTS.md` says which file
answers which question, and in what order to read them.

<a id="what-works"></a>

## What works

| | Status | Notes |
|---|---|---|
| Boots straight into Game Mode | ✅ | gamescope on DRM, landscape, VR session manager removed |
| Display (Samsung AMS667XX01) | ✅ | 2400×1080 @ 60 Hz, panel reports `rotation=270`, compositor runs landscape |
| Touch (Focaltech FT8756) | ✅ | Interrupt-driven; 1 dropped frame in 5146 |
| GPU (Adreno 650) | ✅ | Mesa Turnip; needs the phone's own signed `a650_zap.mbn` |
| x86 games (FEX + Proton 11 ARM64) | ✅ | 4K pages confirmed, which FEX requires absolutely |
| Performance overlay (mangoapp) | ✅ | Including a real GPU-busy figure — see [patch 0028](external-and-mods/kernel-sm8250/patches/0028-drm-msm-export-gpu-utilization-through-debugfs.patch) |
| Speakers (2× Cirrus CS35L41) | ✅ | Tertiary TDM backend; needed three kernel patches and a UCM profile |
| Wi-Fi + Bluetooth (QCA6390) | ✅ | Bluetooth address is generated but stable across reboots, so pairings persist |
| Bluetooth controller | ✅ | Shows up as a Steam Deck pad via InputPlumber |
| Volume keys / power button | ✅ | Steam quick-access menu; suspend and resume |
| Charging (PM8150B) | ✅ | Float voltage clamped to 4.45 V. No fast charge |
| Battery level in Game Mode | ✅ | |
| Plugged in while playing | ✅ | Battery 38 °C, hottest SoC sensor 61 °C |
| USB-C host mode | ✅ | Wired controllers and keyboards enumerate |
| Device-side kernel flashing | ✅ | `scripts/alioth-selfflash-boot.sh` — a kernel iteration needs no cable and no button presses |
| Overnight standby drain | ⏳ | The one untested acceptance item |
| Microphone | ❌ | `&vamacro` and `&lpass_tlmm` are disabled in this DTS, so there is no capture path at all |
| Camera, NFC, FM, IR | ❌ | Out of scope |
| Android dual boot | ❌ | Out of scope, by design |

<details>
<summary><strong>Hardware notes worth knowing before you start</strong></summary>

- **The speakers have no protection DSP.** The CS35L41 pair can run Cirrus
  speaker-protection firmware, but that `wmfw`/`bin` pair is not
  redistributable, so the signal path is a straight bypass with no limiter.
  Gains are set conservatively in the UCM profile and the earpiece amp is
  deliberately 6 dB below the bottom one. **Do not raise them.** I burned a
  smell out of the earpiece once already; the write-up is in `docs/alioth.md`
  under *事故：把听筒烧出了糊味*.
- **Two firmware blobs must come from your own phone.** `a650_zap.mbn` (GPU)
  and `adsp.mbn` (audio) go through Qualcomm's PAS path and are verified by
  this phone's TrustZone, which rejects every generically-signed copy in
  `linux-firmware`. Same filenames, same byte counts, different signature —
  so a wrong one looks correct in every way except that the screen stays
  black.
- **The RTC lies.** It reads about 64 years fast on a cold boot, which breaks
  PAM and every HTTPS certificate until NTP catches up. The port installs a
  `clock-epoch` floor to keep the first boot sane.

</details>

<a id="screenshots"></a>

## Screenshots

<table>
<tr>
<td width="50%"><img src="docs/images/controller.jpg" alt="Launching a game, with the Steam Deck controller template"></td>
<td width="50%"><img src="docs/images/in-game.jpg" alt="Ori and the Blind Forest running through FEX and Proton"></td>
</tr>
<tr>
<td><sub>Launching a game. A Bluetooth controller arrives as a Steam Deck pad through InputPlumber, so Steam offers the Deck layout — the phone has no buttons of its own to offer.</sub></td>
<td><sub><i>Ori and the Blind Forest: Definitive Edition</i> — a Windows x86 build, running through FEX and Proton 11 ARM64 on an Adreno 650 with Mesa Turnip.</sub></td>
</tr>
<tr>
<td colspan="2"><img src="docs/images/perf-overlay.jpg" alt="The mangoapp performance overlay in game" width="100%"></td>
</tr>
<tr>
<td colspan="2"><img src="docs/images/custom-game.jpg" alt="Touhou 07 running as a non-Steam game" width="100%"></td>
</tr>
<tr>
<td colspan="2"><sub>Your own Windows games work too. This is <i>Touhou 07: Perfect Cherry Blossom</i> from 2003 — a 32-bit x86 binary on DirectX 8, running through FEX's wow64 path with DXVK's <code>d3d8.dll</code> on Turnip. <a href="docs/custom-games.md">How to add your own</a> (in Chinese).</sub></td>
</tr>
<tr>
<td colspan="2"><sub>The same session with the mangoapp overlay up: 43 FPS, CPU 53%, GPU 62%, 5.3 GiB RAM, 1.3 GiB VRAM. The GPU figure comes from <code>/sys/kernel/debug/dri/0/perf_now</code>, exported by patch 0028 — mainline msm has no such file, and MangoHud hardcodes <code>dri/0</code>, so simpledrm also has to be blacklisted at initcall time for msm to get minor 0.</sub></td>
</tr>
</table>

All five are real captures off the device, not mockups. The first three came from `gamescopectl screenshot`; the one with the overlay needs gamescope's debug screenshot atom
(`xprop -root -f GAMESCOPECTRL_DEBUG_REQUEST_SCREENSHOT 8c -set GAMESCOPECTRL_DEBUG_REQUEST_SCREENSHOT 0`),
because `gamescopectl screenshot` only captures the base plane and the overlay is not on it.

<a id="build-it"></a>

## Build it

Host: x86_64 Linux. The aarch64 toolchain runs in a container; you need about
40 GiB free.

**Prerequisites**

| | For |
|---|---|
| `docker` or `podman` | the kernel build container (Fedora 43) |
| `dtc` (with `fdtget`), `git`, `curl`, `python3`, `rsync`, `android-tools` | builds, assertions, flashing |
| A static **aarch64** busybox | the initramfs |
| A [ROCKNIX](https://github.com/ROCKNIX/distribution) checkout at tag `20261001` | the kernel baseline |
| Your phone's `modem_a` and `vendor_a` contents | the two signed firmware blobs |

The exact commands for the busybox and ROCKNIX pieces are in
[`docs/alioth.md` → 前置依赖](docs/alioth.md).

**Then**

```bash
# 1. Kernel + DTB + initramfs  (~6 min on 20 threads)
./build-alioth-kernel.sh

# 2. Valve's rootfs            (a few GB, idempotent — safe to re-run)
scripts/fetch-steamos-rootfs.sh

# 3. The two signed blobs, from your own phone's partitions
scripts/extract-alioth-firmware.sh <modem-dir> <vendor-dir> work/alioth-fw

# 4. Assemble the installable image
ALIOTH_FW_DIR=work/alioth-fw ./make-steamos-alioth.sh --install
```

Optional but recommended — set `ALIOTH_SSH_PUBKEY` on step 4 and the image
comes up with `sshd` enabled for your key, plus a narrow `sudoers` rule that
lets the device flash its own kernel. Without that variable the image gets no
key, no `sshd` and not one extra `sudoers` line.

Run the suite before you flash anything:

```bash
for t in scripts/assert-alioth-*; do "$t"; done
```

<a id="install-it"></a>

## Install it

You need an **unlocked bootloader** (Xiaomi's own unlock tool, with its waiting
period). Back up anything you want to keep off the phone first — step 3 is
irreversible.

```bash
# phone in fastboot: hold volume-down + power
./flash-alioth.sh --install
```

It prints what it is about to do and waits for you to type `ERASE`. What it
does:

1. `erase dtbo_a` + `erase dtbo_b` — the stock overlay would otherwise be
   merged onto the mainline device tree and fail
2. `flash boot_a` + `flash boot_b` — the same image to both slots, so a
   bootloader fallback lands somewhere that boots
3. `flash userdata` — **the irreversible one**
4. `--set-active=<current slot>` — clears any leftover `unbootable` flag and
   retry counters

First boot grows the filesystem to the full 106 GiB partition and marks the
slot successful once the system is actually up.

Iterating on the kernel afterwards does **not** need a cable:
`scripts/alioth-selfflash-boot.sh` sends a new boot image over USB networking,
verifies it by SHA-256 on the device, and reboots.

<a id="getting-android-back"></a>

### Getting Android back

`super` was never written, so Android's system is still there. Getting it to
boot again needs three things from a stock fastboot ROM for your model:

```bash
fastboot flash boot_a <stock boot.img>     # and boot_b
fastboot flash dtbo_a <stock dtbo.img>     # and dtbo_b
fastboot erase userdata                    # Android formats /data on first boot
```

Keep a copy of that ROM before you start. If the phone will not boot at all,
`volume-down + power` always reaches fastboot — that path lives in the
bootloader and does not care what is in the slots.

<a id="how-it-was-done"></a>

## How it was done

The documentation is the point of this repo as much as the code is, and it is
written in Chinese.

| | |
|---|---|
| [`docs/alioth.md`](docs/alioth.md) | Conclusions: every measured fact, every patch and why it exists, both phase acceptance reports |
| [`docs/alioth-journal.md`](docs/alioth-journal.md) | The process — including the wrong turns, which is where most of the useful information is |
| [`docs/alioth-hardware.md`](docs/alioth-hardware.md) | The hardware map |
| [`docs/custom-games.md`](docs/custom-games.md) | Running your own Windows games on it as non-Steam shortcuts |
| [`docs/superpowers/specs/`](docs/superpowers/specs) | The design spec the work was planned against |
| [`AGENTS.md`](AGENTS.md) | For an agent asked to flash this or port it: the hard rules, the sequence, and what each assertion gates |

A few write-ups that stand on their own, if you are porting to another
Snapdragon phone:

- **The black screen was four separate bugs stacked** — none of which could be
  found while the other three were present.
- **The speaker path was wrong at four layers at once** — the machine driver
  never told the codec its bit clock, the backend was MI2S when the data line
  physically goes to the tertiary TDM group, Valve's image has ALSA UCM
  handling switched off, and a WirePlumber script hardcodes a sink name that
  happens to be ours. Three kernel patches came out of it.
- **GPU utilisation read 0 % forever** — MangoHud's `msm` backend reads a
  debugfs file mainline does not have, and then reads it from the wrong DRM
  minor because `simpledrm` took minor 0 during early boot.
- **A `sudoers` file named `50-` instead of `zz-`** silently loses to the
  image's own `wheel` rule, and the symptom is indistinguishable from the rule
  not being installed.

## Repository layout

```
AGENTS.md                  read this first if you are an agent
build-alioth-kernel.sh     kernel + DTB + initramfs
make-steamos-alioth.sh     --kernel-only | --install  (assembles the rootfs)
flash-alioth.sh            --boot | --test | --install
alioth-overlay/            what this port adds to Valve's rootfs
external-and-mods/
  kernel-sm8250/dts/       sm8250-xiaomi-alioth.dts
  kernel-sm8250/patches/   0017-0018 panel+touch, 0025-0027 audio, 0028 GPU load
scripts/
  assert-alioth-*          the assertion suite
  alioth-selfflash-boot.sh flash a kernel from the running device
  alioth-speaker-test.sh   the only safe way to test audio (see the warning above)
docs/                      the write-ups
```

Three pieces come from the upstream project this is forked from, kept because
the build genuinely needs them: `external-and-mods/kernel-common` (the build
container and `mkbootimg-v0.py`), `external-and-mods/kernel-sm8250` (the device
tree and patch series), and `sm8250-overlay` + `steamos-overlay`, which
`apply-alioth-overlay.sh` and `apply-alioth-devr.sh` install from. Everything
else upstream carried — a dozen other devices' overlays, kernels, image
scripts and docs — was removed before publishing, so merging from upstream is
no longer a cheap operation. Their attribution is in [CREDITS.md](CREDITS.md).

## Contributing

Issues and pull requests are welcome, especially from anyone with an `alioth`
willing to test. Two requests:

- If you touch anything under `external-and-mods/kernel-sm8250/` or
  `alioth-overlay/`, run the assertion suite and say so in the PR.
- Never commit firmware extracted from a phone, and scrub device-unique
  identifiers (MAC addresses, `ro.boot.cpuid`, touch lockdown info, vbmeta
  digests) out of any log you paste.

## Credits

This port started from the work of
**[hashtagbasit/SteamOS-ARM-Port](https://github.com/hashtagbasit/SteamOS-ARM-Port)**,
which did the hard part first: making Valve's Frame image behave like a handheld
OS at all. Four pieces of it are still here and are what the build runs on —
`external-and-mods/kernel-common`, `external-and-mods/kernel-sm8250`,
`sm8250-overlay` and `steamos-overlay` — so that project is the reference to
read alongside this one, and the place to look for the dozen other devices it
supports.

The kernel baseline comes from **[ROCKNIX](https://github.com/ROCKNIX/distribution)**.
The `alioth` device tree and the panel and touch drivers were forward-ported
from **[postmarketOS / pmaports](https://gitlab.postmarketos.org/postmarketOS/pmaports)**
and mainline. Every upstream and third-party component kept here is credited in
[CREDITS.md](CREDITS.md).

## License

Scripts and overlays are GPL-2.0. Everything under `external-and-mods/` keeps
its own license. See [LICENSE](LICENSE).

Steam and SteamOS are trademarks of Valve Corporation, used here only to say
what this is built on. Please do not ask Valve — or Xiaomi — about any of it.
