# 阶段 2：完整系统 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把阶段 1 已验证的 alioth 内核装成一台开机直接进 Game Mode、能用蓝牙手柄跑 Proton 游戏的掌机。

**Architecture:** 复用 Valve Frame 的 aarch64 rootfs（一行不动），alioth 特有配置全部集中在新的 `alioth-overlay/`，由 `scripts/apply-overlays.sh` 的一个新设备选择器装入。打包照 REDMAGIC 6 的手机模型：单个 ext4 刷进 `userdata`，首次开机扩展到整个分区。

**Tech Stack:** Valve SteamOS Frame rootfs (glibc, aarch64)、gamescope、InputPlumber → deck-uhid → hid-steam、FEX + Proton 11 ARM64 + DXVK 2.x、Mesa Turnip、ALSA UCM2、qbootctl

**Spec:** `docs/superpowers/specs/2026-10-22-steamos-alioth-port-design.md`（§6 启动链/分区/安装/回滚、§7 用户空间、§8 阶段 2 验收）

**阶段 1 结论（本计划的输入）:** `docs/alioth.md`「阶段 1 验收：通过（2026-10-23）」节。内核、面板、触摸、UFS、充电、USB-C host、WiFi、蓝牙均已在真机验证。

## Global Constraints

- **禁止写入 `super`**（8.5 GiB）—— 刻意保留，格一下 `userdata` 即可复活 Android。
- **禁止写入 `abl_a` / `abl_b`** —— bootloader，砖了只能走 EDL 9008。
- **`userdata`（sda35，106 GiB）现在可写** —— 2026-10-23 授权，见 `docs/alioth.md`。不可逆。
- **`--test` 模式的代码路径里不得出现任何写 `userdata` 的代码**（spec §6.5，物理隔离）。
- **`--install` 必须要求输入 `ERASE` 二次确认**（spec §6.5）。
- 刷机脚本必须读 `fastboot getvar current-slot`；目标槽等于活动槽则拒绝并退出非零（阶段 1 既有约束，继续生效）。
- **fastboot 单次传输上限 768 MiB** —— `userdata.img` 必须小于此值，靠首次开机 resize 补足（spec §6.1）。
- `fastboot erase dtbo_<slot>` 是必需步骤（阶段 1 已确认）。
- 电池：`voltage-max-design-microvolt` ≤ 4450000，充电电流上限显式写出 —— 由 `scripts/assert-alioth-dtb.py` 强制，每轮构建重跑。
- 面板方向靠 DT `rotation = <270>`，不在 userspace 里转。
- 游戏路径只走 Proton：`x86_64 → FEX → Proton 11 ARM64 → DXVK 2.x → Turnip → A650`。**不做 D3D12 / DXVK 3 / Proton Experimental**。
- 不写温控服务、不做外接显示、不装 KDE 桌面（spec §10 YAGNI）。

## 裁决：spec §7.5「不加载充电驱动」作废

spec 写「不加载充电驱动，社区 PM8150B 驱动会把上限设到约 4.87 V」。阶段 1 实测推翻了这个前提：驱动从电池节点读 `voltage-max-design-microvolt` 再 `clamp(…, 3600000, 4450000)`，而 alioth 的 DTS 钉死 4450000 且有断言强制。真机读数 `Charging` / 4312977 µV，全程无异常。

而且 spec §8 的验收项「Game Mode 里能看到电量」**需要**这个驱动提供 `power_supply`。两者不可兼得，以实测为准：**加载充电驱动**。代价若错：电池过充风险 —— 由 `assert-alioth-dtb.py` 第 6 条断言兜底，每轮构建都跑。

## spec 里不需要新任务的条目

**§7.2 显示** —— 阶段 1 已经做完：横屏靠 DTS 的 `rotation = <270>`（由
`scripts/assert-alioth-dtb.py` 断言），命令模式面板的真实 vblank 时间戳靠上游
patch 0012，两者都已在真机工作。本阶段只在 Task 8 验收，不写新代码。预期行为：
命令模式面板**切换刷新率 = 完整 modeset**，在 Steam 里改帧率会黑屏闪一下，
REDMAGIC 6 文档记录了同样现象，属正常，不要当 bug 去修。

