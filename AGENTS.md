# Working on this repository as an agent

This file is for an LLM coding agent — Claude Code, Codex, Cursor, or a human
using one — that has been asked to **flash this port onto a phone** or **port it
to a different phone**. Read it before you touch anything. The rest of the
documentation is in Chinese; you can read it, and you will need it.

If you are here for something smaller (a typo, a script change), the short
version is: run the assertion suite, don't work around a failing assertion, and
don't touch the three partitions named under *Hard rules*.

---

## What this repository is

Valve's ARM64 SteamOS, built for the Steam Frame VR headset, running on a Xiaomi
`alioth` (Redmi K40 / POCO F3) — Snapdragon 870, `sm8250-ac`, Adreno 650 — with
a mainline 7.2.8 kernel underneath it, booting into Steam Game Mode.

Two things about the shape of the work, because they change how you should
behave here:

1. **Almost every bug in this port had its cause far away from its symptom.**
   A black screen was four independent defects stacked, none findable while the
   other three were present. "No sound" was a PipeWire permission manager three
   times in a row, and twice I concluded the hardware was damaged before
   checking. "GPU load always 0%" was a debugfs file that mainline does not have
   plus a DRM minor number taken by `simpledrm` during early boot. If you reason
   from a symptom to a cause here without measuring in between, you will be
   wrong, and the cost is measured in flashes and in hardware.

2. **The rules are checked, not remembered.** There are 14 assertion scripts.
   `flash-alioth.sh` refuses to run if the relevant ones fail. That is
   deliberate: a rule that lives only in a comment is a rule that gets violated
   by the next person who is in a hurry, and some of these rules are the only
   thing between a working phone and an EDL recovery.

---

## Hard rules

**Never write these partitions:**

| Partition | Why |
|---|---|
| `abl_a`, `abl_b` | The bootloader. Break it and the only way back is Qualcomm EDL 9008 mode with a signed firehose programmer. Nothing in this repo names these partitions, and `scripts/assert-alioth-boot-image.sh` fails if the string appears anywhere in the flash script, comments included. |
| `super` | Android's system partitions (8.5 GiB). Kept on purpose: it costs nothing and it means Android can be restored. |
| `vbmeta` | Never needed. The phone boots with `verifiedbootstate=orange` and vbmeta has never been written in this port's history. |

**`userdata` is writable, and that is irreversible.** It is where the SteamOS
rootfs goes, and it is Android's `/data`. Only `flash-alioth.sh --install`
writes it, only inside the marked `INSTALL-ONLY REGION`, and only after the
operator types `ERASE` at an interactive terminal.

**Never raise the amplifier gains.** `alioth-overlay/usr/share/alsa/ucm2/Xiaomi/Alioth/HiFi.conf`
sets `RCV Analog PCM Volume` to 4 and `LCV` to 10, and
`scripts/assert-alioth-overlay.py` asserts both the ordering and an absolute
ceiling. There is no limiter in the signal path (no redistributable Cirrus DSP
firmware, `PCM Source` is `ASP` bypass), the CS35L41's thermal protection
measures die temperature, and the voice coil has no sensor at all. The earpiece
has already been burned once at +18.5 dB with every fault bit clear. If a user
says "it's very loud", that is a warning, not a success.

**Never test audio with anything but `scripts/alioth-speaker-test.sh`.** Not
`speaker-test -D hw:0,0`, which bypasses PipeWire and runs at the amplifier's
full scale. The script bounds duration to 1–5 s and level to ≤ 1.0, generates
pink noise rather than a sine (crest factor 4 vs 1.41 — a sine puts an order of
magnitude more average power into the coil at the same peak voltage), reads the
fault registers before and after, and restores the system volume. It also fails
loudly when it cannot read the registers, because "no fault bits" and "nothing
was read" look identical otherwise.

**Never commit firmware extracted from a phone.** `a650_zap.mbn` and
`adsp.mbn` are Xiaomi-signed and not redistributable. Build artifacts go in
`work/`, which is git-ignored.

**Scrub device-unique identifiers before committing a dump or a log:** MAC
addresses, `ro.boot.cpuid`, `ro.boot.oled_wp`, `ro.boot.serialno`, touch
`fts_lockdown_info`, vbmeta digest and PARTUUID.

---

## Which document to read, in order

