# SteamOS ARM 移植到 Xiaomi Redmi K40 / POCO F3 (alioth) — 设计

- 日期：2026-10-22
- 设备：Xiaomi Redmi K40 / POCO F3，代号 `alioth`，骁龙 870（`sm8250-ac`，平台 `kona`）+ Adreno 650
- 配置：8 GB RAM / 128 GB UFS 3.1，2400x1080 120Hz 命令模式 AMOLED（Samsung AMS667XX01），触摸 FocalTech FT8756，WiFi/BT 为 QCA6390

## 1. 目标与范围

把 alioth 变成一台只跑 Steam Game Mode 的掌机，用来玩**独立游戏**。

这不是"把 SteamOS 镜像刷进手机"——SteamOS 3（Holo）是 x86_64 的 Arch 衍生系统，没有公开的 ARM64 镜像。本项目使用的是 **Valve 为 Steam Frame 发布的官方 SteamOS ARM 镜像**（glibc，自带 Valve 的 Mesa/Turnip/zink、Proton 11 ARM64 和 FEX），把它的内核与设备支持换成 alioth 的。

**项目定位**：自用，但要可复现、可跟随上游更新。不做发布镜像（Valve rootfs 与小米固件均不可分发）。

### 1.1 已确认的产品决策

| 决策 | 内容 |
|---|---|
| Android | 不保留双启动，整机刷掉。永久失去通话/短信/移动数据 |
| 桌面 | 只用 Game Mode。KDE Plasma **保留**（它本就在 Valve 镜像里）作为黑屏时的图形兜底，但不作为默认会话 |
| 输入 | 蓝牙手柄（Xbox / DualSense / 8BitDo）+ 纯触摸。不用 USB-C 手柄（单口与充电冲突），不做外接显示 |
| 调试通道 | USB gadget 网卡 + SSH（主）；屏幕 fbcon TTY。**不做 UART 焊线**，不做额外的兜底图形会话 |
| 救砖 | 有公开的 9008 救砖包，不需要授权 Mi 账号。作为第三层退路 |
| x86 rootfs | 阶段 2 先不带，实测 Proton 路径后再决定是否加（见 §7.3） |

## 2. 硬件事实（`fastboot getvar all`）

```
unlocked:yes          secure:yes            slot-count:2        current-slot:b
max-download-size:768 MiB                   variant:SM8 UFS     product:alioth
slot-retry-count:a/b:7                      slot-unbootable:a/b:no

boot_a / boot_b            各 192 MiB       vendor_boot_a / _b    各 96 MiB
userdata                   106.3 GiB        super                 8.5 GiB
modem_a / _b 各 448 MiB    dsp_a / _b 各 64 MiB
总计                       118.9 GiB（114 个分区）
```

关键推论：
- `boot_a`/`boot_b` 各 192 MiB，而带内嵌 initramfs 的内核约 30–50 MiB → **两个槽都塞得下，A/B 内核回滚是免费的**
- `max-download-size` 768 MiB → 大镜像需 sparse 或"小镜像 + 首开扩展"
- `unlocked:yes` → bootloader 接受未签名 boot image（pmOS 已在 alioth 上验证）

## 3. 架构

```
alioth 硬件  (SD870 / Adreno 650 / 2400x1080 120Hz 命令模式)
  └─ Linux 7.2.8  (ROCKNIX SM8250 基线 + 上游 16 个 sm8250 补丁 + alioth DTS/面板/触摸)
      └─ Valve Steam Frame SteamOS ARM rootfs  (glibc，无容器)
          ├─ gamescope  (Game Mode，横屏 2400x1080)
          ├─ InputPlumber → deck-uhid → hid-steam  (虚拟 Deck 手柄)
          └─ Steam ARM64 客户端
              └─ Proton 11 ARM64 + FEX 2604        (x86/x86_64 → ARM64)
                  └─ DXVK / VKD3D-Proton
                      └─ Valve 的 Mesa Turnip (Vulkan 1.3, A6xx 一致性认证) → Adreno 650
```

**没有 pmOS 层，没有容器。** pmOS 用 musl 而 Steam 需要 glibc，才导致 ARMDeck 必须套 distrobox；Valve 的镜像本身是 glibc，容器自然消失。真正有性能开销的只有 FEX（主要，CPU 2–5x）和 DXVK（较小），两者都无法去掉。