**§7.5 热管理** —— spec 明确「先不写服务」，等实测到过热再决定。Task 8 的
「边充边玩温度不超过 45°C」是这个决定的检验点。

## Review Focus

- **`--install` 写错分区**：脚本收到非预期的 `current-slot` 输出（空、`a`/`b` 之外的值、fastboot 报错）时，必须拒绝而不是当作默认值继续 —— 写错槽或写到 `super` 是不可逆的。Task 6 测。
- **`userdata.img` 越过 768 MiB**：rootfs 装了 Steam 种子之后镜像会长大，越线时 fastboot 会在刷了一半的时候失败，留下不可启动的系统。Task 5 测。
- **配置写进了 `$R/etc` 却没进 `/var/lib/overlays/etc/upper`**：SteamOS 的 `/etc` 是 overlayfs 且挂载很晚，只写下层的文件开机时看不到 —— 表现为「配置明明装了却不生效」，极难归因。Task 3 测。
- **首次开机 resize 被打断**：掉电或 reboot 落在 `resize2fs` 中间，下次开机必须能识别未完成状态并重试，而不是把半扩展的文件系统当作正常。Task 7 测。
- **`pci-pwrctrl-pwrseq` 无人加载**：没有任何东西依赖它，一旦 rootfs 的模块加载策略漏掉它，WiFi 和蓝牙会一起消失，而症状是「PCIe 总线上什么都没有」，看起来像硬件故障。Task 4 测。

---

### Task 1: Valve rootfs 提取与基线断言

**Files:**
- Create: `scripts/assert-alioth-rootfs.sh`
- Modify: `docs/alioth.md`（追加 rootfs 基线结论）

**Interfaces:**
- Consumes: `scripts/extract_rootfs.py`（上游，零改动）
- Produces: `${STEAMOS_WORK}/rootfs`（共享 Valve rootfs 目录）；`scripts/assert-alioth-rootfs.sh <rootfs-dir>` 退出码 0 = 全部断言通过

- [ ] **Step 1: 用上游脚本提取 rootfs**

Run: `python3 scripts/extract_rootfs.py`（参数照其 `--help`）
Expected: `${STEAMOS_WORK}/rootfs` 下有 `usr/bin/bash`、`usr/bin/gamescope`

- [ ] **Step 2: 写断言脚本 `scripts/assert-alioth-rootfs.sh`**

每条断言打印 `PASS`/`FAIL` 加证据，任一失败则退出非零。断言内容：

```
aarch64            file usr/bin/bash 含 "ARM aarch64"
gamescope 存在     usr/bin/gamescope 可执行
FEX 存在           usr/bin/FEXInterpreter 或 usr/lib/fex-emu 存在
Turnip 存在        usr/lib/aarch64-linux-gnu/dri 下有 freedreno/turnip
Proton 11 ARM64    usr/share/steam 或 steamapps 下存在 Proton 11 条目
InputPlumber 存在  usr/bin/inputplumber
/etc overlayfs     var/lib/overlays/etc/upper 目录存在
```

- [ ] **Step 3: 运行断言**

Run: `./scripts/assert-alioth-rootfs.sh ${STEAMOS_WORK}/rootfs`
Expected: `全部断言通过`

- [ ] **Step 4: 核实 spec §7.3 的待验证项 —— 镜像是否自带 x86/i386 FEX Mesa**

Run: `find ${STEAMOS_WORK}/rootfs -path '*i386*' -name 'libvulkan*' -o -path '*x86_64*' -name 'libGL*' | head`
把结论（自带 / 不自带，以及因此是否需要额外 4.4 GB）写进 `docs/alioth.md`。这关闭 spec §9 风险登记里的一项。

- [ ] **Step 5: 提交**