| You are doing | Read |
|---|---|
| Anything at all | this file, then [`README.md`](README.md) |
| Flashing, debugging, changing the kernel | [`docs/alioth.md`](docs/alioth.md) — conclusions only: every measured fact, every patch and why it exists, both acceptance reports. Start with the acceptance sections at the end and work backwards to the subsystem you care about. |
| Understanding why something is the way it is | [`docs/alioth-journal.md`](docs/alioth-journal.md) — the process, including the wrong turns. Most of the useful information about this hardware is in the wrong turns. |
| Hardware identity (panel model, touch IC, battery limits, pin assignments) | [`docs/alioth-hardware.md`](docs/alioth-hardware.md) |
| Adding the user's own Windows games as non-Steam shortcuts | [`docs/custom-games.md`](docs/custom-games.md) |
| The design the work was planned against | [`docs/superpowers/specs/`](docs/superpowers/specs) |

`docs/alioth.md` is long (~2400 lines) and organised chronologically with
section headers that state conclusions. Grep it. Do not read it top to bottom
before starting; do read the section that covers the subsystem you are about to
touch, because most sections exist to record a wrong answer that looked right.

---

## Task A: flash this onto an alioth

Prerequisites the agent cannot supply: an unlocked bootloader, physical access,
and the user's informed consent to lose everything on the phone.

```bash
# 1. Kernel, DTB, initramfs. Needs docker/podman, a ROCKNIX checkout at tag
#    20261001, and a static aarch64 busybox — see docs/alioth.md 前置依赖.
./build-alioth-kernel.sh

# 2. Valve's rootfs. Several GB, idempotent, safe to re-run.
scripts/fetch-steamos-rootfs.sh

# 3. The two device-signed blobs, from the user's OWN phone. Not optional:
#    Xiaomi's TrustZone rejects every generically-signed copy in linux-firmware,
#    and the result is a black screen with no audio.
scripts/extract-alioth-firmware.sh <modem-dir> <vendor-dir> work/alioth-fw

# 4. Assemble. Refuses to start without ALIOTH_FW_DIR, by design.
ALIOTH_FW_DIR=work/alioth-fw ./make-steamos-alioth.sh --install

# 5. Verify before writing anything.
for t in scripts/assert-alioth-*; do "$t" || echo "FAILED: $t"; done

# 6. Flash. Prints what it will do, then waits for the operator to type ERASE.
./flash-alioth.sh --install
```

Step 6 erases both `dtbo` partitions, writes the same boot image to both slots,
writes `userdata`, and re-declares the active slot. First boot grows the
filesystem and marks the slot successful once the system is actually up.

**Do not type `ERASE` on the user's behalf.** The prompt requires an
interactive terminal specifically so that a script — or an agent — cannot
satisfy it.

### Iterating on the kernel afterwards

Do not make the user hold volume-down + power for every kernel change. The
installed system can flash its own boot slot:

```bash
./build-alioth-kernel.sh && ./make-steamos-alioth.sh --kernel-only
scripts/alioth-selfflash-boot.sh work/steamos-alioth/boot.img --reboot
```

It sends the image over USB networking, verifies it by SHA-256 on the device,
and reboots. **It sends the modules too, by default** — do not pass
`--no-modules` unless you know the change is entirely built-in. Half of this
port is `=m` (`snd-soc-sm8250`, `ath11k`, `pci-pwrctrl-pwrseq`), a boot image
carries only the kernel and the device tree, and replacing boot alone leaves the
device loading the old `.ko` files under an identical version string — so
nothing reports an error and a whole round of work is silently lost. That
happened on 2026-10-24 with the audio machine driver. If you need modules
without a new kernel, `scripts/alioth-push-modules.sh` does that part alone.

Device access: `scripts/alioth-ssh.sh` (sshd in the installed system, needs the
image to have been built with `ALIOTH_SSH_PUBKEY`), `scripts/alioth-shell.sh`
(the unauthenticated root shell in the initramfs, phase-1 debugging),
`scripts/log-alioth-console.sh` (kernel console over USB ACM).

---

## Task B: port this to a different phone

This repo is one device. Porting means writing a new sibling of each
device-specific piece. Work in this order, because each step is how you find
out whether the previous one worked.