GPU 驱动一行不改：A650 直接用 Valve 的 Frame Mesa。上游只在 8 Gen 2 / Adreno 740 上替换 Mesa。

### 3.1 两个上游与各自的贡献

- **`hashtagbasit/SteamOS-ARM-Port`** — 主上游，本项目是它的 fork。提供 Valve rootfs 组装流程、`kernel-sm8250` 配方（ROCKNIX 7.2.8 / ref 20261001）、16 个 sm8250 补丁、构建流水线、debug initramfs、**以及 REDMAGIC 6 这个"手机"移植模板**
- **`nasaarmas/pmaports-alioth`** — alioth 设备代码来源：`sm8250-xiaomi-alioth.dts`、`panel-samsung-ams667xx01.c`（120/90/60Hz）、`ft8756.c`、`alsa-ucm-conf`、以及已验证可用的 fastboot boot image 参数

### 3.2 为什么 ROCKNIX ABL 不需要

`external-and-mods/ufs-install/ufs-bootimg.py` 的 docstring 证明：ABL 启动的那个 `KERNEL` 就是 **Android boot image, header v0**。`scripts/stage-rocknix-abl.sh` 显示 ABL 是按 SoC 构建的（一个 `abl_signed-SM8250.elf` 服务全部 10 台 865 掌机，platform=`kona`）。

ABL 只提供三个功能：菜单选设备型号（决定加载哪个 DTB）、选启动源（SD/内部）、保留 Android 入口。**alioth 一个都不需要**：单一设备、无 SD 卡槽、不要 Android。

→ 使用小米原厂 ABL + `fastboot flash boot`，**不触碰 ABL 分区**。这不只是避险，更重要的是它允许无限次重刷迭代——在没有 SD 卡退路的情况下这是刚需。

### 3.3 REDMAGIC 6 是本项目的直接模板

上游 `docs/redmagic6.md`（Nubia NX669J / SM8350）与 alioth 的约束几乎一一对应：手机而非掌机、无 SD 卡槽、厂商原厂已解锁 bootloader、无 ABL 无设备菜单、A/B 槽测试、无内置手柄、固件不可分发所以自建 kit、命令模式 AMOLED 多刷新率、竖屏面板靠 DT `rotation` 让 gamescope 横屏、`vendor_boot-debug.img` 提供 USB 串口 + USB 网卡调试 shell。

**本项目 = `kernel-sm8250`（SoC 支持）× REDMAGIC 6（手机安装模型）。**

与 REDMAGIC 6 的差异：
- 它用 mainline 7.1.2；本项目用 ROCKNIX 7.2.8（为了拿到 sm8250 的 16 个补丁）
- 它用 boot header v3（kernel 在 `boot`、DTB+initramfs 在 `vendor_boot`）且其 bootloader 不接受 `fastboot boot`；alioth 的 pmOS 用 legacy v0 + append_dtb 且已验证可开机 → 先用 v0
- 它的 `current-slot` 是 a 所以拿 b 做实验；**alioth 的 `current-slot` 是 b，所以拿 slot a 做实验**

## 4. 仓库结构与上游边界

fork `hashtagbasit/SteamOS-ARM-Port`，alioth 作为新设备加入。核心原则：**alioth 特有的内容全部放新文件**，让 `git merge upstream/main` 的冲突面最小。

```
新增（本项目拥有）
  external-and-mods/kernel-sm8250/dts/sm8250-xiaomi-alioth.dts
  external-and-mods/kernel-sm8250/patches/0017-drm-panel-add-samsung-ams667xx01.patch
  external-and-mods/kernel-sm8250/patches/0018-input-add-focaltech-ft8756.patch
  alioth-overlay/                     InputPlumber / 音频 UCM / udev / 电源键
  make-steamos-alioth.sh              手机 kit 构建器（照 make-steamos-sm8350.sh）
  flash-alioth.sh                     fastboot 刷机脚本（--test / --install）
  docs/alioth.md                      安装与调试说明

必须改的上游文件（三处，均为追加）
  external-and-mods/kernel-sm8250/soc.env          DTBS 追加 sm8250-xiaomi-alioth
  external-and-mods/kernel-sm8250/steamos.config   追加 2 个 CONFIG
  scripts/apply-overlays.sh                        SOC=sm8250 分支内加 alioth-overlay 应用

直接复用（零改动）
  external-and-mods/kernel-common/build.sh          内核构建流水线
  external-and-mods/kernel-common/initramfs/        含 debug shell（USB 串口 + USB 网卡）
  external-and-mods/kernel-common/mkbootimg-v0.py
  external-and-mods/kernel-common/steamos.config    共享游戏内核选项（见 §5.3）
  external-and-mods/kernel-sm8250/patches/0001–0016 全部 16 个 sm8250 补丁
  scripts/build-gamescope-in-rootfs.sh
  Valve Frame rootfs + Valve 的 Mesa/Turnip/Proton/FEX   一行不动
```