```bash
git add scripts/assert-alioth-rootfs.sh docs/alioth.md
git commit -m "feat(phase2): Valve rootfs 基线断言，并核实 x86 FEX Mesa 是否自带"
```

---

### Task 2: `alioth-overlay/` —— InputPlumber、电源键、udev

**Files:**
- Create: `alioth-overlay/README.md`
- Create: `alioth-overlay/etc/inputplumber/devices.d/02-xiaomi-alioth.yaml`
- Create: `alioth-overlay/etc/inputplumber/capability_maps.d/alioth_keys.yaml`
- Create: `alioth-overlay/etc/systemd/user/gamescope-session.target.d/99-alioth-powerbuttond.conf`
- Create: `alioth-overlay/usr/lib/udev/rules.d/70-alioth.rules`
- Create: `scripts/assert-alioth-overlay.py`

**Interfaces:**
- Consumes: 无
- Produces: `alioth-overlay/` 目录树，供 Task 3 的 `apply-overlays.sh` 分支装入

**为什么独立于 `sm8250-overlay/`：** 后者全是掌机的物理摇杆/按键配置（AYANEO / Retroid / MANGMI / AYN），与 alioth 的「触摸 + 蓝牙手柄」无交集；混在一起会让每次 merge 都要手工分辨归属（spec §4）。

- [ ] **Step 1: 写失败的断言脚本 `scripts/assert-alioth-overlay.py`**

照 `scripts/assert-alioth-dtb.py` 的样式：每条断言打印 `PASS`/`FAIL` 加证据，
结尾汇总，任一失败退出非零。本仓库没有 `tests/` 也没有 pytest —— 断言脚本
就是这个项目的测试载体。四条断言：

```python
def test_device_yaml_matches_dtb_model():
    # DTB 的 model 是 'Xiaomi Poco F3'（scripts/assert-alioth-dtb.py 已断言）
    cfg = yaml.safe_load(open('alioth-overlay/etc/inputplumber/devices.d/02-xiaomi-alioth.yaml'))
    assert 'Xiaomi Poco F3' in yaml.dump(cfg)

def test_no_physical_stick_sources():
    # alioth 没有物理摇杆：匹配源只能是蓝牙手柄/按键/触摸，不能是掌机的 iio 或 gpio 摇杆
    cfg = yaml.safe_load(open('alioth-overlay/etc/inputplumber/devices.d/02-xiaomi-alioth.yaml'))
    assert 'joystick' not in yaml.dump(cfg).lower()

def test_volume_keys_mapped_to_steam_and_qam():
    cfg = yaml.safe_load(open('alioth-overlay/etc/inputplumber/capability_maps.d/alioth_keys.yaml'))
    dumped = yaml.dump(cfg)
    assert 'Guide' in dumped        # 音量上 → Steam 键
    assert 'QuickAccess' in dumped  # 音量下 → 快捷菜单

def test_all_overlay_yaml_parses():
    for p in glob.glob('alioth-overlay/**/*.yaml', recursive=True):
        yaml.safe_load(open(p))
```

- [ ] **Step 2: 运行，确认失败**

Run: `python3 scripts/assert-alioth-overlay.py`
Expected: FAIL，`FileNotFoundError: alioth-overlay/...`

- [ ] **Step 3: 写 overlay 文件**

照 `sm8250-overlay/etc/inputplumber/devices.d/02-retroid-pocket-865.yaml` 的结构，匹配条件改为 DT model `Xiaomi Poco F3`，source 只留按键（`gpio-keys`、`pm8941_pwrkey`、`pm8941_resin`）与蓝牙手柄，target 为 `deck-uhid`。`alioth_keys.yaml` 把音量上映射到 Steam 键（Guide）、音量下映射到快捷菜单（QuickAccess）。

`99-alioth-powerbuttond.conf` 照 `sm8250-overlay/etc/systemd/user/gamescope-session.target.d/99-sm8250-powerbuttond.conf` 原样复制 —— 上游注释说明 Frame 自带的 unit 依赖 SteamVR，必须替换。