| Order | What | Where alioth's version lives |
|---|---|---|
| 1 | Confirm **4K pages** are achievable on the SoC. FEX requires them absolutely. If the vendor kernel and the hardware force 16K/64K, stop — the project has no point on that device. | `CONFIG_ARM64_4K_PAGES=y`, asserted in `scripts/assert-alioth-boot-image.sh` |
| 2 | Device tree. Start from postmarketOS's if one exists; it is usually closer to working than anything you will write. | `external-and-mods/kernel-sm8250/dts/sm8250-xiaomi-alioth.dts` |
| 3 | Boot image format. Which header version the bootloader accepts, whether `dtbo` must be erased, what the kernel command line needs. Measure this from the device's own UART or USB console, not from a wiki. | `make-steamos-alioth.sh` (`KERNEL_CMDLINE_EXTRA`, `mkbootimg-v0.py`) |
| 4 | A log channel that survives a reset, before you need it. On alioth `ramoops` was ruled unusable (PSHOLD hard reset loses the record) and the USB ACM console replaced it. Getting this wrong means every later failure looks identical: a black screen. | `docs/alioth.md` 日志通道的真相 |
| 5 | Panel and touch. Both were forward-ports; the API adaptation is small, the hard part is the panel's init sequence and the touch IC's firmware state. | patches `0017`, `0018`, `0020`–`0024` |
| 6 | Device-signed firmware. Find out which blobs your SoC's TrustZone insists on. | `scripts/extract-alioth-firmware.sh`, `scripts/assert-alioth-firmware.sh` |
| 7 | Audio. Expect this to be the worst part. On alioth it was wrong at four layers simultaneously and needed three kernel patches plus a UCM profile. | patches `0025`–`0027`, `alioth-overlay/usr/share/alsa/ucm2/` |
| 8 | Input. A composite device profile so the controller appears to Steam as a Deck pad. | `alioth-overlay/etc/inputplumber/` |
| 9 | Battery and charging limits. Get `voltage-max-design-microvolt` and the charge current ceiling from the vendor device tree, and write them explicitly. | the DTS, asserted in `scripts/assert-alioth-dtb.py` |
| 10 | Write the assertions as you go, not at the end. Each one should encode a mistake you actually made. | `scripts/assert-alioth-*` |

Three rules that earned their place on this port:

- **Verify the premise on the real device before you change code for it.** More
  than one round here was spent fixing something that was never broken. Four
  separate conclusions in the touch-controller investigation were disproved by
  measuring on stock Android afterwards.
- **In phase 1, `=m` equals absent.** With no rootfs there is no `modprobe`, so
  a module is never loaded and the symptom is an absent device, not a missing
  module. `CONFIG_PCI_PWRCTRL_PWRSEQ=m` cost a round this way; so did
  `CONFIG_TYPEC_MUX_FSA4480=m`.
- **When two guesses in a row miss, stop guessing and print the data.** The
  ADSP returned `EBADPARAM` twice against two plausible theories. The third
  round added a configuration dump and the answer was visible immediately:
  24-bit samples in 16-bit slots.

---

## The assertion suite

Run all of it before you claim anything works. Several scripts need an argument
or root; the two noted below are the exceptions to `for t in scripts/assert-alioth-*`.

| Script | Gates |
|---|---|
| `assert-alioth-boot-image.sh` | kernel config, cmdline tokens, symbols, and the partition-name bans in the flash script. `flash-alioth.sh` runs this before any write. |
| `assert-alioth-dtb.py` | the built DTB: compatibles, panel, touch, battery limits, audio backend and pinctrl. Takes the `.dtb` path. |
| `assert-alioth-flash.sh` | the flash script's behaviour, against a fake `fastboot`: banned partitions, both slots, the `ERASE` prompt, refusal to write the active slot, firmware provenance, and the `--test`/`--install` code isolation. |
| `assert-alioth-kit.sh` | the built kit: filesystem format, size, fstab, firmware signatures, sudoers. Group B needs `--install` output and `sudo`. |
| `assert-alioth-overlay.py` / `-applied.sh` | the overlay's content, and that applying it to a rootfs lands every file with the right mode in both the lower directory and `/etc`'s overlayfs upper. |
| `assert-alioth-speaker-test.sh` | that the audio-test guardrails still exist — level and duration bounds, and that the fault decoder fails when it cannot read. |
| `assert-alioth-firmware.sh` | that the two blobs are the device's own and not linux-firmware's. |
| `assert-alioth-writeboot.sh` | the device-side boot writer. Needs root. |
| `assert-alioth-markslot.py`, `-modules.py`, `-firstboot.sh`, `-devr.sh`, `-rootfs.sh` | GPT slot marking, the module set, first-boot growth, de-VR-ing, the assembled rootfs. |

**If an assertion fails, do not work around it.** Every one of them exists
because something it checks was once wrong in a way that was expensive to find.
Either the code is wrong, or the assertion has become wrong and you should fix
the assertion deliberately and say so. Deleting an assertion to make a run green
is the one thing in this repository that is actually forbidden.

---

## Reporting back

Say what you measured, not what you expect. "GPU load reads 42 in
`/sys/kernel/debug/dri/0/perf_now`" is a result; "the GPU should be working now"
is not. If a step was skipped, say it was skipped. If a test failed, paste the
output. The user of this repository has to decide whether to spend an
irreversible flash on your conclusion, and they can only do that from evidence.

Commit messages here are in Chinese and state the cause, not the change — the
diff already shows the change. Match that if you contribute.