`alioth-overlay/` 独立于 `sm8250-overlay/`：后者全是掌机的物理摇杆/按键 InputPlumber 配置，与 alioth 的"触摸 + 蓝牙手柄"无交集；混在一起会让每次 merge 都要手工分辨归属。

## 5. 内核

### 5.1 三块移植工作，每块对照一个同时代样本

把"未知的 API 漂移"降级为"对照已知正确的同时代样本"：

| 要移植（来自 pmOS 6.19.6） | 对照样本（ROCKNIX 7.2.8，同 SoC） |
|---|---|
| `panel-samsung-ams667xx01.c` | `patches/0009-drm-panel-add-the-ayaneo-ar18-panel.patch` |
| `ft8756.c`（FocalTech 触摸，I2C） | `patches/0010-input-add-the-sitronix-st7123-touchscreen.patch` |
| `sm8250-xiaomi-alioth.dts` | `dts/sm8250-ayaneo-pocketmicro2.dts`（24 KB，完整 sm8250 手持 DTS） |

方法：先读对照样本，确认 7.2.8 里 `drm_panel_funcs` 签名、`mipi_dsi_multi_*` 辅助函数、面板分配方式长什么样，再把 nasaarmas 的驱动改成同样的形状。**不要靠逐个编译错误猜 API。**

面板驱动现状（已核实）：`alioth_modes[]` 含 120Hz（`DRM_MODE_TYPE_PREFERRED`）、90Hz、60Hz 三个模式，驱动内有完整 vrefresh 切换逻辑。120Hz 无需自行实现。

### 5.2 DTS 的三处 alioth 特有改动

1. **`rotation = <270>`** — 竖屏面板 → gamescope 横屏跑 Game Mode。缺这条 Game Mode 会竖着跑，而 Steam 的 Deck UI 是为横屏设计的
2. 删掉 pmOS 专有节点 — modem / sensor / hexagonrpcd 相关的不要
3. 与 ROCKNIX 基线对齐 — patch 0016 改过 `sm8250` 的 cpu-ddr votes，确认与 alioth.dts 不冲突

### 5.3 内核配置：只需两行

上游共享的 `kernel-common/steamos.config` 已覆盖全部游戏相关选项：`NTSYNC`、`HID_STEAM`/`STEAM_FF`（InputPlumber 虚拟 Deck 手柄）、`BT_RFCOMM`/`BT_BNEP`（蓝牙手柄）、`UCLAMP_TASK`/`_GROUP`、`CPU_FREQ_DEFAULT_GOV_SCHEDUTIL`、`CPU_IDLE_GOV_TEO`、`FTRACE`/`ENABLE_DEFAULT_TRACERS`（mangoapp 与 steamos-manager 必需）、`ANDROID_BINDER_IPC`、`UNICODE`（Proton 的 ext4 casefold）、`EROFS`/`SQUASHFS`（Steam runtime）。`PREEMPT`、MGLRU、4K 页**推定**由 ROCKNIX 的 `devices/SM8250/linux/linux.aarch64.conf` 基线提供
（ROCKNIX 本身是游戏发行版，且其 sm8250 目标已跑 box64/FEX）——但这是推断而非已核实，
其中 **4K 页是 FEX 的硬性前提**，必须在阶段 1 以 `getconf PAGESIZE` 确认。

`kernel-sm8250/steamos.config` 已含 `CONFIG_QCOM_Q6V5_PAS=m`（ADSP 固件在根文件系统上，驱动编进内核会在根挂载前探测失败）。

本项目只需追加：
```
CONFIG_DRM_PANEL_SAMSUNG_AMS667XX01=m
CONFIG_TOUCHSCREEN_FT8756=m
```