- [ ] **Step 4: 运行测试**

Run: `python3 scripts/assert-alioth-overlay.py`
Expected: 全部断言通过（4 条）

- [ ] **Step 5: 提交**

```bash
git add alioth-overlay scripts/assert-alioth-overlay.py
git commit -m "feat(phase2): alioth-overlay —— InputPlumber、电源键、udev"
```

---

### Task 3: `apply-overlays.sh` 的 alioth 设备选择器

**Files:**
- Modify: `scripts/apply-overlays.sh:875-882`（SM8250 文件块）
- Create: `scripts/assert-alioth-overlay-applied.sh`

**Interfaces:**
- Consumes: Task 2 的 `alioth-overlay/`
- Produces: 环境变量契约 `DEVICE=alioth`；设置后 `apply-overlays.sh` 装 `alioth-overlay/`、并**移除** `sm8250-overlay/` 的文件

**为什么需要选择器而不是 spec 说的「SOC=sm8250 分支内加」：** 现有代码在 `SOC == sm8250` 时无条件装入全部 44 个掌机文件（`S8250_OVL` 块）。alioth 也是 sm8250，直接加分支会把 AYANEO/Retroid 的摇杆配置一起装上，InputPlumber 会按错误的设备定义去匹配。既有代码已有「不是这个镜像就删掉」的模式，照它写。

- [ ] **Step 1: 写失败的断言脚本 `scripts/assert-alioth-overlay-applied.sh`**

对一个最小的假 rootfs 目录树跑 `SOC=sm8250 DEVICE=alioth`，断言：

```
alioth 文件已装      $R/etc/inputplumber/devices.d/02-xiaomi-alioth.yaml 存在
掌机文件未装        $R/etc/inputplumber/devices.d/02-retroid-pocket-865.yaml 不存在
/etc overlay upper   $R/var/lib/overlays/etc/upper/inputplumber/devices.d/02-xiaomi-alioth.yaml 存在
不设 DEVICE 时反过来  SOC=sm8250 单独跑：掌机文件在，alioth 文件不在
```

第三条是 Review Focus 那一项：SteamOS 的 `/etc` 是 overlayfs 且挂载很晚，只写下层开机看不到。

- [ ] **Step 2: 运行，确认失败**

Run: `./scripts/assert-alioth-overlay-applied.sh`
Expected: FAIL，alioth 文件不存在

- [ ] **Step 3: 改 `apply-overlays.sh`**

在 `S8250_OVL` 块旁加 `ALIOTH_OVL="${ROOT}/alioth-overlay"`，条件从 `[[ "${SOC:-sm8650}" == sm8250 ]]` 细分为 alioth / 非 alioth 两支，两支互相移除对方的文件。alioth 支同时把 `etc/` 下的文件复制一份到 `$R/var/lib/overlays/etc/upper/`，照既有代码对 `konkrd` 的做法。

- [ ] **Step 4: 运行测试**

Run: `./scripts/assert-alioth-overlay-applied.sh`
Expected: 全部断言通过

- [ ] **Step 5: 提交**

```bash
git add scripts/apply-overlays.sh scripts/assert-alioth-overlay-applied.sh
git commit -m "feat(phase2): apply-overlays 的 DEVICE=alioth 选择器"
```

---

### Task 4: 模块加载策略 —— WiFi / 蓝牙 / 音频

**Files:**
- Create: `alioth-overlay/usr/lib/modules-load.d/alioth.conf`
- Create: `alioth-overlay/usr/share/alsa/ucm2/Xiaomi/Alioth/HiFi.conf`
- Create: `alioth-overlay/usr/share/alsa/ucm2/Xiaomi/Alioth/Alioth.conf`
- Create: `alioth-overlay/usr/share/alsa/ucm2/conf.d/sm8250/Alioth.conf`
- Create: `scripts/assert-alioth-modules.py`

**Interfaces:**
- Consumes: Task 2 的 overlay 目录
- Produces: 开机自动加载的模块清单