### 5.4 boot image 与工具链

```
格式     mkbootimg-v0.py（legacy v0）—— pmOS 在 alioth 上已验证
         EMBED_INITRAMFS=1，initramfs 编进 Image，ramdisk 位置放 dummy
         DTB 附加在内核镜像后（append_dtb）
cmdline  steamos.root=PARTLABEL=userdata
         （用 steamos.root= 而非 root=，因为这是上游共享 initramfs 读取的键；
           上游在 REDMAGIC 6 上采用此约定是为了避开 ABL 追加的 root=，
           小米 ABL 是否同样追加 root= 未知，但复用共享 initramfs 时此约定无论如何都正确）
         + sm8250 的 CMDLINE_SOC（mem_sleep_default=s2idle、fw_devlink.sync_state=timeout 等）
工具链   容器化构建 build-gcc15.sh sm8250
         （GCC 15 + Binutils 2.45 的硬要求是 SM8750/Oryon 专有，sm8250 的 A77/A55 不受影响）
```

退路：若小米 ABL 拒绝 v0，改用 `mkbootimg-v3.py` + `vendor_boot`（alioth 有 `vendor_boot_a/b` 各 96 MiB），照 REDMAGIC 6 的 v3 方案。

## 6. 启动链、分区、安装与回滚

### 6.1 不重新分区

```
保留不动   xbl / abl / tz / hyp / modem / dsp / bluetooth / devcfg / keymaster
          cmnlib / persist / ...  (~4 GiB)   ← SoC 启动与固件加载所需，删了连 fastboot 都进不去
保留不动   super            8.5 GiB          Android system/vendor/product，闲置但保留回 Android 的可能
刷写      boot_a / boot_b   各 192 MiB       内核（A/B 回滚）
擦除      dtbo_a / dtbo_b                    必需：防 ABL 用 libufdt 把厂商 dtbo 覆盖到 mainline DTB
刷写      vbmeta_a / vbmeta_b                禁用验证（若需要，scripts/mk-vbmeta-disabled.py）
刷写      userdata        106.3 GiB          单个 ext4 = /，首次开机 resize 到整个分区
```

单一文件系统（而非 ROCKNIX ABL 的 `ROCKNIX`+`STORAGE`+`HOME` 三分区），照 REDMAGIC 6 的手机模型。这同时绕开了 768 MiB 的 fastboot 单次传输上限——刷一个小 ext4 再首开扩展，不需要 sparse 分块。

取舍：`super` 那 8.5 GiB 闲置。换来零 GPT 操作（写错分区表是最容易彻底变砖的操作之一）以及保留回 Android 的可能。106.3 GiB 装独立游戏完全够。

### 6.2 阶段 1 测试启动：用 slot a

```bash
fastboot flash vbmeta_a vbmeta-disabled.img   # 若需要
fastboot erase dtbo_a
fastboot flash boot_a boot-debug.img          # 带 debug initramfs
fastboot --set-active=a
fastboot reboot
# 失败 → fastboot --set-active=b  回到 Android
```

debug initramfs 在 `userdata` 上找不到 SteamOS 时会**自动开调试 shell**（上游已实现），两条通道：

```
USB 串口   /dev/ttyACM0      screen /dev/ttyACM0 115200
USB 网卡   172.16.42.1       PC 侧设 172.16.42.2/24，然后 telnet
```

**阶段 1 完全隔离了内核这一个变量**：不需要 Valve rootfs、不需要 40 GB 构建、不动 `userdata`、不碰 Android slot b。内核前向移植成不成，一次约 10 分钟的刷机即可判定。

### 6.3 三层回滚

```
第 1 层   A/B 槽手工切换 —— 新内核刷非活动槽，--set-active，失败切回。日常迭代用，代价 0
第 2 层   bootloader 自动回退 —— slot-retry-count:7 + slot-unbootable
          系统若从未标记槽为 successful，连续失败 7 次后自动回退到另一槽
          阶段 1 故意不做 successful 标记，让这层保持激活
          阶段 2 正式安装后才加标记服务（qbootctl；ARMDeck 用 op8-qbootctl 做同样的事）
第 3 层   9008 救砖包 —— 终极退路
```

仍然盲的场景：内核早期就挂、USB 未起来。缓解：已知 pmOS 的 6.19.6 在 alioth 上能开机，可用二分法逐步把 alioth DTS 片段往 7.2.8 上搬以缩小范围。

### 6.4 首次开机预置 Steam

构建时设 `STEAM_ARM_SEED`，把完整 Steam 客户端预先塞进 rootfs。上游文档明确：不这样做首次开机会"在黑屏上下载 2.5 GB"。对纯触摸、无桌面、无串口的本项目尤为重要。

### 6.5 `flash-alioth.sh` 两个模式

```
--test      只刷非活动槽的 boot/dtbo/vbmeta，绝不触碰 userdata。可无限次重复
--install   boot 刷两槽 + userdata.img + 启用 successful 标记。要求输入 ERASE 二次确认
```

两个模式的代码路径物理隔离：`--test` 不包含任何写 `userdata` 的代码，使得迭代内核期间不可能手滑擦掉系统。

## 7. 用户空间

### 7.1 输入：InputPlumber 虚拟 Deck 手柄

```
蓝牙手柄 (Xbox/DualSense/8BitDo) ─┐
                                  ├─→ InputPlumber → deck-uhid → hid-steam → Steam 看到"真 Deck 手柄"
音量键 / 电源键                  ─┘
触摸 ──────────────────────────────→ gamescope 原生处理（Deck UI 本身支持触摸）
```

走虚拟 Deck 手柄而非直接暴露蓝牙手柄，白拿三样：Steam 按键图标正确、Deck 专属控制布局可用、社区 Deck 配置直接可套。

`alioth-overlay/` 待写文件：
```
etc/inputplumber/devices.d/02-xiaomi-alioth.yaml          匹配 DT model "Xiaomi Poco F3"
etc/inputplumber/capability_maps.d/alioth_keys.yaml       音量键 → Steam 键 / 快捷菜单 (QAM)
etc/systemd/user/gamescope-session.target.d/99-alioth-powerbuttond.conf
usr/lib/udev/rules.d/70-alioth.rules
usr/share/alsa/ucm2/Xiaomi/Alioth/{HiFi.conf,Alioth.conf}
```

电源键复用上游 `steamos-powerbuttond`（上游注释说明 Frame 自带的 unit 依赖 SteamVR，必须替换）。

### 7.2 显示

原生 2400x1080，Game Mode 全屏，120Hz 首选（90/60 可选），DT `rotation = <270>` 使之横屏。patch 0012（命令模式面板真实 vblank 时间戳）使 gamescope 帧率限制准确。

预期行为：命令模式面板**切换刷新率 = 完整 modeset**，在 Steam 里改帧率会黑屏闪一下。REDMAGIC 6 文档记录了同样现象，属正常。

### 7.3 游戏路径

阶段 2 只走 Proton：`游戏(x86_64) → FEX → Wine/Proton 11 ARM64 → DXVK → Turnip → A650`。

**先不带 FEX 的 x86 Mesa / x86 rootfs**（约 4.4 GB）。原生 Linux x86_64 版独立游戏可少掉 Wine 和 DXVK 两层，理论上更快，但引入一条额外的调试路径。阶段 2 用 Proton 路径测两三个游戏后，若性能不足再加 x86 rootfs 做对比。

待确认：Valve 的 Frame 镜像可能本就自带 x86/i386 的 FEX Mesa（上游 mesa README 的措辞暗示如此，因 A650 走的是"保留 Valve 的 Mesa"路径），则额外开销可能为 0。阶段 2 解包 rootfs 时核实。

### 7.4 音频

移植 nasaarmas 的 `alsa-ucm-conf/HiFi.conf` + `alioth.conf`。alioth 无 3.5mm 口 → 仅扬声器 + 蓝牙音频。nasaarmas 报告扬声器质量"cranky"，需在 UCM 内调整，并照 ARMDeck 做法加音量上限保护（其值为 -12 dB）。

白拿的上游 865 修复：`CONFIG_QCOM_Q6V5_PAS=m`（见 §5.3）、以及上游针对 865 UCM 的爆音/音量修复。

### 7.5 电源与热管理

**充电：不加载充电驱动。** 照 ARMDeck 的做法交给 bootloader 的硬件保护。原因：社区 PM8150B 驱动会把充电上限设到约 4.87 V，而安全值为 4.435 V，有电池鼓包与起火风险。alioth 同为 PM8150B 平台，直接照搬此决定。