**阶段 1 的实测前提：** `pci-pwrctrl-pwrseq` 不被加载就没有 PCIe 总线，WiFi 和蓝牙一起消失，而症状是「总线上什么都没有」，看起来像硬件坏了。没有任何东西依赖它（它是隐藏 tristate，由 ath11k 的 `select` 决定值），所以必须显式列出。

- [ ] **Step 1: 写失败的断言脚本 `scripts/assert-alioth-modules.py`**

同样照 `assert-alioth-dtb.py` 的样式。三条断言：

```python
def test_pci_pwrctrl_pwrseq_is_listed():
    mods = open('alioth-overlay/usr/lib/modules-load.d/alioth.conf').read().split()
    assert 'pci-pwrctrl-pwrseq' in mods  # 没它就没有 PCIe 总线 → 没有 WiFi

def test_wifi_and_bt_modules_listed():
    mods = open('alioth-overlay/usr/lib/modules-load.d/alioth.conf').read().split()
    for m in ('ath11k_pci', 'hci_uart', 'btqca'):
        assert m in mods

def test_ucm_names_match_dtb_model():
    # UCM 按 DT model 查找；model 是 'Xiaomi Poco F3'
    assert 'Xiaomi Poco F3' in open('alioth-overlay/usr/share/alsa/ucm2/conf.d/sm8250/Alioth.conf').read()
```

- [ ] **Step 2: 运行，确认失败**

Run: `python3 scripts/assert-alioth-modules.py`
Expected: FAIL，文件不存在

- [ ] **Step 3: 写 `modules-load.d/alioth.conf` 与 UCM**

模块清单：`pci-pwrctrl-pwrseq`、`ath11k_pci`、`hci_uart`、`btqca`、`bluetooth`，加 cs35l41 与 sm8250 声卡所需模块。UCM 移植自 `nasaarmas/pmaports-alioth` 的 `HiFi.conf` + `alioth.conf`，照 ARMDeck 的做法加音量上限保护（其值为 −12 dB）—— nasaarmas 报告扬声器质量 cranky。alioth 无 3.5 mm 口，只有扬声器 + 蓝牙音频。

- [ ] **Step 4: 运行测试**

Run: `python3 scripts/assert-alioth-modules.py`
Expected: 全部断言通过（3 条）

- [ ] **Step 5: 提交**

```bash
git add alioth-overlay scripts/assert-alioth-modules.py
git commit -m "feat(phase2): 模块加载清单与 alioth 音频 UCM"
```

---

### Task 5: `make-steamos-alioth.sh --install`

**Files:**
- Modify: `make-steamos-alioth.sh`（新增 `--install` 模式；`--kernel-only` 行为不变）
- Create: `scripts/assert-alioth-kit.sh`

**Interfaces:**
- Consumes: Task 1 的 rootfs、Task 3 的 `DEVICE=alioth`
- Produces: `${STEAMOS_KIT}/userdata.img`（sparse ext4，< 768 MiB）、`${STEAMOS_KIT}/boot.img`

照 `make-steamos-sm8350.sh`（262 行，REDMAGIC 6 的手机 kit 构建器）。关键差异：alioth 的 root 靠 `PARTLABEL=userdata` 找到，与阶段 1 的 cmdline 一致，kit 里不需要按机器打补丁。

- [ ] **Step 1: 写失败的断言脚本 `scripts/assert-alioth-kit.sh`**

```
用法        不带参数仍打印用法并退出非零（现有行为不得回归）
--kernel-only 仍产出 boot-debug.img，sha 与改动前一致
镜像大小    userdata.img < 768 MiB（fastboot 单次上限）
文件系统    file userdata.img 报 ext4 或 Android sparse image
root 标签   镜像内 /etc/fstab 不含硬编码的 /dev/sd*，依赖 PARTLABEL
```

- [ ] **Step 2: 运行，确认失败**

Run: `./scripts/assert-alioth-kit.sh`
Expected: FAIL，`--install` 未实现

- [ ] **Step 3: 实现 `--install`**

流程照 `make-steamos-sm8350.sh`：把共享 rootfs 复制到 `${STEAMOS_ROOTFS}`（源永不修改）→ `SOC=sm8250 DEVICE=alioth scripts/apply-overlays.sh` → 装内核模块与固件 → 造 sparse ext4 → 输出 kit。固件必须包含阶段 1 实测缺的那几个：`qcom/a650_sqe.fw`、`a650_gmu.bin`、`qcom/sm8250/a650_zap.mbn`、`ath11k/QCA6390/hw2.0/{amss.bin,m3.bin,board-2.bin}`、`qca/{htbtfw20.tlv,htnv20.bin}`。

- [ ] **Step 4: 运行测试**

Run: `./scripts/assert-alioth-kit.sh`
Expected: 全部断言通过（5 条）

- [ ] **Step 5: 跑 DTB 断言（每轮必跑）**

Run: `python3 scripts/assert-alioth-dtb.py work/kernel-sm8250/output/*/dtbs/sm8250-xiaomi-alioth.dtb`
Expected: `全部断言通过`

- [ ] **Step 6: 提交**

```bash
git add make-steamos-alioth.sh scripts/assert-alioth-kit.sh
git commit -m "feat(phase2): make-steamos-alioth.sh --install"
```

---

### Task 6: `flash-alioth.sh --install`

**Files:**
- Modify: `flash-alioth.sh`（新增 `--install`；`--test` 代码路径不得出现写 userdata 的代码）
- Create: `scripts/assert-alioth-flash.sh`

**Interfaces:**
- Consumes: Task 5 的 `userdata.img` / `boot.img`
- Produces: 无（终端动作）

- [ ] **Step 1: 写失败的断言脚本 `scripts/assert-alioth-flash.sh`**

用一个假的 `fastboot` 可执行文件放进 `PATH`，记录收到的参数，不碰真设备。断言：

```
禁止分区      --install 的全部 fastboot 调用里不出现 super / abl_a / abl_b
活动槽保护    getvar current-slot 返回 a 时，不出现 flash boot_a
确认字        未输入 ERASE 时退出非零，且一次 fastboot 都没调用
getvar 异常   current-slot 返回空串或 "unknown" 时拒绝执行并退出非零
--test 隔离   grep 整个 --test 代码路径，不含 userdata
successful    --install 末尾设置 successful 标记
```

第四条是 Review Focus 那一项：把异常输出当默认值继续是不可逆的写错分区。

- [ ] **Step 2: 运行，确认失败**

Run: `./scripts/assert-alioth-flash.sh`
Expected: FAIL，`--install` 未实现

- [ ] **Step 3: 实现 `--install`**

两槽都刷 boot（spec §6.5），`erase dtbo_<slot>` 两槽都做，刷 `userdata.img`，最后标记 successful。`--test` 与 `--install` 的代码路径物理隔离，使迭代内核期间不可能手滑擦掉系统。

- [ ] **Step 4: 运行测试**

Run: `./scripts/assert-alioth-flash.sh`
Expected: 全部断言通过（6 条）

- [ ] **Step 5: 提交**

```bash
git add flash-alioth.sh scripts/assert-alioth-flash.sh
git commit -m "feat(phase2): flash-alioth.sh --install，含分区与活动槽保护"
```

---

### Task 7: 首次开机 —— resize、Steam 种子、successful 标记

**Files:**
- Create: `alioth-overlay/usr/lib/systemd/system/alioth-firstboot.service`
- Create: `alioth-overlay/usr/lib/steamos-arm/alioth-firstboot`
- Create: `scripts/assert-alioth-firstboot.sh`

**Interfaces:**
- Consumes: Task 5 刷进 `userdata` 的小镜像
- Produces: 扩展到 106 GiB 的根文件系统；A/B successful 标记

- [ ] **Step 1: 写失败的断言脚本 `scripts/assert-alioth-firstboot.sh`**

在一个 loop 挂载的小 ext4 上跑脚本，断言：