**待机**：`mem_sleep_default=s2idle`（sm8250 的 `CMDLINE_SOC` 已含）+ patch 0016（cpu-ddr votes active-only，使 DDR 在 s2idle 下自刷新）。上游 commit `fix(sleep): let 865 DDR self-refresh in s2idle with active-only CPU votes` 正为 865 所做。

**热管理：先不写服务。** alioth 无风扇，`konkrd` 的风扇曲线部分完全不适用。阶段 2 只依赖 `UCLAMP` + `schedutil` + 已有的 `THERMAL_GOV_STEP_WISE` 与硬件 cutoff（90°C 降频 / 95°C 加强 / 110°C 保护关机）。**等实测到过热再决定是否写 alioth 版主动降频服务**——独立游戏负载远轻于 3A，很可能不需要。没有实测数据就写温控曲线是在猜。

## 8. 阶段划分与验收标准

### 阶段 1：内核（不需要 rootfs）

```
□ fastboot 刷 slot a 后能启动到 debug shell
□ USB 串口 /dev/ttyACM0 与 USB 网卡 172.16.42.1 至少通一条
□ dmesg 确认：面板点亮；drm/msm + A650 GPU 初始化成功；UFS 认出；
            FT8756 触摸探测到；QCA6390 WiFi/BT 探测到
□ getconf PAGESIZE 为 4096（FEX 的硬性前提）
□ 内核配置确认 PREEMPT 与 MGLRU 已开
□ 失败能靠 fastboot --set-active=b 回到 Android
```

### 阶段 2：完整系统

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

## 9. 风险登记（含待验证项）

| 项 | 性质 | 缓解 / 验证时机 |
|---|---|---|
| 7.2.8 的 `drm_panel` / input API 具体形状 | 已知未知 | 对照 AR18 / ST7123 补丁（§5.1） |
| ROCKNIX sm8250 平台代码与 alioth DTS 冲突 | 已知未知 | 阶段 1 编译 + 开机 |
| 小米 ABL 接受 boot header v0 还是必须 v3 | 已知未知 | 阶段 1；先试 v0（pmOS 有先例），失败切 v3 |
| 是否需要禁用 vbmeta 验证 | 已知未知 | 阶段 1；`scripts/mk-vbmeta-disabled.py` 备用 |
| 是否必须 `fastboot erase dtbo` | 高概率需要 | 阶段 1 一并试（REDMAGIC 6 必须） |
| 不加载充电驱动后电量百分比从哪读 | 待验证 | 阶段 2；电量计通常与充电控制器是独立器件 |
| Valve 镜像是否自带 x86/i386 FEX Mesa | 待验证 | 阶段 2 解包 rootfs 时核实 |
| ROCKNIX 基线是否确实提供 4K 页（FEX 硬性前提） | 待验证 | 阶段 1 `getconf PAGESIZE` 必须为 4096 |
| ROCKNIX 基线是否确实开启 PREEMPT / MGLRU | 待验证 | 阶段 1 查 `/boot/config-*` 或 `zcat /proc/config.gz` |
| 内核早期挂且 USB 未起来 → 无日志 | 残余风险 | 二分法对照已知可开机的 pmOS 6.19.6 |
| Adreno 650 不支持 DXVK 3 / Proton Experimental ARM64 | 已知上限 | 锁定 Proton 11 ARM64 + DXVK 2.x；D3D12 游戏不在目标内 |
| SD870 缺 FEAT_LSE2 导致 FEX 非对齐原子开销 | 已缓解 | 上游 patch 0004/0005 在内核态模拟非对齐原子操作 |
| 持续满载过热 | 残余风险 | 阶段 2 实测后再决定是否写温控服务（§7.5） |

## 10. 明确不做的（YAGNI）

```
Decky Loader              以后想要再加，不影响核心
lsfg-vk 帧生成            Adreno 650 不一定支持，独立游戏也不需要
Lepton / Android 应用层   不是目标
DP alt mode / 外接显示    已排除，且在 alioth 上是未验证项
删除 KDE Plasma           保留作兜底（§1.1）
alioth 主动温控服务       等实测数据
重新分区 / 合并 super     避免 GPT 操作（§6.1）
发布镜像 / CI             自用定位，且 Valve rootfs 与小米固件不可分发
保留 Android 双启动       已排除
```