```
扩展        resize2fs 之后文件系统大小等于分区大小
幂等        连跑两次，第二次不做任何事且退出 0
中断可恢复  在 resize 前杀掉脚本，哨兵文件仍在 → 下次开机重试并完成
标记        调用 qbootctl 标记 successful（用假 qbootctl 记录调用）
```

第三条是 Review Focus 那一项：掉电落在 `resize2fs` 中间时，不能把半扩展的文件系统当成正常。

- [ ] **Step 2: 运行，确认失败**

Run: `./scripts/assert-alioth-firstboot.sh`
Expected: FAIL，脚本不存在

- [ ] **Step 3: 写 `alioth-firstboot` 与它的 unit**

哨兵文件在扩展**之前**创建、在成功**之后**才删除，这样中断必然落在「哨兵还在」的状态，下次开机重试。标记 successful 放在 resize 成功之后 —— 先确认系统真的起来了再停止自动回退。

- [ ] **Step 4: 运行测试**

Run: `./scripts/assert-alioth-firstboot.sh`
Expected: 全部断言通过

- [ ] **Step 5: 确认 Steam 种子已在镜像里**

Run: `ls ${STEAMOS_ROOTFS}/home/*/.steam 2>/dev/null || ls ${STEAMOS_ROOTFS}/etc/skel/.steam`
Expected: 非空。不这样做首次开机会「在黑屏上下载 2.5 GB」（spec §6.4），而本项目纯触摸、无桌面。

- [ ] **Step 6: 提交**

```bash
git add alioth-overlay scripts/assert-alioth-firstboot.sh
git commit -m "feat(phase2): 首次开机 resize、Steam 种子与 successful 标记"
```

---

### Task 8: 真机验收

**需要真机。** 本任务是阶段 2 的验收门。

**Files:**
- Modify: `docs/alioth.md`（追加阶段 2 验收结论）

**Interfaces:**
- Consumes: Task 6 刷好的系统
- Produces: 阶段 2 验收结论

- [ ] **Step 1: 刷机**

Run: `./flash-alioth.sh --install`
Expected: 两槽 boot + userdata 写入成功，successful 标记已设

- [ ] **Step 2: 逐项核对 spec §8 的验收标准**

每项记录 PASS/FAIL 与证据行：

```
□ 开机直接进 Game Mode，横屏，2400x1080
□ 纯触摸能完成 Steam 登录（靠 Steam 自带屏幕键盘）
□ 蓝牙手柄配对后 Steam 识别为 Deck 手柄，按键图标正确
□ 一个 Windows 独立游戏经 Proton 11 ARM64 跑通
□ mangoapp 性能浮层能显示（验证 tracefs 链路）
□ 音量键呼出 Steam 快捷菜单；电源键能待机/唤醒
□ s2idle 待机一夜掉电在可接受范围
□ Game Mode 里能看到电量
□ 边充边玩，电池温度不超过 45°C
```

- [ ] **Step 3: 确认蓝牙 BD_ADDR 跨重启稳定**

Run（重启前后各一次）: `./scripts/alioth-shell.sh -c 'hciconfig hci0 | grep "BD Address"'`
Expected: 两次相同。阶段 1 只测到模块重载前后一致；若跨重启会变，手柄每次开机都要重新配对，必须在这里发现。

- [ ] **Step 4: 对 FAIL 项修正并回到对应任务**

每轮只改一处。需要重刷内核的改动攒成一批再刷（见记忆 `batch-flashes-verify-on-device-first`）：能在 `/dbg` 或运行中的系统里验证的，先在那里验证。

- [ ] **Step 5: 固化**

```bash
git add docs/alioth.md
git commit -m "feat(alioth): 阶段 2 通过 —— Game Mode 可用"
```

---

## 阶段 2 完成后

剩余的已知上限与待办，不在本计划内：FEX 的 x86 rootfs（视 Task 1 Step 4 的结论决定是否需要）、RTC 由 NTP 纠正、温控服务（等实测到过热再决定）、相机 / NFC（范围外）。
