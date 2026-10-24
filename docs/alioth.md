# alioth（Xiaomi Redmi K40 / POCO F3）构建与刷机

设备：骁龙 870（`sm8250-ac`，平台 `kona`）+ Adreno 650，8 GB / 128 GB。

这份文档记**结论**。过程、失败的尝试和踩坑记录在 `docs/alioth-journal.md`。

## 前置依赖

宿主为 x86_64 Linux（交叉编译，aarch64 工具链在容器里）。

| 依赖 | 用途 | 备注 |
|---|---|---|
| `podman` 或 `docker` | `build-gcc15.sh` 在 Fedora 43 容器里构建内核 | 自动探测，podman 优先。docker 需守护进程已启动；用户不在 `docker` 组时包装脚本会自动走 `sudo docker` |
| `dtc`（含 `fdtget`） | DTB 断言 | Task 2 起需要 |
| `git` / `curl` / `python3` | — | — |
| 静态 **aarch64** busybox | 进 initramfs | 见下 |
| ROCKNIX 检出 @ `20261001` | 内核基线 | 见下 |
| 磁盘 ≥ 40 GiB | 构建产物 | — |

其余构建依赖（gcc、bc、bison、flex、cpio、openssl-devel…）由 `build-gcc15.sh` 在容器内 `dnf install`，宿主不需要。

### ROCKNIX 检出

`build.sh` **不会自动 clone**，且校验它停在固定 ref 上：

```bash
cd "$(dirname /home/shouchen/Projects/SteamOSforAlioth)"
git clone --filter=blob:none --no-checkout --depth 1 --branch 20261001 \
    https://github.com/ROCKNIX/distribution rocknix-20261001
cd rocknix-20261001
git sparse-checkout init --cone && git sparse-checkout set projects packages
git checkout 20261001
```

约 99 MB。commit 应为 `c445081a59518f37d9776e5412dd7b14910696f7`。

### 静态 aarch64 busybox

busybox.net 只提供 i686/x86_64 预编译，**没有 aarch64**。从 Alpine 的 aarch64 包取：

```bash
curl -fLO https://dl-cdn.alpinelinux.org/alpine/v3.22/main/aarch64/busybox-static-1.37.0-r20.apk
tar -xzf busybox-static-1.37.0-r20.apk -C <空目录>
cp <空目录>/bin/busybox.static work/busybox-aarch64-static
```

必须确认 `file` 输出同时含 `ARM aarch64` 与 `statically linked`。

## 构建内核

```bash
./build-alioth-kernel.sh
```

不要直接调 `external-and-mods/kernel-common/build-gcc15.sh` —— 包装脚本负责六条上游不保证的前提，其中第 4 条（busybox 架构）是静默失败（见脚本内注释）。

### 输出目录（实测）

```
work/kernel-sm8250/output/7.2.8-sm8250-steamos/     # KREL 命名的真实目录
work/kernel-sm8250/output/current -> 7.2.8-sm8250-steamos
├── boot/KERNEL              # Android boot image，16,005,120 字节
├── boot/KERNEL.md5
├── config-7.2.8-sm8250-steamos
├── System.map-7.2.8-sm8250-steamos
├── dtbs/                    # 只含 soc.env 的 DTBS 清单所列（基线 10 个）
├── modules/7.2.8-sm8250-steamos/
└── firmware/{qcom,ath11k,qca,regulatory.db}
```

**`current` 是符号链接，所以 `find` 必须带 `-L` 才能穿过它**；不带 `-L` 的
`find "$WORK" -path '*output/current/boot/KERNEL'` 永远匹配不到。按文件名找
（`find work -name 'xxx.dtb'`）不受影响，因为真实目录下有同名文件。

## 未知项结论

spec §9 风险登记里的待验证项，实测结果记在这里。

| 项 | 结论 | 依据 |
|---|---|---|
| ROCKNIX 基线是否提供 4K 页（FEX 硬性前提） | **PASS** | `grep '^CONFIG_ARM64_4K_PAGES=y'` 于 `rocknix-20261001/projects/ROCKNIX/devices/SM8250/linux/linux.aarch64.conf`；同时 `CONFIG_PAGE_SIZE_4KB=y` |
| ROCKNIX 基线是否开启 PREEMPT | **PASS** | 同一文件：`CONFIG_PREEMPT=y`、`CONFIG_PREEMPTION=y`、`CONFIG_PREEMPT_RCU=y` |
| ROCKNIX 基线是否开启 MGLRU | **PASS** | 同一文件：`CONFIG_LRU_GEN=y`、`CONFIG_LRU_GEN_ENABLED=y` |
| 7.2.8 的 `drm_panel` / input API 形状 | 待定 | Task 3 / Task 4 |
| ROCKNIX sm8250 平台代码与 alioth DTS 冲突 | 待定 | Task 2 / Task 6 |
| 小米 ABL 接受 boot header v0 还是必须 v3 | 上游产出为 **v0**；设备是否接受待定 | 实测基线 `KERNEL`：magic `ANDROID!`、`header_version=0`、`page_size=2048`。设备侧验证在 Task 5 |
| 是否需要禁用 vbmeta 验证 | 待定 | Task 5 |
| 是否必须 `fastboot erase dtbo` | 待定 | Task 5 |

因为前三项都 PASS，`external-and-mods/kernel-sm8250/steamos.config` 不需要追加调度/内存相关配置，
spec Global Constraints 的「新增内核配置仅两行」成立。

### 顺带观察到的基线事实

- `CONFIG_HZ_250=y` —— ROCKNIX 用 250 而非 1000。spec 未要求 1000，不改。
- `CONFIG_NTSYNC=y` —— ROCKNIX 编进内核；上游 `kernel-common/steamos.config` 设 `=m`，会降为模块。两者对 Wine 都可用，不处理。
- `CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE=y` —— 上游 `steamos.config` 覆盖为 `SCHEDUTIL`，与其注释一致。

## 基线构建实测（Task 1）

未修改的上游 `sm8250` 构建通过，退出码 0。

| 项 | 实测值 |
|---|---|
| 内核版本 | `7.2.8-sm8250-steamos` |
| `boot/KERNEL` 大小 | 16,005,120 字节（boot 分区 192 MiB，余量充足；spec 估的 30–50 MiB 偏高） |
| boot image header | `ANDROID!`，`header_version=0`，`page_size=2048` |
| `kernel_addr` / `tags_addr` | `0x10000000` / `0x10000000` |
| `ramdisk_size` | 5 字节 —— `EMBED_INITRAMFS=1` 把 initramfs 放进内核镜像，boot image 的 ramdisk 槽只是占位 |
| 基线 DTB 数 | 10（与 `soc.env` 的 `DTBS` 清单一致） |

基线 cmdline（288 字符）：

```
video=efifb:off usbcore.interrupt_interval_override=045e:028e:2 mem_sleep_default=s2idle
fw_devlink.sync_state=timeout quiet loglevel=0 systemd.show_status=0 rd.udev.log_level=0
logo.nologo vt.global_cursor_default=0 rw rootwait root=PARTUUID=00000000-02
rootfstype=ext4 errors=remount-ro
```

### 两条留给 Task 5 的风险

1. **页大小不一致。** 上游产出 `page_size=2048`，而 pmaports 的 `deviceinfo`
   对 alioth 写的是 `flash_pagesize="4096"`。bootloader 从 header 里读 page
   size，理论上 2048 可行，但这是 alioth 上唯一已知能开机的配置与我们的产物
   的一处明确分歧，首次刷机失败时优先怀疑它。
2. **基线 cmdline 会压掉调试输出。** `quiet loglevel=0
   systemd.show_status=0 vt.global_cursor_default=0` 三者叠加，屏幕会一片空白。
   不需要自己拼 cmdline —— `kernel-common/cmdline.sh` 已有开关：
   `CMDLINE_QUIET=0` 换成 `console=tty0 loglevel=4`，`KERNEL_CMDLINE_EXTRA`
   可追加任意项。`scripts/sd-debug-boot.sh` 就是这么用的。

## 固件路径（Task 2 发现）

pmaports 的 alioth DTS 把五处 `firmware-name` 指向 `qcom/sm8250/xiaomi/alioth/`
子目录，而本项目的固件 kit（`soc.env`）一处都不提供：

| DTS 原值 | kit 提供 | 处置 |
|---|---|---|
| `…/xiaomi/alioth/a650_zap.mbn` | `qcom/sm8250/a650_zap.mbn` | **改路径** —— zap shader 加载不到，Adreno 650 出不了 secure mode，GPU 整个不可用 |
| `…/xiaomi/alioth/adsp.mbn` | `qcom/sm8250/adsp.mbn` | 改路径（照上游 ayaneo DTS） |
| `…/xiaomi/alioth/cdsp.mbn` | `qcom/sm8250/cdsp.mbn` | 删 `&cdsp` 节点 —— 上游 sm8250 DTS 不带，非阶段 1 验收项 |
| `…/xiaomi/alioth/slpi.mbn` | 无 | 删 `&slpi` 节点 —— 传感器 DSP，固件 kit 里完全没有 |
| `…/xiaomi/alioth/venus.mbn` | `qcom/vpu-1.0/venus.mbn` | 删 `&venus` 节点 —— 硬件视频解码是阶段 2 |

`sm8250.dtsi` 自身**不提供任何 `firmware-name` 默认值**（7.2.8 全文件 0 处），
所以 zap-shader 的路径必须由设备 DTS 给出，不能靠删覆盖块回退到默认。

## DTB 选择（Task 2 实测）

`pack_kernel_img`（`build.sh:340`）把 `$DTBS` 列出的**全部** DTB 追加在
gzip 过的 `Image` 之后，由 bootloader 按 `qcom,msm-id` + `qcom,board-id` 选择。
注册 alioth 后启动镜像从 16,005,120 长到 16,138,240 字节，刚好是一个 DTB。

| DTB | msm-id | board-id |
|---|---|---|
| sm8250-xiaomi-alioth | 356 131073 | **44 0** |
| sm8250-ayaneo-pocketmicro2 | 356 131073 | 11 0 |
| sm8250-mangmi-air-y-pro / pocket-max | 356 131073 | 65544 0（两者相同） |
| sm8250-retroidpocket-\*（6 个） | 356 131073 | 65567 1（六者相同） |
| sm8250-ayn-thorlite | （无） | （无） |

`msm-id` 356 = `QCOM_ID_SM8250`，`131073` = `0x20001` = v2.1。

两个结论：

1. **alioth 的 board-id 唯一**，小米原厂 ABL 靠 msm-id + board-id 就能选对
   ——这是 spec「不需要替换 ABL」的硬证据。上游要自建 ABL，是因为它自己的
   六个 retroid 机型共用一个 board-id，只能靠 ABL v1.1.8+ 读 `model` 消歧。
2. 但阶段 1 仍用 `DTBS_OVERRIDE=sm8250-xiaomi-alioth` 构建单 DTB 镜像：
   若原厂 ABL 的匹配偏宽松、只认 msm-id（11 个全相同），就可能选中别的机型
   的 DTB 而黑屏。阶段 1 只有一个设备，这个风险零成本就能消除。

## 阶段 1 的「没有 rootfs」问题（Task 3 实测，Task 5 处置）

阶段 1 只启到 initramfs，不做 `switch_root`。而 `.config` 的实际情况是：

| 配置 | 值 | 对阶段 1 的后果 |
|---|---|---|
| `CONFIG_DRM_MSM` | `=y` | DPU / DSI / Adreno 内建，不需要 rootfs ✓ |
| `CONFIG_DRM_MSM_KMS_FBDEV`、`CONFIG_FRAMEBUFFER_CONSOLE` | `=y` | fbcon 走 drm/msm ✓ |
| 面板驱动（`DRM_PANEL_*`） | `=m` | **加载不了** → DSI 没有面板 → 屏幕不亮 |
| `CONFIG_ATH11K`、`CONFIG_BT` | `=m` | **加载不了** → WiFi / BT 验收项无法进行 |
| 固件（`FW_BUILTIN=0`） | 在 rootfs | **取不到** → GPU zap / WiFi 固件缺失 |

`external-and-mods/kernel-common/initramfs/init` 里**没有任何 `modprobe` 或
`insmod`** —— 它只做挂根与 `switch_root`。上游设备不受影响：它们从 SD 卡启动，
面板模块在 `switch_root` 之后才 probe。alioth 阶段 1 没有那一步。

讽刺的是 `initramfs/bootdebug` 第 29 行就往 `/dev/tty1` 写，它本身假设屏幕
是亮的。

**处置（Task 5）**：阶段 1 的调试镜像追加配置覆盖

```
CONFIG_DRM_PANEL_SAMSUNG_AMS667XX01=y
CONFIG_TOUCHSCREEN_FT8756=y
FW_BUILTIN=1          # soc.env；env 白名单里没有它，不能用环境变量覆盖
```

依赖项都已满足（`DRM_MIPI_DSI=y`、`BACKLIGHT_CLASS_DEVICE=y`、`OF=y`）。
Task 3 / Task 4 本身仍用 `=m` —— Global Constraints 如此规定，且那两个任务
的 `.ko` 断言依赖它。

WiFi / BT 仍是 `=m`，阶段 1 要验这两项得把 `ath11k` / `bt` 模块也编进去，或
接受它们留到阶段 2。

另：`CONFIG_FRAMEBUFFER_CONSOLE_ROTATION=y`，所以 cmdline 加 `fbcon=rotate:1`
能让阶段 1 的调试文字横向可读（面板物理竖装）。

## 面板驱动前向移植（Task 3）

`patches/0017-drm-panel-add-samsung-ams667xx01.patch`，基线 6.19.6 → 7.2.8。
对照样本是上游 `patches/0009`（AYANEO AR18，同内核版本同 SoC）。

好消息：pmaports 的驱动已经用 `mipi_dsi_multi_context` 系列（现代形式），
input/DSI 辅助函数大部分没变。三处必须改：

| 项 | 6.19.6 | 7.2.8 |
|---|---|---|
| 面板分配与初始化 | `devm_kzalloc` + `drm_panel_init` | **`drm_panel_init` 已删**，改 `devm_drm_panel_alloc`（分配+初始化合一，必须排在 probe 最前） |
| 朝向 | 驱动完全不读 | 加 `.get_orientation` 回调 + probe 里 `of_drm_get_panel_orientation`（**原驱动没有，不是移植而是新增**） |
| DSC 每包片数 | `dsi->dsc_slice_per_pkt = 2` | **字段不存在**，见下 |

### DSC slice_per_pkt：唯一的未决项

`dsc_slice_per_pkt` 是 pmOS sm8250 下游 fork 的字段，mainline 没有。
7.2.8 的 `drivers/gpu/drm/msm/dsi/dsi_host.c` 自己写明：

```
:955   bytes_per_pkt = dsc->slice_chunk_size; /* * slice_per_pkt; */
:962   Since the current driver only supports slice_per_pkt = 1,
:1121  Currently, the driver only supports default value of slice_per_pkt = 1
:1123  TODO: Expand mipi_dsi_device struct to hold slice_per_pkt info
```

面板自己的 PPS（init 序列里那条 `0x9e` 长写）把拓扑写死了 —— 解码其载荷：
`0x0438`=1080 宽、`0x0960`=2400 高、`0x021c`=540 片宽、`0x0008` 片高，
所以 `slice_count = 1080/540 = 2` 不可改。唯一的变量是**每行发 2 个包
（mainline）还是 1 个包装 2 片（下游）**。

阶段 1 先按 mainline 走：它的路径自洽，且是所有上游 DSC 命令模式面板走的路。
**若 Task 6 实测花屏或黑屏，补救方案**是按那条 TODO 实现 slice_per_pkt，
改三处后作为 `patches/0018`：

- `dsi_update_dsc_timing()`：`bytes_per_pkt = slice_chunk_size * slice_per_pkt`
- 同函数：`pkt_per_line = slice_per_intf / slice_per_pkt`
- 命令模式的 word count：`wc = slice_chunk_size * slice_per_pkt + 1`

### 显示模式

pmaports 的 60 Hz 模式在 `#if 0` 里，注释写明 "60hz mode causes screen
flickering"，原样保留。活动模式两个：**120 Hz（`DRM_MODE_TYPE_PREFERRED`）
与 90 Hz**。计划原本要求三个模式并断言恰好 3 条 `.clock =`，前提不成立。

### 顺带修掉的一处 panic

`ams667xx01_get_current_mode()` 先解引用 `ctx->connector`，却只检查
`!connector->state`。`ctx->connector` 要到 `get_modes()` 才赋值，而该函数
经 `prepare` → `init_sequence` 在每次面板上电时都跑 —— 阶段 1 由 fbcon
很早拉起显示，正是容易出现异常顺序的场合，那里 NULL 解引用是 panic 而非黑屏。

### 断言 compatible 不要用 strings

计划 Task 3/4 的交叉断言写的是 `strings "$DTB" | grep -qx "$compat"`。
**这会产生假阴性**：DTB 是二进制，相邻属性值的尾字节会和字符串并进同一个
token —— 实测 `xiaomi,alioth-ams667xx01` 前面紧挨着一个 `2`，于是
`grep -qx` 匹配不上，而 compatible 其实完全正确。

另外 modalias 的形状是 `of:N<name>T<type>C<compatible>`，后面可能再跟
一个 `C*`，计划的 `sed 's/^of:N\*T\*C//'` 没处理尾部。

两处都已并入 `scripts/assert-alioth-dtb.py`（`--module` 选项），它按
DTB 结构遍历比对，顺带检查模块到底有没有 `of:` 别名。

## Task 5 前置条件（阶段 1 调试镜像）

上游的 **REDMAGIC 6（`kernel-sm8350`）就是手机移植模板**，它的
`steamos.config` 把每条手机专属配置的理由都写在注释里。把那份清单对着
sm8250 的实际 `.config` 逐条比对，ROCKNIX 的基线几乎什么都有（dispcc、
refgen、gpucc、LLCC、AOSS、USB DWC3 双角色、QMP COMBO PHY、TYPEC、
ROLE_SWITCH、CONFIGFS、PCIE_QCOM、POWER_SEQUENCING_QCOM_WCN、UHID 全是 `=y`），
只差 5 项，且全部是调试通道相关：

| 配置 | sm8250 现状 | 缺了会怎样 |
|---|---|---|
| `CONFIG_USB_CONFIGFS_ACM` | not set | `usb_shell()` 建不出 `acm.usb0`，**`/dev/ttyACM0` 串口通道不存在**（计划 Task 5 Step 7 的「通道一」） |
| `CONFIG_U_SERIAL_CONSOLE` | 缺失 | gadget 上的串口控制台 |
| `CONFIG_DRM_SIMPLEDRM` | not set | 接不管 bootloader 的 splash framebuffer —— 这是**比面板驱动更早**的日志通道 |
| `CONFIG_PSTORE_RAM` | `=m` | 模块在 initramfs 里加载不上，等于没有 |
| `CONFIG_PSTORE_CONSOLE` / `_PMSG` | not set | 控制台日志不进 ramoops，panic 原因读不到 |

加上先前几节的结论，阶段 1 调试镜像的完整配方：

```
# 配置（阶段 2 有 rootfs 后可改回 =m）
CONFIG_DRM_PANEL_SAMSUNG_AMS667XX01=y   # 上游手机移植同样做法，见下
CONFIG_TOUCHSCREEN_FT8756=y
CONFIG_USB_CONFIGFS_ACM=y
CONFIG_U_SERIAL_CONSOLE=y
CONFIG_DRM_SIMPLEDRM=y
CONFIG_PSTORE_RAM=y
CONFIG_PSTORE_CONSOLE=y
CONFIG_PSTORE_PMSG=y

# soc.env
FW_BUILTIN=1                            # GPU zap / WiFi 固件进内核镜像

# 构建环境
DTBS_OVERRIDE=sm8250-xiaomi-alioth      # 单 DTB 镜像
CMDLINE_QUIET=0                         # console=tty0 loglevel=4
KERNEL_CMDLINE_EXTRA="steamos.usbshell=1 fbcon=rotate:1"
```

`CONFIG_DRM_PANEL_*=y` 不是我的发明 —— REDMAGIC 6 的 fragment 里是
`CONFIG_DRM_PANEL_NUBIA_NX669J=y`，注释写得很直白：

> Display: DPU + DSI (C-PHY, DSC) and the NX669J panels. **Built in: the
> console on the real panel is the only log channel before the rootfs.**

### `steamos.usbshell=1` 是调试 shell 的唯一开关

`kernel-common/initramfs/init` 的 `usb_shell()` 已经实现了 spec 选定的两条
通道：USB gadget 的 ACM 串口（设备侧 `/dev/ttyGS0` → 主机 `/dev/ttyACM0`）
与 NCM 网卡上 `172.16.42.1:23` 的 root shell（nc，不是 telnetd —— 见下文
「网络 shell 一直是死的」）。它由 cmdline 的 `steamos.usbshell=1`
开启，且在**挂根之前**执行（`init` 第 90 行），所以挂根成败都不影响。

计划的 Global Constraints 里没有这一项，必须补上，否则没有任何调试通道。

### 挂根失败是安全的

`init` 第 177 行用 `mount -t ext4 -o rw` 挂 `steamos.root=`。阶段 1 的
`userdata` 上还是 Android 的 /data（f2fs 且加密），ext4 的超级块检查会在
只读探测阶段失败，**不会写入**；随后第 254–260 行落到 `exec sh`。
所以 Global Constraints「禁止写 userdata」与 `steamos.root=PARTLABEL=userdata`
不冲突，`fastboot --set-active=b` 回 Android 的退路也仍然有效。

### simpledrm 与 ramoops 都需要 DTS 配合

| | alioth 的值 | 来源 |
|---|---|---|
| 连续 splash framebuffer | **`0x9c000000`，大小 `0x2300000`** | 原厂 DTS 的 `cont_splash_region@9c000000`（`pmaports-alioth/Notes/dts/alioth_lineageos.dts:40502`） |
| ramoops | **无现成值** | 原厂用 Qualcomm 自己的 `mem_dump`/minidump，不是 pstore，需自行挑空闲区域 |

1080 × 2400 × 4 = `0x9E3400`，在 `0x2300000` 之内。节点形状照
`kernel-sm8350/patches/0007`：

```dts
framebuffer0: framebuffer@9c000000 {
    compatible = "simple-framebuffer";
    reg = <0 0x9c000000 0 (1080 * 2400 * 4)>;
    width = <1080>; height = <2400>; stride = <(1080 * 4)>;
    format = "a8r8g8b8";
    clocks = <&gcc GCC_DISP_HF_AXI_CLK>, <&gcc GCC_DISP_SF_AXI_CLK>;
    power-domains = <&dispcc MDSS_GDSC>;
};
```

**还必须配一条 `no-map` 的 reserved-memory**：alioth DTS 现有的预留最高只到
`0x92700000`，`0x9c000000` 没被预留，内核会直接分配到那里把 splash 覆盖掉。

ramoops 优先级低于 simpledrm（没有已知安全地址），阶段 1 可先不做。

## 触摸驱动前向移植（Task 4）

`patches/0018-input-add-focaltech-ft8756.patch`，基线 6.19.6 → 7.2.8。

**API 移植量为零。** 驱动用到的全部接口在 7.2.8 都存在且签名未变：
`devm_input_allocate_device`、`input_mt_init_slots`、
`touchscreen_parse_properties`、`devm_request_threaded_irq`、
`input_register_device`、`devm_regmap_init`、`pm_sleep_ptr`、
`DEFINE_SIMPLE_DEV_PM_OPS`、`drm_is_panel_follower`、
`devm_drm_panel_add_follower`、`linux/unaligned.h`。

注意它是 **SPI** 设备（`ft8756_spi_probe(struct spi_device *)`），而计划指定的
对照样本 `patches/0010` 的 ST7123 是 I2C —— 只有 input 子系统那半边可对照。

### 唯一的改动：补 `.of_match_table`

原驱动只声明了 `spi_device_id { "ft8756-spi", 0 }`，没有 OF 表。SPI 核心仍
能绑定它（去掉厂商前缀后与 `spi_device_id.name` 比对的旧路径），所以 probe
跑得起来；但 `MODULE_DEVICE_TABLE(spi, ...)` 生成的是 `spi:` 别名：

```
补之前： spi:ft8756-spi
补之后： of:N*T*Cfocaltech,ft8756-spiC*
        of:N*T*Cfocaltech,ft8756-spi
        spi:ft8756-spi
```

按 Global Constraints 它是 `=m`，而 udev 是按设备树节点的 `of:` modalias
加载模块的 —— 没有 OF 表，阶段 2 有了 rootfs 之后触摸会直接不工作，而
`dmesg` 里不会有任何错误（模块压根没被加载）。

### 两处与 DTS 的核对

- DTS 的 `touchscreen@0` 没有 `panel` 属性，`drm_is_panel_follower()` 为假，
  驱动走 `vio-supply` / `ibb-supply` 的 regulator 路径 —— 与 DTS 一致。
- **待观察**：DTS 写 `irq-gpio = <&tlmm 39 IRQ_TYPE_EDGE_FALLING>`，但 gpio
  属性的第三个 cell 是 GPIO flags，不是 IRQ 类型（pmaports 这里用法有误）；
  而驱动请求的是 `IRQ_TYPE_EDGE_RISING`。pmaports 实测可用，不改。若 Task 6
  触摸无响应，这是第一怀疑点。

## 阶段 1 调试镜像（Task 5）

### Xiaomi ABL 的实际行为（来自设备自己的 UART 日志，不是推测）

`pmaports-alioth/Notes/uart_logs/` 里是这台机器 bootloader 的真实输出。它一次
回答了计划里列为「需要真机试错」的三个未知项：

| 日志 | 结论 |
|---|---|
| `avb_slot_verify.c:577: ERROR: vbmeta_b: Error verifying vbmeta image: OK_NOT_SIGNED` → `VB2: Authenticate complete! boot state is: orange` → 继续启动 | **不需要刷 vbmeta。** 解锁的 bootloader 只是把校验状态标成 orange 就放行。kit 里 REDMAGIC 6 那条 `fastboot flash vbmeta_*` 在这台机器上是一次没有收益的写入。 |
| `Dtbo hdr magic mismatch 0, with D7B7AB1E` → `Best match DTB tags ...` → `Update Device Tree total time: 13 ms` → 启动成功 | **`erase dtbo_<槽>` 有效且被容忍**（magic 0 = 已擦除）。bootloader 跳过 overlay，直接用追加在内核后面的 DTB。 |
| `Best match DTB tags 356/0000002C/0x00000000/20001/...` | bootloader 按 `qcom,msm-id` + `qcom,board-id` 匹配追加的 DTB。`0x2C` = 44 = alioth DTS 里的 `qcom,board-id = <44 0>`。 |
| `Load Image vendor_boot_b total time: 121 ms`，而 pmOS 从不刷它 | **不需要动 `vendor_boot`。** |

另外 `device-xiaomi-alioth/deviceinfo` 没有 `deviceinfo_bootimg_header_version`，
而 `deviceinfo_generate_bootimg="true"`，所以 pmbootstrap 产出的是 **header v0** ——
那个镜像在这台机器上起得来，于是「v0 会不会被拒」这个未知项也不必用一次刷机去换。

净效果：刷机配方比 kit 里 REDMAGIC 6 的模板少两个分区写入，只剩
`erase dtbo_a` + `flash boot_a`。

### 镜像参数的来源

| 参数 | 值 | 为什么不是上游默认值 |
|---|---|---|
| `page_size` | 4096 | `deviceinfo_flash_pagesize="4096"`。上游 `mkbootimg-v0.py` 默认 2048，那是 ROCKNIX ABL 的值。 |
| `kernel_addr` | `0x00008000` | deviceinfo 的 `offset_base=0` + `offset_kernel=0x8000`。上游默认 `0x10000000`。 |
| `ramdisk_addr` | `0x01000000` | deviceinfo `offset_ramdisk`。 |
| `tags_addr` | `0x00000100` | deviceinfo `offset_tags`。 |

bootloader 两种都会重定位（它的日志里 RAM 从 `0x80000000` 起，上述地址全在 RAM
之下），但在无法便宜地试错的那一个镜像上，没有理由偏离已被证明过的那组值。

内核载荷是 **gzip(裸 `Image`) ++ 单个 alioth DTB**。pmaports 的 APKBUILD 用
`make zinstall`（即 `Image.gz`），所以 gzip 是这个 bootloader 实测接受的。注意
gzip 的必须是**裸 `Image`**：本配置 `CONFIG_EFI_ZBOOT=y`，此时内核自己产出的
`Image.gz` 是一个 EFI PE 包装而不是 gzip 流，没有 EFI 的 bootloader 永远解不开它 ——
这正是 pmaports README 里那个被称作 "THE IMPOSTOR" 的 bug。上游
`pack_kernel_img()` 压的就是裸 `Image`，所以这条路天然免疫。

### 阶段 1 必须编进内核的配置

阶段 1 的 initramfs 没有 `/lib/modules` 也没有 `modprobe`（`kernel-common/initramfs/init`
只做挂根和 `switch_root`），所以任何 `=m` 在这个阶段都等于不存在：

| 符号 | 基线值 | 阶段 1 需要 | 理由 |
|---|---|---|---|
| `DRM_PANEL_SAMSUNG_AMS667XX01` | `m` | `y` | 面板控制台是两条日志通道之一 |
| `TOUCHSCREEN_FT8756` | `m` | `y` | 同上（Task 6 验收用） |
| `SPI_QCOM_GENI` | `m` | `y` | **计划漏项。** 触摸挂在 `/soc@0/geniqup@9c0000/spi@990000`（`&spi4`，`qcom,geni-spi`）上；总线控制器是模块的话，编进内核的触摸驱动没有东西可绑。 |
| `DRM_SIMPLEDRM` | 未设 | `y` | 接管 bootloader 的 splash framebuffer |
| `USB_CONFIGFS_ACM` | 未设 | `y` | `ttyGS0` 串口通道 |
| `U_SERIAL_CONSOLE` | **配置里压根没出现** | `y` | 它依赖 `USB_U_SERIAL`，而后者由 ACM selects —— 不先开 ACM，这个符号不会被 offer，也就不会出现在 `.config` 里 |

`USB_CONFIGFS_NCM`、`USB_GADGET`、`USB_CONFIGFS`、`FRAMEBUFFER_CONSOLE`、`DRM_MSM`、
`TYPEC_QCOM_PMIC`、`TYPEC_TCPM`、`USB_DWC3_DUAL_ROLE`、`USB_ROLE_SWITCH` 基线已经是 `y`。

### 两条调试通道都成立的依据

USB gadget 要求 UDC 能注册出来。alioth 的 `&usb_1_dwc3` 是 `dr_mode = "otg"` +
`usb-role-switch`，角色来自 `&pm8150b_typec` 的 `usb-c-connector`。这条链走的是
**原生 SPMI 驱动**（`CONFIG_TYPEC_QCOM_PMIC=y` + `TYPEC_TCPM=y`），不经 PMIC GLINK /
UCSI，所以不需要 ADSP 固件、也不需要任何模块 —— 在 initramfs 里就能工作。

`initramfs/init` 的相关事实：
- `[ -n "$steamosroot" ] && rootarg="$steamosroot"` —— `steamos.root=` 覆盖 `root=`。
  必须用前者：这个 bootloader 会把自己的参数追加在我们的 cmdline 之后，而 init 的
  解析循环取最后一个 `root=`。
- `[ "$usbshell" = 1 ] && usb_shell` 在等根**之前**调用，所以 USB shell 先起来。
- `by_partlabel()` 读 `/sys/class/block/*/uevent` 的 `PARTNAME=`，不需要 udev。
- `PARTLABEL=*` 分支会等最多 `60 × 0.5s = 30 秒`。alioth 上 `userdata` 是真实存在的
  分区，所以立刻命中，`mount -t ext4` 随即在只读超级块探测阶段失败（f2fs 魔数不符，
  不写入），落到 `exec sh`。**挂根失败就是阶段 1 的预期结果。**

### 页大小与 VA_BITS

| | 本 kit 基线 | pmaports | 采用 |
|---|---|---|---|
| `ARM64_4K_PAGES` | `y` | `y` | `y` —— **FEX 的硬性前提成立，项目继续** |
| `ARM64_VA_BITS` | 52 | 48 | **52（不改）** |
| `PGTABLE_LEVELS` | 5 | 4 | **5（不改）** |

pmaports 的作者把 VA_BITS 降到 48、`PGTABLE_LEVELS` 降到 4，理由是 Cortex-A77/A55
不实现 LVA。但 ROCKNIX 的 SM8250 设备（retroid 等，同样是 A77/A55 的 SD865）就用这份
52/5 的配置在跑 —— 同核心、同配置、已启动，比 README 的推理强。README 自己也把
`CONFIG_EFI_ZBOOT=n` 标成真正的 "breakthrough"，VA_BITS 那条更像顺手改的。

## 自动回退：存在，但不是退路（2026-10-23 实测，第三版结论）

这一条我写错过两次，所以把三版都留在这里。

**第一版（写计划时）**：「bootloader 自带 `slot-retry-count:7` 自动回退」。依据是
`fastboot getvar all` 里 `slot-retry-count:a:7` / `:b:7` —— 纯粹按字面读变量名。

**第二版（独立审查后）**：「这台机器没有自动回退」。依据是两条：

- `Notes/uart_logs/` 里**每一次**启动都打 `A/B retry count NOT decremented`
  （`uart_log.txt:352`、`uart_logs_ext.txt:363/740/1116`、`uart_logs_ext2.txt:383`、
  `uart_logs_ext3.txt:337`，以及 `uart_logs_ext-elish.txt` 里的每一次）。
- 那份 `getvar all` 在手机启动过 Android 无数次之后仍报 `slot-retry-count:b:7`
  且 `slot-successful:b:no` —— 按次递减的计数器不可能还停在 7。

推理看着很硬，结论是错的。

**第三版（实测）**：自动回退存在。2026-10-23 在这台手机上，**没有写入任何分区**
的情况下（`fastboot boot` 只在 RAM 里跑）：一次跳进垃圾镜像让 SoC 崩了，之后的
几次启动尝试都失败，然后 bootloader **自己**把当时的活动槽 b 标成不可启动，并把
活动槽切到了 a。事后 `getvar all`：

```
current-slot:a            ← 事发前我亲手读到的是 b，期间无人运行 --set-active
slot-unbootable:b:yes
slot-retry-count:a:7      ← 同一次读取里 a 和 b 不同，b 这边确实在记账
slot-retry-count:b:4
```

第二版错在哪：`A/B retry count NOT decremented` 这行日志是真的，但它只说明某些
条件下不记账，不等于这台机器从不记账。拿一行日志的否定式去证明一个机制不存在，
是用不完全的证据下了完全的结论。而 `getvar` 那条依据更弱 —— 它来自 pmaports 仓库
里**另一台**机器（serialno 与本机不同）的抓取。

**后果（操作上很重要）：** 自动回退存在，但它不能当退路用，有两个代价。

1. 它会**花掉启动尝试**，而且落到另一个槽里的旧系统上。实测那边是起不来的旧
   Android：亮 Redmi 标志、黑屏、重复，不会自己停。
2. 它会**弄坏被放弃那个槽的标记**。slot b 的内容从头到尾没被动过，但它被标成了
   `slot-unbootable:b:yes`；要让它重新能启动，还是得手动
   `fastboot --set-active=b`（这条命令同时清 unbootable 并复位 retry 计数）。

所以操作上的退路没变，只是理由变了：按住音量下 + 电源进 fastboot，执行
`fastboot --set-active=b`，再往下才是 9008 EDL 救砖包。等 bootloader 自己动手
只会多花几次启动尝试，并且最后还是要跑这条命令。

「禁止做 successful 标记」这条约束仍然保留 —— 它是一次不必要的写入，而且会让
「测试过的槽」和「没测过的槽」无法区分。

## gzip + 追加 DTB 在这台机器上已被证明（独立审查提出质疑，核实后证伪）

审查怀疑过 gzip 内核 + 追加 DTB 的组合：它注意到三次 `Decompressing kernel image`
之后紧跟的是 `DTB offset is incorrect, kernel image does not have appended DTB`
（`uart_logs_ext.txt:382/384`、`759/761`、`1135/1137`），而那三次都进了重启循环。

查全部日志之后结论相反 —— `uart_logs_ext-elish.txt` 里有十余次这样的三连：

```
Decompressing kernel image total time: 356 ms
Best match DTB tags 356/0000002C/...
[    0.000000] Linux version 6.15.1 (pmos@nasarmasg5) ...
```

（`9866/9868`、`10245/10247`、`11001/11003`、`12911/12913`、`13290/13292`、
`14288/14290`、`15699/15701→15725`、`17285/17287→17311`、`20759/20761→20785`、
`21951/21953→21977`）

**gzip 内核 + 追加 DTB 一路跑到了 `Linux version`，反复如此。** 那三次失败的
cmdline 是 `quiet pmos_boot_uuid=...`，是真的没有追加 DTB 的早期镜像。

顺带确认了裸 `Image` + 追加 DTB 也可行（`uart_log.txt`、`uart_logs_ext2.txt`、
`uart_logs_ext3.txt` 的成功启动里没有 `Decompressing` 行）—— **两条路这个
bootloader 都接受**，所以上游 `pack_kernel_img()` 的 gzip 做法不需要改。

## 刷机脚本的其它硬化（独立审查发现）

| 问题 | 修法 |
|---|---|
| 不校验接的是哪台手机 —— 这个 kit 里有好几台别的手机的刷机脚本，任何一台在 fastboot 里且活动槽是 b，都能通过其余所有检查 | 加 `getvar product` 必须等于 `alioth` |
| `--boot`（零写入）被写入路径的槽位检查挡住，而且拒绝理由是误导的 | 槽位检查只对 `--test` 生效；`--boot` 在活动槽已是 a 时正是最有用的 |
| `getvar` 解析只接受 `name: value`，而这台机器的原始 INFO 行是 `(bootloader) name:value`（冒号后无空格）；`\| head -n1` 在 `pipefail` 下会把 SIGPIPE 变成无消息退出 | 改成纯 shell 解析，两种形状都接受，去掉管道，`fastboot` 非零退出时明确报错 |
| `echo YES \| ./flash-alioth.sh --test` 会无人值守地刷机 | 确认必须来自 TTY（`[[ -t 0 ]]`） |
| `SHA256SUMS` 声称能挡住过期镜像，其实每次构建都重写，只能挡住损坏 | 改正说明；并让 `flash-alioth.sh` **强制**先跑断言脚本（原先它谁都不调用，等于可选） |
| `second_addr` 用的是上游 ROCKNIX 基址 `0x10F00000`，与「只用被证明过的那组值」自相矛盾 | `mkbootimg-v0.py` 加 `--second-addr`，传 `0x00F00000` |
| `os_version` 取当天日期，同一个内核明天会产出不同镜像与不同校验和 | 支持 `SOURCE_DATE_EPOCH`，打包脚本用 `Image` 的 mtime |
| initramfs 默认找名为 `ROCKNIX` 的分区，找到就**读写挂载**并往里写日志；alioth 上没有这个名字纯属巧合 | cmdline 显式 `steamos.bootlabel=steamos-arm-no-boot-partition` |

断言脚本自己也被重写过一遍：原先 A 组每一条都能在约束被违反的情况下通过
（`grep -q current-slot` 会被 die 消息满足；统计写操作时 `echo "=> fastboot flash ..."`
和真命令分不清；`TARGET` 改成 `b` 全组照过）。现在先剔注释、再按 heredoc 跳过
文本段、再剔 `echo`/`printf` 行，然后才找命令；并且用 **9 个故意违规的变异体**
验证过每条断言真的抓得住：

```
✓ TARGET=b               → 目标槽钉死为 a
✓ flash 换成 echo        → 确实执行 flash boot_$TARGET
✓ 偷加 flash boot_b      → 代码里不碰 slot b 的分区
✓ 删掉 getvar current-slot → 运行时读活动槽
✓ 删掉 getvar product    → 校验设备型号
✓ 拒绝分支去掉 exit 1   → 以非零退出
✓ 写回「等它自己退回」  → 没有把等自动回退当退路
✓ 写回「retry 计数器不递减」→ 没有宣称自动回退不存在
✓ 删掉 --set-active=b    → 说明了退路
✓ 偷加 fastboot -w       → 整机写操作
✓ 偷加 bootctl mark-boot-successful → 标记 successful
```

## 首次真机启动的结论（2026-10-23，Task 5 Step 8）

`./flash-alioth.sh --test` 之后内核起来了，面板上有日志。阶段 1 原本列为「必须
真机才知道」的几项，一次全部落定：

| 结论 | 证据 |
|---|---|
| Xiaomi ABL 接受 boot header **v0** | 刷完直接启动 |
| `page_size=4096` + pmaports 那组载入地址正确 | 同上 |
| gzip 裸 `Image` + 追加单个 DTB 可行 | 同上 |
| **不需要刷 vbmeta** | 我们没刷，照常启动（解锁态 AVB 不匹配非致命） |
| `erase dtbo_<槽>` 足以绕开厂商 overlay | 同上 |
| 面板控制台通道成立 | 屏幕上有内核日志 |
| USB gadget 通道成立（到枚举为止） | 主机认到 `SteamOS ARM debug shell`，`cdc_acm` + `cdc_ncm` |

屏幕上读到的那一页：

```
[0.915571] DSI PLL(0) lock failed, status=0x00000000      dsi_phy_7nm.c:392
[0.931603] PLL(0) lock failed                              dsi_phy_7nm.c:515
[1.205782] ft8756-spi spi4.0: Chip ID mismatch: expected 0x5652, got 0xefef
[1.223356] ft8756-spi spi4.0: Chip ID mismatch: expected 0x8756, got 0x56b2
[1.267787] msm_dpu ...: [drm:adreno_request_fw] *ERROR* failed to load a650_sqe.fw
[1.918109] Warning: unable to open an initial console.
```

### 面板旋转：90，不是 270

厂商 DTS（pmaports、LineageOS）都写 `rotation = <270>`，照抄过来控制台确实横了，
但**上下颠倒 180 度**。Qualcomm 下游的旋转约定与 mainline DRM 的
`DRM_MODE_PANEL_ORIENTATION_*` 反向：`<270>` = RIGHT_UP，`<90>` = LEFT_UP，差 180 度。

这个值离机无法确定：`simpledrm`（`drivers/gpu/drm/sysfb/simpledrm.c`）**不读**
`rotation`，只有面板驱动的 `.get_orientation`
（`panel-samsung-ams667xx01.c:399`）会用它。所以屏幕上那个横屏控制台本身就证明了
**msm DRM + 我们的面板驱动**在驱动显示，而不是 simpledrm 在画 bootloader 的
splash framebuffer。

注意 DTS 里有四处 `rotation = <270>`，另外三处属于摄像头 sensor
（`cam_imx582` / `s5k5e9` / `imx355`）的安装旋转，与屏幕无关 —— 全局替换会把相机
一起转。断言脚本按 `compatible` 定位面板节点，不按出现次数，就是为了这个。

### 两个还没解决的问题（Task 6）

**DSI PLL 没锁**（`status=0x00000000`）。但显示在工作，所以要么后续重试成功，
要么还有别的解释；一页日志不够判断。

**触摸读不到 Chip ID**。`0xefef` 是典型的总线无应答。时间上它在 PLL 失败**之后**
（1.20s vs 0.91s），而 FT8756 是 `drm_panel_follower` —— 面板的上电/复位序列不对，
跟随它的触摸就会读到垃圾。两者很可能是同一个根因，不要分开修。

### `a650_sqe.fw` 加载失败：结论对，时机判断错

`FW_BUILTIN=0` 的 ruling 当时的理由是「GPU 固件在 `adreno_load_gpu()` 里惰性加载，
用户态首次 open DRM 才触发」。实测它在 `msm_dpu` bind 阶段（1.26s）就试了。
**结论仍然成立** —— 它只打一条 ERROR，显示照常工作，阶段 2 的 rootfs 里有这个固件
—— 但「惰性加载」那半句是错的。

## 第二版镜像的完整日志（2026-10-23）

`docs/logs/2026-10-23-first-boot-dmesg.log`，820 行，从 `/dev/ttyACM0` 直接拉下来
的。两条调试通道这一版都通了：串口上有 shell，`ping 172.16.42.1` 有回应。

### 显示路径是完整的，面板驱动确实在跑

```
0.771  [drm] Initialized simpledrm 1.0.0 for 9c000000.framebuffer on minor 0
0.939  DSI PLL(0) lock failed, status=0x00000000      （dsi_phy_driver_probe 里）
0.939  WARNING clk_core_disable / clk_core_unprepare  → 内核 Tainted [W]
1.256  msm_dpu ae01000.display-controller: bound ae94000.dsi
1.341  [drm] Initialized msm 1.13.0 ... on minor 1
1.609  fb0: sys_imageblit: framebuffer is not in virtual address space  ← simpledrm 被摘
1.649  msm_dpu ...: [drm] fb0: msmdrmfb frame buffer device
```

设备上查到：

```
/sys/bus/mipi-dsi/devices/ae94000.dsi.0/driver -> panel-samsung-ams667xx01
/sys/class/drm/card1-DSI-1  status = connected
```

所以 `simpledrm` 只负责开头那 0.9 秒，之后 msm DRM 接管，控制台跑在真正的面板上。
`PLL lock failed` 发生在 PHY 的 probe 阶段而不是 modeset，显示此后正常工作 ——
它是噪声还是隐患，这份日志还不足以定论，但它不阻塞阶段 1。

### 触摸：总线通、协议通、芯片答了，但 ID 不对

```
ft8756-spi spi4.0: enter ft8756_spi_probe
ft8756-spi spi4.0: supply lab not found, using dummy regulator
ft8756-spi spi4.0: Chip ID mismatch: expected 0x5652, got 0xefef
ft8756-spi spi4.0: Chip ID mismatch: expected 0x8756, got 0x56b2
```

已经排除的：

- **不是 DTS 的问题**。触摸节点与 pmaports 的原版逐字相同。
- **不是前向移植改坏的**。驱动与 pmaports 原版的唯一差异是我加的
  `of_match_table`（见下面的 diff），其余 635 行一字不差。
- **不是时序/上电顺序**。原始启动时触摸读 ID 在 1.228s，**早于** msm DRM 初始化
  （1.341s）；但在系统空闲 403 秒、显示完全起来之后手工
  `echo spi4.0 > /sys/bus/spi/drivers/ft8756-spi/bind` 重试，读到的是**完全相同**的
  两个值。确定性的，不是竞态。
- **不是总线不通**。`/proc/interrupts` 里 `990000.spi` 有计数；而且驱动的
  `ft8756_spi_read` 会在状态字节异常时打 `Failed to read data status`、CRC 不符时打
  `crc error` —— 这两条一条都没出现，说明芯片按协议应答了，连 CRC 都对得上。

所以芯片在说话，只是说的不是驱动期待的内容：寄存器 `0xA3` 和 `0x9F` 都读到 `0xef`，
ROM boot 路径（写 `0x55 0xAA` 后读 `0x90`）读到 `0x56b2` 而不是 `0x8756`。

一条还没验证的线索：alioth 出厂有多家面板/触摸供应商，vendor cmdline 里有
`msm_drm.dsi_display0=qcom,mdss_dsi_k11a_38_08_0a_dsc_cmd`。本机与 nikroks 那台
（serialno 与本机不同）可能根本不是同一个触摸变体。

### 另外两条不影响启动的噪声

- `Initramfs unpacking failed: invalid magic at start of compressed archive`（0.708s）
  —— 这是 `mkbootimg-v0.py` 写的那个 ROCKNIX 哑 ramdisk。真正的 initramfs 编在
  Image 里（`EMBED_INITRAMFS=1`），`Run /init as init process` 在 2.206s 正常发生。
- `Unknown kernel command line parameters "errors=remount-ro"` —— 那是 ext4 的挂载
  选项，内核不认识就交给用户态，符合预期。

### 一个旧证据的更正

前一天驳回独立审查 #9（质疑 gzip + 追加 DTB）时，我引用的是
`Notes/uart_logs/uart_logs_ext-elish.txt`，并称它证明了这条路「在这台机器上」可行。
那份日志是 **elish（小米平板 5 Pro）** 的 —— 同 SoC、同系 bootloader，但不是
alioth。结论现在由真机直接证实（镜像就是这么打包的，它起来了），但当时的论证把
另一台设备的日志说成了本机证据。


## 触摸：诊断收口 —— 应用固件没在跑（2026-10-23，Task 6）

这一项查了四轮，三个看着合理的根因被逐个证伪。最终结论与驱动参数、
DTS 都无关。

### 实测的最终事实

带 20×20ms 重试的 ID 读取（补丁 0023）之后：

```
[1.766865] no valid answer from 0xA3 in 20 tries, last 0xef   ← 任何 0x55 0xAA 之前
[1.787508] Chip ID mismatch: expected 0x8756, got 0x56b2      ← romboot id
[1.787628] unknown chip id, continuing (ft8756.ignore_id=1)
[2.478864] no valid answer from 0xA3 in 20 tries, last 0xef   ← 第二次复位之后
```

58 秒 uptime、显示完全起来时手工 `unbind`/`bind` 重做一遍，结果完全
相同。点数据寄存器（`ft8756.poll`）161 次轮询、覆盖「手指按住 5 秒」的
整个窗口，全部返回 62 字节 `0xEF` + 正确 CRC；IRQ 152 恒为 0。

### 排除清单（全部在设备上直接读到，不是推断）

| 怀疑 | 排除依据 |
|---|---|
| DTS 写错 | 触摸节点与 pmaports 原版逐字相同 |
| 前向移植改坏驱动 | 与 pmaports 原版 635 行逐行 diff，唯一差异是我加的 `of_match_table` |
| 引脚没复用成 GPIO | `pin 33 (GPIO_33): device spi4.0 function gpio`，`pin 39` 同 |
| 还在复位里 | `gpio33 : out high func0 8mA pull up` |
| 中断线被拉死 | `gpio39 : in high func0 8mA pull up` —— 空闲为高，没被按住 |
| 电源缺一条 | 厂商 DTS 的 `focaltech@0` 只有两条：`vcc_i2c` = pm8150a-l1（L1C 1.8V）、`vdd` = pm8150a-l10（L10C 3.0V）。我们给的 `vio` = `vreg_l10c_3p0`、`ibb` = `vreg_l1c_1p8` 正是这两条，都已 enable；缺的 `lab` 在厂商节点里根本不存在 |
| 中断类型错 | 驱动写死 `EDGE_RISING` 而 DTS/厂商都是下降沿 —— 是真缺陷，但解释不了零计数：芯片若拉低再释放，上升沿照样触发。线从未动过 |
| 总线/协议故障 | `ft8756_spi_read` 自己按 poly 0x8408 校验 CRC，不符会打 `crc error`。整轮数百帧、三种载荷长度（1 字节 `0xef`、2 字节 `0x56b2`、62 字节全 `0xef`）一次都没出现过 |
| 认错芯片（ST / Novatek / Himax） | 同上 —— 非 FocalTech 协议的芯片算不出这个 CRC。`fts,tp-vendor = <0x38>` 与 cmdline `k11a_38_08_0a` 曾指向 ST，作废 |
| 复位后读得太早 | 补丁 0023 的 20×20ms 重试，两次复位各 400ms，全程 `0xef` |
| 驱动自己把芯片按在 ROM 里 | 曾是第三轮的结论，被 0023 证伪：第一次读（在任何 romboot 命令之前）就已经全程 `0xef` |

### 诊断

这台机器的触摸控制器是 FocalTech 协议芯片，电源、引脚复用、复位时序、
SPI 协议全部正确，但**应用固件没有在跑，复位也启动不了它**。只有 ROM
级别应答：romboot id `0x56b2`（厂商驱动期望 `0x8756`），所有应用寄存器
`0xEF`（驱动自己把点数据里的 `0xEF` 定义为「无有效数据」），INT 线永不
动作。

alioth 的触摸确为多供应商 —— 厂商 DTS 在同一条 SPI 上并列四个节点：
novatek（nt36523，`display-maker` 0x08/0x42）、himax（hxcommon）、
focaltech（`focaltech,fts`）、fts（ST FingerTipS，固件名
`st_fts_l3a.ftb`），Android 按面板/TP 供应商码选择。参考实现（nikroks）
那台能读出 `0x5652`/`0x8756`，所以他的是另一颗。

### 下一步

主机侧把固件下载进 PRAM 并启动 —— 驱动里一直定义着没被使用的
`FT8756_ROMBOOT_CMD_SET_PRAM_ADDR` / `WRITE` / `ECC` / `START_APP`
正是为此预留。前提是先拿到适用于 romboot id `0x56b2` 这颗芯片的固件。

注意：往触摸 IC 的 flash 写固件是会把这颗芯片写坏的操作。下载到 PRAM
并启动不写 flash，应优先走这条。

## 触摸：上一节的诊断是错的（2026-10-23，原厂 Android 实测推翻）

上一节断言「应用固件没在跑，下一步是 PRAM 固件下载」。**那是错的。**
进原厂 Android（已 root）用厂商驱动自己的 sysfs 问同一颗芯片：

```
Read A3: 56        ← 正是 mainline 驱动期望的值
Read 9F: 52
Read A6: 1D        ← 应用固件 v0x1d，正在运行
fts_driver_info:   IC ID:0x5652 / Driver Ver:Focaltech V3.2 20200422
                   reset gpio:1133, int gpio:1139, irq:395 / SPI mode 0, max 10 MHz
fts_dump_reg:      Power Mode:0x00  FW Ver:0x1d  Vendor ID:0x8d
                   INT count:0x73   ESD count:0x5f
of_node ->         .../spi@990000/focaltech@0
```

所以：同一颗芯片、同一个驱动期望的 ID、固件就在芯片里、中断在正常计数。
「多供应商、我们这台是另一颗」的推论作废；`/vendor` 与 `/odm` 下也**没有**
任何 FocalTech 固件文件，固件本来就在芯片的 flash 里。

### `0xEF` 到底是什么（在 Android 上复现出来的）

在 Android 上写 `0x55 0xAA`（我们驱动 ID 不匹配时发的那条，romboot 入口），
然后复位，厂商驱动立刻也开始读到 `0xEF`：

```
echo 55AA > fts_rw_reg
cat fts_hw_reset   → hw reset executed
echo A6 > fts_rw_reg; cat fts_rw_reg   → Read A6: EF      ← 我们的症状
cat fts_hw_reset   → hw reset executed
echo A6 ...                            → Read A6: EF      ← 复位清不掉
cat fts_hw_reset   → （第三次，仍然 EF）
```

而把屏幕关掉再打开（`input keyevent 26` 两次，走厂商驱动的 suspend/resume
路径），立刻恢复：

```
Read A3: 56
Read A6: 1D
```

FocalTech 的 resume 做的是 `fts_power_source_ctrl(ENABLE)` + `fts_reset_proc()`，
而 suspend 把 vdd/vddio **关掉**。也就是：

> **芯片离开 ROM 模式只认电源周期，复位不行。**

### 我们的驱动为什么做不到

`ft8756_spi_probe` 只调 `regulator_bulk_enable()`。这两条轨在我们进 probe
时已经是开的（bootloader 留着的），所以 enable 只是把引用计数加一，**电平
从未下降过**，芯片从来没有经历一次干净的上电。补丁 0024 改成真正的电源
周期：enable → disable → 30 ms → enable，复位线在整个过程中保持拉低（它在
probe 更早处就以 `GPIOD_OUT_LOW` 取得，此时还没被释放）。

这样做是安全的：`vio-supply = <&vreg_l10c_3p0>` 与 `ibb-supply =
<&vreg_l1c_1p8>`（也就是厂商的 vdd = pm8150a-l10 3.0V 与 vcc_i2c =
pm8150a-l1 1.8V）在整份 DTS 里**只有触摸这一个用户**，所以放掉我们的引用
确实会让电平下降。

### 这一轮里被证伪的三条自己的结论

| 曾经的结论 | 被什么证伪 |
|---|---|
| 「是另一颗芯片，romboot id 0x56b2 不是 0x8756」 | 厂商驱动读到 `IC ID:0x5652`，就是 mainline 期望的值 |
| 「应用固件不在芯片里，要 PRAM 下载」 | `FW Ver:0x1d` 在跑；`/vendor`、`/odm` 下没有任何 FocalTech 固件文件 |
| 「驱动用 0x55 0xAA 把芯片按在 ROM 里」（上一版的根因） | 加重试之后，第一次读（任何 romboot 命令之前）就已经 400ms 全程 `0xef` |

补丁 0020（txBuf 越界）、0021（`ignore_id`）、0022（`poll`）、0023（重试 +
离开 ROM）修的都是真缺陷，但它们对**现象原因**的判断都不对。真正的原因要
靠一台能工作的同款设备才能看出来 —— 这一轮的教训是：有一个已知可工作的
参照系（原厂 Android + root）时，先去那里量，比在自己这边连续推断四轮便宜
得多。

## ramoops：地址是有的（2026-10-23 实测，推翻此前结论）

`kernel-sm8250/steamos.config` 此前写着「alioth 原厂 DTS 没有 ramoops 区域，
每一个看着空闲的地址都是固件的或被 ABL 重写的」，于是把 `PSTORE_RAM` 留在
`=m`。**这条是错的。** 原厂 Android 的设备树里有：

```
/sys/firmware/devicetree/base/reserved-memory/ramoops
  compatible  = "ramoops"
  reg         = <0x0 0xb0000000 0x0 0x00100000>    ← 0xB0000000，1 MiB
  record-size = <0x00100000>
  max-reason  = <4>
```

并且它的内核真的把驱动绑在那里（`/sys/bus/platform/devices/b0000000.ramoops`，
驱动 `ramoops`）。`0xb0000000` 与我们 DTS 的 reserved-memory、与
`sm8250.dtsi` 都不冲突。

我们的 DTS 现在带上这块区域，但分法与原厂不同：原厂把 `record-size` 设成
整块 1 MiB，于是只有一条 oops 记录。对一个移植项目来说，**连续的 console
日志**才是更有用的那一半 —— 在 USB 和面板都还没起来之前死掉的内核，今天
什么都留不下。所以切成 `record-size = 0x40000`、`console-size = 0x80000`、
`ftrace-size = 0x20000`、`pmsg-size = 0x20000`，并把 `max-reason` 开到 5。
配置相应改为 `CONFIG_PSTORE_RAM=y` / `PSTORE_CONSOLE=y` / `PSTORE_PMSG=y`
（`=y` 而不是 `=m`，理由和面板、触摸驱动一样：阶段 1 没有 rootfs，需要先
加载模块的崩溃日志对启动期崩溃毫无用处）。

## 充电：spec §280 的裁决被推翻（2026-10-23）

原裁决是「不加载充电驱动」，理由是社区 PM8150B 驱动会把浮充上限设到约
4.87 V（安全值 4.435 V，有电池鼓包与起火风险）。读了实际参与编译的那份
驱动（`drivers/power/supply/qcom_pm8150b_charger.c`，由 `CONFIG_CHARGER_QCOM_SMB5=y`
编入），这个理由不成立：

```c
rc = clamp(chip->batt_info->voltage_max_design_uv, 3600000, 4450000);
rc = (rc - 3600000) / 10000;
regmap_update_bits(..., FLOAT_VOLTAGE_CFG, FLOAT_VOLTAGE_SETTING_MASK, rc);
```

寄存器是 3.6 V 起点、10 mV 步长（与 Qualcomm 自己 smb5 的
`.fv = {.min_u = 3600000, .max_u = 4790000, .step_u = 10000}` 一致），而驱动
把请求 **clamp 在 4 450 000 µV** —— 正是原厂 Android 自己报的
`/sys/class/power_supply/bms/voltage_max_design`。4.79 V 是这颗寄存器的硬件
上限，驱动从不写到那里。

输入侧同样保守：驱动启用 AICL（周期重跑 + ADC 检测）与
`SUSPEND_ON_COLLAPSE_USBIN`，供电撑不住时自己退档。

于是 `&pm8150b_charger` 启用，电池节点改为 `voltage-max-design-microvolt =
<4450000>`（与原厂一致，也正好是 clamp 值）并显式写出
`constant-charge-current-max-microamp = <2000000>`（0.44C；安全相关的数值
应该是 DTS 里的决定，而不是「容量的一半」这种副作用）。

**这不带来快充。** 原厂 33 W 走 BQ25970 电荷泵（Android 上的
`bq2597x-charger`，`i2c@884000` 的 0x66），这里没有那个驱动 —— 只有 PMIC
自己的通路。

断言脚本第 6 条随之重写：从「charger 必须 disabled」改成真正的安全属性 ——
电池节点最大电压 ≤ 4.45 V、充电电流上限必须显式、启用的 charger 必须指向
电池节点。改之前先在旧 DTB 上跑过，两条按预期失败（4460000 超限、电流属性
缺失），确认断言真的在检查。

## USB-C：有线手柄需要的那一条线（2026-10-23）

原厂 Android 上这个口是完整的双角色口：

```
/sys/class/typec/port0:  port_type=[dual] source sink,  PD rev 3, Type-C rev 1.3
extcon: qcom,qpnp-smb5 → USB / USB-HOST;  pdphy@1700 (PM8150B)
控制器: a600000.ssusb → a600000.dwc3
```

我们的内核配置其实早就齐了：`USB_DWC3_DUAL_ROLE=y`、`USB_XHCI_HCD=y`、
`USB_ROLE_SWITCH=y`、`TYPEC_QCOM_PMIC=y`、**`REGULATOR_QCOM_USB_VBUS=y`**，
手柄侧 `JOYSTICK_XPAD` / `HID_PLAYSTATION` / `HID_NINTENDO` / `HID_SONY` /
`HID_MICROSOFT` / `INPUT_JOYDEV` 都在，`HID_STEAM=m`。DTS 也已有
`dr_mode = "otg"`、`usb-role-switch`，`&pm8150b_vbus` 与 `&pm8150b_typec`
都 okay。

缺的是**它们之间的那一条连线**。首次真机启动日志里有：

```
qcom,pmic-typec c440000.spmi:pmic@2:typec@1500: supply vdd-vbus not found, using dummy regulator
```

`pm8150b.dtsi` 的 typec 节点不带 `vdd-vbus-supply`，所以驱动拿到的是 dummy
regulator —— **没有任何东西能打开 VBUS**，一个靠口取电的有线手柄因此不会
工作。补上 `vdd-vbus-supply = <&pm8150b_vbus>;`。

还有一条待查：同一份日志里 `typec@1500: deferred probe pending: (reason
unknown)`。要在真机上确认 typec 这次有没有 probe 成功。

## 第四版镜像：触摸／充电／ramoops 三项通过，USB-C 根因定位（2026-10-23）

含补丁 0024（probe 期电源周期）、ramoops 区域、充电节点启用、typec
`vdd-vbus-supply` 的那一版，真机实测结果：

### 触摸：完全工作

```
ft8756-spi spi4.0: supply vio was on before probe      ← 机制证实
ft8756-spi spi4.0: supply lab was on before probe
ft8756-spi spi4.0: supply ibb was on before probe
ft8756-spi spi4.0: polling point data every 50 ms
ft8756-spi spi4.0: FT8756 touchscreen initialized
```

三行 `was on before probe` 正是补丁 0024 要证明的事：轨在 probe 之前
已经是开的，所以 `regulator_bulk_enable()` 只加引用计数、不产生电平
变化，芯片从来没经历过 POR。显式 disable→30ms→enable 之后，**没有
`Chip ID mismatch`，也没有 `unknown chip id, continuing`** —— ID 检查
自己就过了，`ignore_id` 这次根本没被用上。

`IRQ 152 (msmgpio 39 Edge spi4.0)` 记到 7398 次中断，
`/sys/class/input/` 有 `event0..event3`。中断路径可用，所以
`ft8756.poll=50` 是多余的，已从 cmdline 去掉。

### 充电：工作（不含快充）

```
/sys/class/power_supply/battery/capacity     = 80
/sys/class/power_supply/battery/status       = Charging
/sys/class/power_supply/battery/voltage_now  = 4288074
/sys/class/power_supply/pm8150b-charger/online = 16
```

`CONFIG_CHARGER_QCOM_SMB5=y`、`CONFIG_BATTERY_QCOM_FG=y` 本来就编进去
了，dtsi 的 charger 节点连 `io-channels` 都齐，缺的只是
`status = "okay"` 和电池节点上的安全属性。快充不在其中：BQ25970 电荷泵
没有 mainline 驱动，拿到的是 SDP/DCP 这一档。

注意 `constant_charge_voltage_max` 这个属性不存在 —— 想核对浮充上限只能
读驱动里的 `clamp(..., 3600000, 4450000)`，不能读 sysfs。

### ramoops：工作

```
OF: reserved mem: 0x00000000b0000000..0x00000000b00fffff (1024 KiB) map non-reusable ramoops@b0000000
pstore: Using crash dump compression: deflate
printk: legacy console [ramoops-1] enabled
pstore: Registered ramoops as persistent store backend
ramoops: using 0x100000@0xb0000000, ecc: 0
```

`/sys/fs/pstore/` 存在但为空 —— 这是 ramoops 使能后的**首次**启动，上一
版镜像还没有这个区域，RAM 里没有有效记录。要再启动一次才能验证持久性。

**读负面结果时的陷阱**：下一次是走 fastboot 刷机重启，而 ramoops 依赖
DRAM 内容跨复位保留。如果下一次启动 pstore 仍为空，不能直接断定 ramoops
坏了 —— 还要区分「bootloader 阶段 DRAM 内容没保住」这一种可能，办法是
从 shell 里直接 `reboot` 做一次热重启再看。

### USB-C：根因是 `CONFIG_TYPEC_MUX_FSA4480=m`

上一节留的那条待查（`typec@1500: deferred probe pending: (reason
unknown)`）在这一版仍然存在，`vdd-vbus-supply` 补上之后
`supply vdd-vbus not found` 确实消失了，但端口还是没起来。

先把 `Fixed dependency cycle(s)` 这条线索排除掉。日志里
`typec@1500/connector` ↔ `typec-mux@42` ↔ `usb@a600000` 之间反复出现这类
行，看上去很像依赖环导致 probe 卡死。它不是原因：fw_devlink 打这行是在
报告**它已经解开的**环。

真正的根因从 debugfs 拿到：

```
# mount -t debugfs none /sys/kernel/debug
# cat /sys/kernel/debug/devices_deferred
c440000.spmi:pmic@0:rtc@6000	platform: wait for supplier /soc@0/spmi@c440000/pmic@0/nvram@b100/rtc-offset@bc
c440000.spmi:pmic@2:typec@1500	
1c00000.pcie	qcom-pcie: cannot initialize host
```

typec 那一行的**原因列是空的** —— probe 返回了 `-EPROBE_DEFER` 却没有调
`device_set_deferred_probe_reason()`。顺着这个特征进源码：

- `typec_register_port()` 调 `typec_switch_get()` / `typec_mux_get()`
  （`drivers/usb/typec/class.c:2777,2784`），并把错误原样往外传。
- 这两个在 DT 声明了连接、但驱动尚未注册时返回 `-EPROBE_DEFER`，
  且不设 reason（`drivers/usb/typec/mux.c:61,298`）。注释原文就是这个
  场景：*"ERR_PTR(-EPROBE_DEFER) when a connection was found but the
  switch has not been enumerated yet"*。

而 `/sys/bus/i2c/devices/15-0042/name` 是 `fsa4480`、i2c 设备在，
`readlink driver` 却是空的 —— 驱动没绑定。因为
`CONFIG_TYPEC_MUX_FSA4480=m`，而**阶段 1 没有 rootfs，就没有
`/lib/modules`，没有 modprobe，模块永远加载不了**。

不重编译就验证了这个结论：把同一次构建产出的 `fsa4480.ko`（12 KB，无
依赖）用 busybox `wget` 从主机拉到手机的 `/dbg`（tmpfs，这次 `/run/t`
不存在）再 `insmod`，`/sys/class/typec/port0` 当场出现：

```
data_role                    host [device]
power_role                   source [sink]
port_type                    [dual] source sink
orientation                  normal          ← FSA4480 mux 在上报方向
usb_power_delivery_revision  3.0
/sys/class/usb_role/a600000.usb-role-switch/role = device
```

这正是一个工作中的双角色口插在 PC 上该有的状态。改成 `=y`。

### 推广出来的规则：阶段 1 里 `=m` 等于没有

这个坑会反复咬人，所以把检查手段记下来。在真机上一行命令列出所有**有
设备节点但没绑驱动**的设备：

```sh
for d in /sys/bus/platform/devices/* /sys/bus/i2c/devices/* \
         /sys/bus/spi/devices/* /sys/bus/spmi/devices/*; do
  [ -e "$d/driver" ] || { c=$(cat $d/of_node/compatible 2>/dev/null | tr "\0" " ")
    [ -n "$c" ] && echo "$(basename $d)  ->  $c"; }
done
```

这一轮扫出来的第二个同类受害者：`nvram@b100 -> qcom,spmi-sdam` 没有驱动，
而 `CONFIG_RTC_DRV_PM8XXX` 本身已经是 `=y`。PM8150 的 RTC 要从隔壁 SDAM
nvmem 取 offset，模块化的 SDAM 让 RTC 一直 deferred（就是上面 deferred
列表第一行），结果整机没有墙上时钟。一并改 `CONFIG_NVMEM_SPMI_SDAM=y`。

`CONFIG_QCOM_GPI_DMA=m` 不改：i2c/spi 走 FIFO 模式正常工作，为已经能跑的
东西打开 DMA 路径是净增风险。

其余未绑定的设备都在范围外或属于阶段 2：`camss` / `camcc` / `cci`（相机）、
`nxp,pn553`（NFC）、`cs35l41` ×2 + `sm8250-sndcard`（音频，还要机内固件）、
`sm8250-adsp-pas`（要 rootfs 固件）、`pcie` + `pci17cb,1101`（QCA6390，
要固件且 `cannot initialize host`）、`pm8008` / `ir-spi-led` /
`pm8150l-flash-led`。`3d6a000.gmu` 未绑定是下一节那个微码问题的下游，
不是独立缺陷。

## adreno 的报错是固件缺失，不是 GPU 故障（2026-10-23）

控制台上这两行会让人以为 GPU 有问题：

```
msm_dpu ae01000.display-controller: Direct firmware load for qcom/a650_sqe.fw failed with error -2
msm_dpu ae01000.display-controller: [drm:adreno_request_fw] *ERROR* failed to load a650_sqe.fw
```

`-2` 是 `ENOENT`。这是设计上的必然：`soc.env` 里 `FW_BUILTIN=0`，GPU 微码
要从 rootfs 的 `/lib/firmware/qcom/` 加载，而**阶段 1 根本没有 rootfs**。
内核在 `msm_dpu` bind 阶段（约 1.46 s）就去请求微码，比任何用户态存在的
时间都早，所以必然 ENOENT。

同一段里的

```
adreno 3d00000.gpu: supply vdd not found, using dummy regulator
adreno 3d00000.gpu: supply vddcx not found, using dummy regulator
```

也无害：Adreno 650 的供电走 GMU，mainline 的 GPU 节点本来就不声明
`vdd` / `vddcx`。

影响范围是**没有 3D／Vulkan 加速**，显示链路本身完整工作 —— `msm_dpu`
拿到了 `fb0`，DSI 面板驱动已绑定，屏幕上有控制台，因为显示走 DPU+DSI
不经过 GPU。`3d6a000.gmu` 没绑驱动是同一件事的下游。阶段 2 放进 rootfs
和 `linux-firmware` 之后这些行就会消失。

阶段 2 要留意的一点（详见 `alioth-hardware.md`）：机内 `/vendor/firmware/`
的 `a650_zap` 是 Android 的旧分段格式（`.mdt` + `.b00/.b01/.b02`），而
mainline 要的是 `qcom/sm8250/a650_zap.mbn`（路径由 DTS 的 zap-shader
`firmware-name` 钉死，已被 assert-alioth-dtb.py 覆盖）。如果 linux-firmware 那份签名 zap
过不了小米的信任链，机内这份重新拼成 `.mbn` 才是能用的那份。

## 日志通道的真相：ramoops 不能用，ACM 控制台从未启用（2026-10-23）

这一节推翻两条此前当成事实用的东西。两者都是在真机上量出来的，不是推断。

### ramoops 注册正常，但记录活不过复位

三种复位都试过，`/sys/fs/pstore/` 始终是空的：

| 复位方式 | pstore 结果 |
|---|---|
| fastboot 刷机后重启 | 空 |
| 长按电源强制重启 | 空 |
| 主动 panic（`echo c > /proc/sysrq-trigger`）＋自动温重启 | 空 |

第三种是最有意义的那次：运行时把 `/proc/sys/kernel/sysrq` 和
`/sys/module/kernel/parameters/panic`（`core_param`，0644，可写）分别设为
1 和 20，往 kmsg 打两个标记再触发 panic。手机 20 秒后自己重启回来了 ——
**自动温重启这一环是工作的** —— 但 pstore 里什么都没有。

控制台后端在整个启动期间是连续写入的（`printk: legacy console
[ramoops-1] enabled`），所以 panic 发生时那块内存里一定有数据。数据被写
进去了，复位之后没了。

地址冲突可以排除。`/proc/iomem`：

```
9e300000-bbafffff : System RAM
  a0080000-a1baffff : Kernel code
  b0000000-b00fffff : reserved        ← ramoops，和内核代码不重叠
```

而且 `ramoops@b0000000` 是所有预留区里唯一标 `map` 的（其余全 `nomap`），
这正是 ramoops 需要的。

原因是高通平台的老问题：

- `CONFIG_POWER_RESET_MSM=y`，内核经 **PSHOLD 硬复位**重启。
- 这个内核树里**没有任何** `restart_reason` / `warm_reset` /
  `qcom,msm-imem` 代码（`drivers/power/reset/`、`drivers/firmware/qcom/`
  都没有）。Android 的下游内核会在 IMEM 里写重启原因，告诉 XBL 这是暖
  复位、跳过 DDR training。
- 没有那个标志，XBL 每次都重做 DDR training，预留区内容必然归零 ——
  这也解释了为什么同一个地址在原厂 Android 上能用、在这里不能。

**裁决：ramoops 在这个移植上不能作为跨复位的崩溃日志通道。** 节点和配置
保留（代价是 1 MB，且已验证不会引起任何问题，万一将来 bootloader 或重启
路径变了它就能用），但不要再把它当作开机失败的记录手段。要让它工作得往
内核里加下游的 IMEM 代码，不值得。

### ACM 控制台一直是「已注册但未启用」

此前文档和操作一直假定 `/dev/ttyACM0` 是内核控制台。**不是。**
`/proc/consoles` 只有两项：

```
tty0                 -WU (EC  p  )    4:1
ramoops-1            -W- (E   p a)
```

端到端测过：主机侧开着 `cat /dev/ttyACM0`，从手机往 kmsg 写 `<3>`
（KERN_ERR，能过 loglevel=4）的消息，手机 dmesg 里有，**主机侧一个字节
都没收到**。

机制是这样的：

- `f_acm.c:891` 用的是 `gserial_alloc_line()`，它在 port_num 为 0 时会
  自动调 `gs_console_init()`；`acm.usb0` 的 `port_num` 实测是 0。所以
  控制台**确实注册了**。
- 但 `gs_console_init()` 里 `cons->console.flags = CON_PRINTBUFFER;` ——
  **没有 `CON_ENABLED`**。register_console 只会在 cmdline 点名了这个
  控制台时才启用它，而我们的 cmdline 只有 `console=tty0`。
- 佐证：把 configfs 的 `console` 属性写 0，dmesg 立刻出现
  `printk: legacy console [ttyGS0] disabled`，而整个启动日志里
  **从来没有过对应的 "enabled" 行**。注册过，从未启用。
  （紧随其后还有一行 `dwc3: request ... was not queued to ep1in`。）

**修法是一行 cmdline**，不需要重新编译（cmdline 是打包阶段写进 boot
image 的）：`console=ttyGS0 console=tty0`。放在 tty0 之前，这样
`/dev/console` 仍然是面板。

这一行把主机侧变成真正的日志通道，而且比 ramoops 更好：`CON_PRINTBUFFER`
会在控制台被启用的瞬间把**整个 kmsg 环形缓冲区重放**出去，所以尽管
gadget 要到约 1 秒才存在，主机拿到的是从时间戳 0 开始的完整启动日志 ——
正是 ramoops 本该提供而无法提供的能力。配套的主机侧录制脚本是
`scripts/log-alioth-console.sh`（跨拔插自动重连）。

### 顺带两条

`loglevel=4` 的影响比看起来大：它把 KERN_ERR 以下全挡在**所有**控制台
之外，包括屏幕和 ramoops 控制台。USB 枚举和驱动 probe 都是 KERN_INFO，
所以 host 模式插键盘时屏幕上一个字都没有，直到手工抬高
`/proc/sys/kernel/printk`。`cmdline.sh` 的 `CMDLINE_QUIET=0` 分支已改为
`loglevel=7`。

sysrq 的掩码我一度读错，纠正记下来：`CONFIG_MAGIC_SYSRQ_DEFAULT_ENABLE=0x1`
**不是**「只允许调日志级别」。`sysrq_on_mask()` 是
`sysrq_always_enabled || sysrq_enabled == 1 || (sysrq_enabled & mask)` ——
值 1 被特殊对待为「全部功能」，位掩码语义只在大于 1 时生效。所以 sysrq
出厂就是全开的，`sysrq_always_enabled` 不必加（已从 cmdline 去掉）。

这件事有实际用处：USB-C 口切到 host 角色再切回来之后，调试 shell 和
网络监听会一起死掉（ACM 重新枚举了、NCM 还能回 ping，但 23 端口回 RST、
两个 ACM 端口都不应答），此时内核活着却无路可入。因为 `CONFIG_VT=y`、
`VT_CONSOLE=y`，而 USB-C 键盘现在能在 host 模式下枚举，**屏幕上
Alt+SysRq+B 就是一条保留 DRAM 的温重启退路**。串口那一侧没有这条路 ——
`u_serial.c` 里完全没有 sysrq 处理。

## USB-C host 模式：真机通过（2026-10-23）

拔掉 PC 线、插入 USB-C 键盘，屏幕上出现 xhci 枚举，键盘正常可用。
`CONFIG_TYPEC_MUX_FSA4480=y` 之后的状态：

```
/sys/class/typec/            port0  port0-partner      ← 伙伴识别完成
/sys/kernel/debug/devices_deferred   只剩 1c00000.pcie  ← typec@1500 与 rtc@6000 都不再 deferred
```

`port0-partner` 的出现意味着 TCPM 完成了和对端的协商，不只是 port 建起来
了。手柄侧不需要额外工作：`xpad` / `hid-playstation` / `hid-nintendo` /
`hid-sony` / `hid-microsoft` / `hid-generic` 全部是 `=y`，键盘能枚举走的
就是同一条 VBUS 供电 + xHCI 的路。

RTC 同时被解锁（`CONFIG_NVMEM_SPMI_SDAM=y`）：`/dev/rtc0` 注册成功，
`rtc@6000` 不再等 nvmem supplier。但读出来的时间偏快约 64 年
（`setting system clock to 2091-01-25T03:25:00 UTC`）—— SDAM 里那个
offset 的含义和驱动的约定对不上。阶段 2 由 NTP 解决，阶段 1 不影响任何
验收项，所以不去写 RTC：写它可能动到 PMIC 的 SDAM 持久存储，而这台机器
还要用 Android 做诊断。

触摸在去掉 `ft8756.poll=50` 之后依然正常：IRQ 152 从 0 涨到 5146，
`input2` 是 `Focaltech FT8756 Touchscreen`。5146 次中断里有 **1 次**
`Failed to read data status: 0xC1`（0.02%），驱动丢掉那一帧继续，
5000 帧丢 1 帧感觉不出来，记录备查。

## 第五版镜像：ACM 控制台通了，网络 shell 一直是死的（2026-10-23）

这一版只改了 cmdline 与 initramfs，内核二进制未动。三个结论。

### `console=ttyGS0` 成立，推断得到证实

刷完之后 `/proc/consoles`：

```
tty0                 -WU (EC  p  )    4:1
ttyGS0               -W- (E   p  )  235:0
ramoops-1            -W- (E   p a)
```

`ttyGS0` 带 `E`（`CON_ENABLED`）—— 上一版这一行根本不存在。主机侧
`cat /dev/ttyACM0` 第一次拿到了内容，而且**第一行就是 `[ 0.000000]`**：
`CON_PRINTBUFFER` 在控制台启用那一刻重放了整个环形缓冲区，所以尽管
gadget 要到约 1.4 秒才存在，拿到的仍是从时间戳 0 开始的日志。开机即
panic 的情况因此也在覆盖范围内。

`panic=120` 同时得到确认：`/proc/sys/kernel/panic` 读回 `120`。

一个限制：重放是一瞬间灌进 gadget serial 的环形缓冲区的，缓冲区不够大，
日志里出现 `[missed 53859 bytes]`。开头约 5 KB 与 3.7 秒以后的部分完整，
中间丢了一段。要减少丢失就得在 gadget 枚举之前主机侧已经打开并在读这个
端口 —— 这正是 `scripts/log-alioth-console.sh` 做的事（先起 logger 再刷
机）。`u_serial.c` 的队列大小是编译期常量，没有旋钮可调。正常运行时的完
整日志从 `dmesg` 取即可；这条通道的价值在**根本到不了 userspace 的那种
启动**。

### 网络 shell 从来就没工作过：这个 busybox 没有 telnetd

上一版加的 telnetd 看门狗循环忠实地每 5 秒重试一次，每次都打
`telnetd could not bind 172.16.42.1`。手工执行给出了真正的原因：

```
# busybox telnetd -F -b 172.16.42.1 -l /bin/sh
telnetd: applet not found
```

ROCKNIX 的 busybox 1.37.0 **没有编进 telnetd applet**。`busybox --list`
里没有 telnetd、没有 httpd、也没有 dropbear。所以这个项目构建过的每一版
镜像在 23 端口上都是死的 —— 之前那次「补回主机地址后 telnet 得到
Connection refused」现在有了完整解释，它不是竞态，而是从未有人在听。
看门狗循环的前提是错的：它在重试一件不可能成功的事。

`nc` 在这个 busybox 里，而且带 `-e/-l/-k` 扩展，提供的东西和 telnetd
要提供的一样 —— 一个 TCP 端口上的 root shell。改成：

```sh
nc -lk -p 23 -s 172.16.42.1 -e /bin/sh
```

未刷机就验证过：把 `init` 里改好的循环体原文抄到真机上跑，`/proc/net/tcp`
出现 `012A10AC:0017`（172.16.42.1:23），主机侧 `ncat` 连上拿到 root
shell，断开后再连一次仍然通（`-lk` 跨客户端存活，两次顺序连接实测），
kmsg 出现且只出现一次 `usbshell: root shell listening on 172.16.42.1:23`
—— 新循环只在状态变化时打印，不再像上一版那样每 5 秒刷一行把控制台日志
埋掉。老的 telnetd 循环在那一刻同时安静了，这反过来证明了基于
`/proc/net/tcp` 的守卫对两个循环都有效。

主机侧客户端用 `ncat`（本机没有 `nc`），**不要用 `telnet`**：它的 IAC 协商
字节会直接进入 shell 的 stdin 变成垃圾输入。没有 pty，所以没有行编辑、没有
作业控制；交互请用 `/dev/ttyACM1`，那是真 tty。

### NetworkManager 会反复抹掉 PC 侧的地址

这件事今天制造了三次误诊，必须记下来：gadget 的 NCM 链路上没有 DHCP
服务器，NetworkManager 因此无事可做，把接口标成 `disconnected`，并且
**反复**删掉手工加上的 `172.16.42.2/24` —— 不是一次，是每隔几分钟一次，
没有外部触发。每次发生时，这条链路看起来和「手机挂了」完全一样：ping
100% 丢包、连接全部 timeout。今天有一次因此误判成「nc 没在监听」，其实
监听一直在。

两个修法，都已入仓：

- `scripts/alioth-shell.sh` —— 按驱动（`cdc_ncm`）找接口（名字跟 USB 口
  走，`enp0s20f0u3u4i4` 这种会随换口变化），地址没了就补回去，然后连
  shell。支持 `-c '命令'` 单条执行。
- `scripts/setup-host-usbnet.sh` —— 一次性写
  `/etc/NetworkManager/conf.d/99-alioth-usbnet.conf`，让 NM 彻底不管这条
  链路。匹配用 **MAC** 而不是驱动：按驱动匹配会连带影响别的手机的 USB
  共享网络。为此 `init` 现在把 gadget 两端的 MAC 钉死
  （`ncm.usb0/dev_addr` = `02:16:42:00:00:01`、`host_addr` =
  `02:16:42:00:00:02`），否则每次开机都是随机的本地管理地址，PC 侧除了
  会变的接口名之外没有任何稳定标识可用。

### 顺带澄清的两条启动期报错

两条每次开机都出现、但无害的消息，记下来免得以后再查一遍。

`Initramfs unpacking failed: invalid magic at start of compressed archive`
（0.708 s）—— 指的**不是**内嵌的 initramfs。内嵌那个由
`populate_rootfs()` 先解包，失败会直接 panic；这一行来自之后对
bootloader 传入的 initrd 的解包尝试，而 `mkbootimg-v0.py` 在没有
`--ramdisk` 时按 ROCKNIX 的做法写了 5 个字节的 `b"dummy"` 当 ramdisk（有
些 bootloader 不接受零长度 ramdisk）。内核照章尝试解包这 5 个字节，当然
没有 magic。`usb_shell` 能跑本身就证明内嵌 initramfs 是好的。

`DSI PLL(0) lock failed, status=0x00000000` + 两条 `clk.c` WARNING
（1.04 s，内核因此 `Tainted: [W]=WARN`）—— 栈回溯落在
`dsi_phy_driver_probe+0x2fc`，是 PHY probe 阶段的一次标定尝试失败。之后
1.69 s `msm_dpu bound ae94000.dsi`、2.10 s `fb0: msmdrmfb frame buffer
device`，显示链路照常工作，面板上有日志。属于已知噪声，不处理。

## 调试 shell 为什么活不过 USB-C 角色切换（2026-10-23）

上一次做 host 模式测试时，ACM 两个端口在插回 PC 线之后都不应答，当时结论
是「原因不明」。这次带着能工作的网络通道重做了一遍，拿到了确定答案。

实测结果分三部分：

- **网络 root shell 活着。** 插回 PC 线后 `alioth-shell.sh` 直接连上，
  kmsg 里**没有**第二行 `root shell listening`，`nc` 还是同一个 PID。
  也就是说上次那个「23 端口回 RST」根本不是监听死了，而是 telnetd 从来
  不存在 —— 看门狗要覆盖的故障，之前被错误归因了。
- **内核控制台活着。** `/dev/ttyACM0` 重新打开就有内容（`CON_PRINTBUFFER`
  又重放了一遍）。
- **`/dev/ttyACM1` 的交互 shell 死了。** 而且是彻底死了：没有任何进程持有
  `/dev/ttyGS1`，respawn 循环本身也从进程表里消失了。

kmsg 给出了最后一块拼图 —— 只有一行 `opening /dev/ttyGS1 for the shell`，
**没有**对应的 `ttyGS1 shell exited`。循环不是走完一轮又卡住，而是被信号
杀掉的。上一版加的那两行自述正是为这一刻准备的。

### 机制：那个负责重启 shell 的进程必然和 shell 一起死

`setsid` 让这个循环成为一个**没有控制终端的会话首进程**。接下来循环体里
那句朴素的重定向

```sh
/bin/sh </dev/ttyGS1 >/dev/ttyGS1 2>&1
```

由会话首进程自己执行 —— 于是 `open()` 把 ttyGS1 变成了**这个会话的控制
终端**。gadget 消失时 tty 挂断，SIGHUP 发给会话首进程，也就是循环自己。
所以「负责把 shell 拉回来的那个进程」被设计成了每次都和 shell 同时死亡，
看门狗写得再对也没用。

### 修法与验证

两处改动，任何一处单独都够：内层 shell 在**自己的会话里**打开 tty
（`setsid` 先执行、重定向后执行，控制终端因此归内层会话，挂断被限制在那
里），以及循环自身 `trap "" HUP`。

不刷机就验证完了，三步，都在真机上：

1. 把改好的循环体抄到手机上跑起来 —— 已经死掉的 `/dev/ttyACM1` **当场
   复活**，这同时证明了「循环死亡」就是故障的全部原因。
2. 给循环的会话首进程发 SIGHUP —— 循环还在，kmsg 出现新的 `opening`。
3. 给内层 shell 发 SIGHUP —— kmsg 出现
   `ttyGS1 shell exited (129)`（129 = 128+SIGHUP），1 秒后 `opening`。

顺带给 nc 那个循环也加了 `trap "" HUP`：它今天没有这个暴露（它不碰 tty），
但代价是零，而这一类故障的代价是「内核活着却无路可入」。

## WiFi 与蓝牙：两个都能工作，阻塞点是一行配置（2026-10-23）

验收清单里唯一的 FAIL 解决了，而且没有刷机 —— 根因、修法、以及「修完确实
能用」三件事都在运行中的机器上做完了。

### 根因：`CONFIG_PCI_PWRCTRL_PWRSEQ=m`

症状看起来像 PCIe 硬件坏了：`/sys/bus/pci/devices/` 是空的，
`devices_deferred` 里是

```
1c00000.pcie	qcom-pcie: cannot initialize host
```

而 `qcom-pcie` 反复 probe 四次（2.52 s、2.54 s、2.64 s、12.77 s）都只打印
到地址范围就停住。

真因是今天第三次遇到的同一类故障。QCA6390 挂在 PCIe 后面，alioth 的 DTS
把它描述成 `pcieport0` 下的 `wifi@0`，九条供电全部来自 `qca6390-pmu` 这个
power sequencer。**PCI 核心会把这样一个 DT 子节点变成一个 pwrctrl 设备，
并且把整个 host bridge 挂起，直到有驱动认领它** —— 因为芯片必须先上电，
总线才能被扫描。驱动是模块，阶段 1 没有 rootfs 可以 modprobe，于是 host
bridge 永久 deferred。

DTS 本身一点问题都没有：`qca6390-pmu` 九个 LDO、`pcie0`/`pcie0_phy`、
`wifi@0` 全套 supply、`uart6` 下的 `qcom,qca6390-bt` 全都齐备，
`qca6390-pmu` 也确实绑上了 `pwrseq-qcom_wcn`。

### 验证：一条 insmod

把同一次构建的那个 9.7 KB 模块 wget 到手机上 `insmod`：

```
pci 0000:01:00.0: BAR 0 [mem 0x60300000-0x603fffff 64bit]: assigned
pcieport 0000:00:00.0: AER: enabled with IRQ 200
```

`/sys/bus/pci/devices/` 当场出现 `0000:00:00.0` 与 `0000:01:00.0`
（`17cb:1101`），`devices_deferred` 清空。

### WiFi：固件齐了就工作

`ath11k_pci` 第一次加载时只差固件（`ath11k/QCA6390/hw2.0/amss.bin`
ENOENT → MHI 上电 -110）。阶段 1 没有 rootfs，但不需要 —— `firmware_class`
的 `path` 参数可以指到 tmpfs：

```sh
echo /dbg/fw > /sys/module/firmware_class/parameters/path
```

把 linux-firmware 的 `amss.bin`、`m3.bin`、`board-2.bin`（共 4.2 MB，解压
后）放进去再加载：

```
ath11k_pci 0000:01:00.0: qca6390 hw2.0
mhi mhi0: Power on setup success
ath11k_pci 0000:01:00.0: chip_id 0x0 chip_family 0xb board_id 0xff
ath11k_pci 0000:01:00.0: fw_version 0x10121492 fw_build_timestamp 2021-11-04 11:23
```

`wlan0` 创建，驱动绑定。

### 蓝牙：走 UART，与 PCIe 无关

QCA6390 的蓝牙不在 PCIe 上，而是 `&uart6` 上的 serdev 设备。装上
`bluetooth.ko` + `btqca.ko` + `hci_uart.ko`（`BT_HCIUART_QCA` 本来就是
`=y`，`SERIAL_DEV_BUS=y`）：

```
Bluetooth: hci0: QCA SOC Version  :0x400a0200
Bluetooth: hci0: QCA Downloading qca/htbtfw20.tlv
Bluetooth: hci0: QCA Downloading qca/htnv20.bin
Bluetooth: hci0: QCA setup on UART is completed
```

`hci0` 建立，`/sys/bus/serial/devices/serial0-0` 绑定 `hci_uart_qca`。

### MAC 地址是生成的，但是稳定的 —— 这关系到手柄配对

两边的地址都不是从 OTP/NV 读出来的真实地址，而是驱动生成的
（`00:03:7f:xx:xx:xx`，Atheros OUI）。原厂 Android 从 modem 的 NV 分区取真
地址，mainline 这条路没有。

重要的是它**确定性**而非随机：末三字节是 ASCII 数字，而且模块重载前后完全
一致（实测两次 `MAC_ADDR set to` 相同）。所以蓝牙的 BD_ADDR 不会每次开机
变一次 —— 手柄配一次就够，不需要反复重配。跨重启的稳定性尚未实测，但派生
方式决定了它应当稳定；阶段 2 第一次配手柄时顺手确认。

### 结论：内核**不改**，这是阶段 1 独有的缺口

最初的结论是「改成 `CONFIG_PCI_PWRCTRL_PWRSEQ=y`，和 FSA4480、SDAM 一样」。
构建脚本自己的断言否掉了它：

```
WARN CONFIG_PCI_PWRCTRL_PWRSEQ=y not applied (got: CONFIG_PCI_PWRCTRL_PWRSEQ=m)
```

`PCI_PWRCTRL_PWRSEQ` 是个**无提示的隐藏 tristate**
（`drivers/pci/pwrctrl/Kconfig`），值来自 ath11k 的
`select PCI_PWRCTRL_PWRSEQ if HAVE_PWRCTRL`，因此跟着 `ATH11K_PCI` 走。
唯一能把它变成 `y` 的办法是 `ATH11K_PCI=y` —— 而那会**破坏阶段 2**，不是
帮它：ath11k 在 probe 时请求 `amss.bin`，固件在 rootfs 里，而内建驱动
probe 的时候 rootfs 还没挂上。

所以保持 `=m`，理由不是「将就」而是这个缺口在阶段 2 会**按构造消失**，并且
这一点是实测的而非推演：往运行中的内核 insmod 这个模块，**deferred 的
`1c00000.pcie` 立刻被重试**、总线当场起来。也就是说加载顺序无关紧要 ——
阶段 2 里 udev 什么时候加载它，PCIe 就什么时候跟上。

阶段 2 要盯的一件事：**确实有人加载这个模块**。没有别的东西依赖它，所以
如果到时候总线上找不到 QCA6390，先查这里。

固件（`ath11k/QCA6390/hw2.0/*`、`qca/htbtfw20.tlv`、`qca/htnv20.bin`）由
阶段 2 的 rootfs 提供，`FW_BUILTIN=0` 不变。

**这一节没有产生任何需要刷机的改动。**

## 阶段 1 验收：通过（2026-10-23）

### spec §9 风险登记里属于阶段 1 的 7 项未知，逐条结论

| 未知 | 结论 |
|---|---|
| 7.2.8 的 `drm_panel` / input API 具体形状 | **已关闭**。面板（AMS667XX01）与触摸（FT8756）都在真机上工作，前向移植的 API 适配是对的 |
| ROCKNIX sm8250 平台代码与 alioth DTS 冲突 | **已关闭**。没有冲突；内核启动到调试 shell，外设逐项可用 |
| 小米 ABL 接受 boot header v0 还是必须 v3 | **v0 可用**。六次刷机全部用 `mkbootimg-v0.py` 产出的 header v0 + `append_dtb`，从未退到 v3 |
| 是否需要禁用 vbmeta 验证 | **不需要**。`scripts/mk-vbmeta-disabled.py` 一次都没用上；设备以 `verifiedbootstate=orange` 正常启动，vbmeta 分区从未写过 |
| 是否必须 `fastboot erase dtbo` | **必须**。已固化进 `flash-alioth.sh`，与 REDMAGIC 6 相同（ABL 会用 libufdt 把厂商 dtbo 覆盖到 mainline DTB 上） |
| 4K 页（FEX 硬性前提） | **成立**。`CONFIG_ARM64_4K_PAGES=y`，真机佐证：HugeTLB 注册 2 MiB / 32 MiB / 1 GiB，`Hugepagesize: 2048 kB` —— 正是 4K granule 的特征组合 |
| PREEMPT / MGLRU | **成立**。`CONFIG_PREEMPT=y`、`CONFIG_LRU_GEN=y`、`CONFIG_LRU_GEN_ENABLED=y` |

### 外设工作状态

| 外设 | 状态 | 备注 |
|---|---|---|
| 面板 AMS667XX01 | ✅ | `fb0: msmdrmfb`；DSI PHY probe 期一次 PLL 标定失败无害 |
| 触摸 FT8756 | ✅ | 纯中断，5146 次里丢 1 帧；`ft8756.poll=` 已去掉 |
| UFS | ✅ | `WDC SDINFDK4-128G`，`/dev/sda` 全部分区 |
| 充电 PM8150B | ✅ | `Charging`，浮充上限由驱动 clamp 到 4 450 000 µV |
| USB-C host 模式 | ✅ | 键盘枚举可用；`port0` + `port0-partner`；两次独立观察 |
| USB gadget 调试通道 | ✅ | ACM 控制台 + ACM shell + 网络 root shell，三条都活过 host 角色往返 |
| WiFi QCA6390 | ✅ | `wlan0`，需 `pci-pwrctrl-pwrseq` 模块 + rootfs 固件（阶段 2 自然满足） |
| 蓝牙 QCA6390 | ✅ | `hci0`，走 `&uart6` serdev；BD_ADDR 生成但确定性，手柄配对可持久 |
| RTC | ⚠️ | `/dev/rtc0` 可用但时间偏快约 64 年（SDAM offset 约定不符）。刻意不写 RTC，阶段 2 由 NTP 解决 |
| GPU A650 | ⚠️ | DPU/DSI 完整，GPU 微码缺失（`FW_BUILTIN=0` + 无 rootfs）。阶段 2 随 rootfs 到位 |
| ramoops | ❌ | 裁决不可用（PSHOLD 硬复位 + 无 IMEM restart_reason）。由 ACM 内核控制台取代 |
| 音频 / 相机 / NFC / PCIe 以太 | — | 范围外或阶段 2 |

### 阶段 2 的授权变更（2026-10-23）

用户确认不再需要 Android，随之解除两条阶段 1 的硬约束：

- **`userdata`（106 GiB，sda35）现在可写** —— SteamOS rootfs 落在这里，
  这正是 cmdline 里 `steamos.root=PARTLABEL=userdata` 一直指向的分区。不可逆。
- **SteamOS 启动成功后标记 A/B successful** —— 阶段 1 禁止标记是为了区分测过与
  未测过的槽；rootfs 住进 userdata 之后，这条理由被一个更大的风险盖过：启动尝试
  用尽时 bootloader 落到 slot b 的原厂 Android，而 Android 看到陌生的 ext4 很可能
  格式化它，连 rootfs 一起没掉。标记 successful 正是 A/B 机制的设计用途。

仍然禁止：**`super`**（8.5 GiB，刻意保留 —— 留着不花钱，且意味着以后格一下
userdata 就能复活 Android）与 **`abl_a`/`abl_b`**（bootloader，砖了只能走 EDL）。
退路从「自动回退到 Android」改为**手动进 fastboot**（音量下 + 电源）—— 那条路在
ABL 里，与槽内容无关，本阶段已反复走通。

## Valve Frame rootfs 里到底有什么（2026-10-23 实测）

阶段 2 的前提是「原样用 Valve 的 rootfs」（spec §4）。那就得先知道它**不**给
我们什么。镜像是 `deckard-20261002.6232440-0.5.3`，解包后 9.1 GiB。

`scripts/assert-alioth-rootfs.sh <rootfs>` 把下面这些钉成断言。

### 自带，可以直接用

| 东西 | 位置 | 备注 |
|---|---|---|
| aarch64 用户空间 | `usr/bin/bash` | — |
| gamescope | `usr/bin/gamescope` | 不需要我们自己编（这一条决定了不调 `apply-overlays.sh`） |
| Turnip | `usr/lib/libvulkan_freedreno.so` | A650 的 Vulkan 驱动 |
| **FEX 的 x86 客户机根** | `usr/share/guestos/fex-mesa` | **967 MiB，x86-64 + i386 都有**，带 Mesa 的 libGL/libGLESv2/libGLX |
| `/etc` overlayfs 机制 | `usr/lib/systemd/system/etc.mount` | `lowerdir=/etc,upperdir=/var/lib/overlays/etc/upper,workdir=…/work` |
| steamos-powerbuttond | `usr/lib/hwsupport/steamos-powerbuttond` | sm8250-overlay 的 unit 的 ExecStart 指向它 |
| Steam bootstrap | `usr/lib/steam/steam.tar.zst` | 首次开机联网自举用 |

**spec §7.3 的开放问题就此关闭：不需要单独准备 FEX 的 x86 rootfs。** Valve
自己带了一整棵，32 位和 64 位都齐。

### 不自带 —— 这几条是坑

| 以为有，其实没有 | 真相 |
|---|---|
| `FEXInterpreter` / `FEXLoader` | 只有 `usr/bin/FEXBash`，一个引用 `/home/steamos/.steam/…` 的 shell 包装。FEXInterpreter 随 **Steam ARM 客户端**一起来，不是镜像的一部分 |
| **InputPlumber 守护进程** | 镜像里只有 Steam 自己的 udev 规则 `90-steam-inputplumber.rules`，**没有 `usr/bin/inputplumber`**。而 spec §7.1 的整套输入设计都压在它上面。由 `make-steamos-alioth.sh --install` 装官方预编译的 aarch64 release |
| Proton 11 | 不在镜像里，由 Steam 下载或种子预置 |
| `/var/lib/overlays/etc/{upper,work}` | **两个目录都不存在。** overlayfs 要求 `upperdir` 和 `workdir` 都已存在，systemd 的 mount unit 不会替你建 —— 少了 `etc.mount` 就失败。镜像构建时建 |

最后一条最阴：只建 `upper` 不建 `work` 时，`etc.mount` 失败、`/etc` 退回下层，
而我们的配置在下层**也有一份**（`apply-alioth-overlay.sh` 两层都写），于是表现
为「配置是生效的，但 `etc.mount` 报错」，比干脆不生效更难查。

### InputPlumber 还需要 libiio

预编译的 `inputplumber` 二进制 `NEEDED: libiio.so.0`，而镜像里没有。
`install-inputplumber-sm8550.sh` 会为 aarch64 现编一份，所以 x86_64 宿主上要有
交叉编译器（`pacman -S aarch64-linux-gnu-gcc`）。少了它 InputPlumber 装上也起
不来，症状是「手柄在 Steam 里还是 Xbox 图标」。

## 阶段 2 真机：从黑屏到能登录 Steam（2026-10-23 / 24）

设备用 `fastboot boot`（零写入）起新镜像，rootfs 在 userdata（sda35，
`df` 105 GiB）。下面每一条都是真机实测，不是推断。

### 黑屏是四个缺陷叠在一起，缺一不可

一条都单独不足以解释，修完前三条还是黑屏。

1. **GPU 时钟上限 925 MHz。** sm8250.dtsi 给了 15 档到 925 MHz，而
   `a6xx_gmu_init` 把 `current_perf_index` 设成 `nr_gpu_freqs - 1` ——
   GMU 开机就投最高那一档。结果 `GX_BW_PERF_VOTE id 7` 超时、`OOB GPU_SET`
   超时、`gpu hw init failed: -110`，接着 Turnip `could not get GPU ID`、
   gamescope `failed to find physical device`、sddm `Relogin=true` 死循环。
   删掉 650–925 MHz 那九档（提交 d8226b2）。

2. **TrustZone 拒收通用签名的 PAS 镜像。** `a650_zap.mbn` 和 `adsp.mbn` 都
   报 `error -22 initializing firmware`（`qcom_scm_pas_init_image` 返
   -EINVAL = Invalid firmware metadata）。必须用机内签名那两份：adsp 从
   `modem_a`（sde5，vfat）的 `image/adsp.mdt` + `.b00..b18` squash，
   a650_zap 从 super 里 `vendor_a` 的 `firmware/a650_zap.mdt` + `.b00..b02`。
   两份和 linux-firmware 的同名文件**连大小都一样**（zap 两边都是 13964
   字节），只有签名不同 —— 看文件名、看大小、看在不在，都发现不了。
   见 `scripts/extract-alioth-firmware.sh`。固件是小米签的，不可再分发。

3. **`/home` 幻影挂载。** Frame 的 `home.mount` 指向
   `/dev/disk/by-partsets/shared/home`，alioth 没这个设备 → 90 秒超时 →
   `Dependency failed for /home` → **每个** `session-N.scope` 都以
   'dependency' 失败 → 没有 seat、没有 DRM master。
   并入 `scripts/apply-alioth-devr.sh` 的 mask 列表。

4. **drop-in 从没被已经在跑的 user manager 读到。** `TimeoutStartSec` 还是
   Frame 原版的 **5 秒**，而 gamescope 起两个 Xwayland 要十几秒 —— 每一轮
   必定超时被杀，steam 连带 SIGTERM。`systemctl --user daemon-reload` 之后
   变 45 秒，重启 sddm 一轮就稳住：gamescope-wl 存活 91 秒、8 个
   steamwebhelper、mangoapp 建出 swapchain、模式 2400x1080@120、plane 满屏
   1080x2400、背光 1535/2047。

### 其余已修的真机问题

| 症状 | 真因 | 修法 |
| --- | --- | --- |
| 触摸相对画面逆时针 90° | `--force-composition-rotation` 只决定旋转在哪做、不设角度，gamescope 不知道面板朝向，于是不变换触摸坐标 | udev `LIBINPUT_CALIBRATION_MATRIX="0 1 0 -1 0 1"`（(nx,ny)→(ny,1−nx)） |
| 电源键完全没反应，守护进程静默退出 0 | `steamos-powerbuttond` 只认带 `STEAMOS_POWER_BUTTON` 属性的 event 设备（`strings` 里就这三个筛选串），通用规则和 sm8250 规则都不给 PMIC pwrkey 设它 | udev 规则按 `ATTRS{name}=="pm8941_pwrkey"` 设该属性 |
| wireplumber SIGSEGV 崩溃循环 | `70-spatial-node-config.conf` 把 Frame 的 VR 空间音频 lua 标成 `required`，而 `/usr/lib/ladspa/vraudiocompositor.so` 不存在 | `75-alioth-no-spatial.conf` 禁掉 |
| 机器发热、风扇全速（实际是 CPU 空转） | 我自己留下的一条交互式 `spa-acp-tool -c 0` 在 99.9% CPU 空转，而且它挂在 ttyGS0 上把串口输入全吞了 | 杀掉；最高温回到 47 °C。**教训：这类 REPL 必须 `</dev/null` 且把命令作为参数传** |
| `adbd-post.service` 永远 activating | 它以 10 Hz 轮询 `ffs.adb/ready`，8381 秒没停过 —— 上游注释说的「SoC 出不了深度 idle」。我们的串口和 usb0 其实来自 initramfs 的 usbshell，不需要它 | mask `adbd` + `adbd-post` |
| 系统时间读出 2091-01-25 | PMIC RTC 首次开机是垃圾值，systemd 判「比内置 epoch 超前 15 年以上」就把时间拍回编译期 epoch 2026-02-23 —— 比 rootfs 构建日期早八个月，PAM 立刻报 "password changed in future"，证书全部「尚未生效」 | `usr/lib/clock-epoch`（systemd 优先用它的 mtime 当 epoch） |
| `System clock synchronized: no`，时间差一整天 | 镜像的 `timesyncd.conf` 里 `[Time]` 全是注释，只能回落到编译期的 arch 池，而那些域名在测试网络上一个都解析不出来 | `50-alioth-ntp.conf`，`NTP=` 列四个跨区域可解析的服务器 |
| `alioth-firstboot` 永久 failed，哨兵不清 | 镜像里**没有** `qbootctl` | 自带 `alioth-mark-slot-successful`，见下 |

### 音频：这个 machine driver 不支持 TDM

UCM、控件名、路由全都核实无误（`TERT_TDM_RX_0 Audio Mixer MultiMedia1`
存在；`RCV/LCV Digital PCM Volume` 的 `dBminmax` 是 −102.00..12.00 dB，
`values=721` 与「721 = −12 dB」推导一致；`alsaucm set _verb HiFi
set _enadev Speaker` 干净通过、路由读回 `on`），但 `spa-acp-tool` 报
`profiles:2 ports:0`，PipeWire 只有 Dummy Output。

pipewire 日志给出真因 `spa.alsa: 'hw:0,0': playback open failed: Invalid
argument`，而 dmesg 是：

```
qcom-q6afe: cmd = 0x100ef returned error = 0x2
qcom-q6afe: DSP returned error[2]
qcom-q6afe: AFE enable for port 0x9020 failed -22
q6afe-dai: ASoC error (-22): at snd_soc_dai_prepare() on TERTIARY_TDM_RX_0
```

`qcom,sm8250-sndcard`（`sound/soc/qcom/sm8250.c`）的 `sm8250_snd_startup`
只认四个 MI2S_RX 端口，**从不调 `snd_soc_dai_set_tdm_slot()`** —— 整个
`sound/soc/qcom` 里只有 `sdm845.c` 调它。TDM 后端带着 0 槽、0 位槽宽交给
ADSP，ADSP 拒收，`snd_pcm_open` 返 EINVAL，ACP 一个 profile 都探不出来。
旁证：整棵 `arch/arm64/boot/dts/qcom/` 里只有我们这一份 DTS 引用过 TDM 端口。

改走 `TERTIARY_MI2S_RX`（引脚一个都没动，`mi2s2_*` 本来就是 tertiary 的
MI2S/TDM 共用）。**真机还没验**，要刷 boot。

另附一条待处理：`aplay --dump-hw-params hw:0,0` 给出
`PERIOD_SIZE: [480 3360]`，而 Frame 的 `50-alsa-config.conf` 要求
`api.alsa.period-size = 256` —— 低于最小值。等 MI2S 起来之后再看 ACP 会不会
自愈。

### A/B 槽状态在 GPT 里，不在 misc 里

`misc` 偏移 2048 处（Android `bootloader_control` 的常规位置）实测全是 0。
真正的槽元数据在 GPT 表项 attributes 的高 16 位 —— Qualcomm 的 ABL 就是这么
存的，`qbootctl` 改的也是这几位：

```
bit 48-49 priority   bit 50 active   bit 51-53 tries remaining
bit 54    successful bit 55 unbootable
```

实测（`/dev/sde`，不是 sda —— boot_a 是 sde12）：

```
abl_a    attr=0x107f…  prio=3 active=1 retry=7 success=1
boot_a   attr=0x0037…  prio=3 active=1 retry=6 success=0
boot_b   attr=0x003a…  prio=2 active=0 retry=7 success=0
```

`boot_a` 的 retry 已经从 7 掉到 6 —— ABL 真的在每次引导未标记的槽时减 1，
减到 0 就标 unbootable 并换槽。**两个槽刷同一个 boot.img 救不了这件事**，
只是把「十几次开机之后谁都引导不了」推后一倍。

所以补了 `alioth-overlay/usr/lib/steamos-arm/alioth-mark-slot-successful`。
它写的是分区表，而这块 LUN 上同时住着 `abl_a` —— 写坏了 XBL 找不到 ABL，
只能走 EDL 9008。缓解见脚本头注释；关键一条是**下笔前用自己的算法重算未修改
的四个 CRC，和表里存着的值比**（真机 `--dry-run` 实测四个全部对得上），
以及每份 GPT 只做一次连续 pwrite。

### 其他真机事实

- **WiFi / 蓝牙**：`wlan0` 192.168.10.214/24，外网可达（ping 1.1.1.1 70 ms），
  DNS 与 HTTPS 都通。
- **Steam 自举成功**：镜像自带的 `steam.tar.zst` bootstrap 在 alioth 上**能
  用** —— 下了 663 MB 更新、装成 3.1 GB，`linuxarm64` 与 `androidarm64` 都在。
  上游 `install-complete-steam-client.sh` 注释说的「version 0、缺 package
  zip、转圈」是他们自己环境里的结论，不适用于这里。
- **Steam 能登录**（2026-10-24）。第一次报错、重试成功；失败那次服务端回的是
  `Try another CM` 然后断开，是 CM 轮询的运气问题。测试网络上所有 Steam 域名
  都解析到 `198.18.x.x`（Clash/mihomo 的 fake-IP 段），HTTPS 通但 CM 会话会被
  掐 —— 这是网络/代理的事，不是移植缺陷。
- **sshd 在镜像里是 `disabled`**。`--install` 的 opt-in 步骤除了装公钥还必须
  建 enable 链接，否则重启就没有通道。
- **`usb-ncm-dnsmasq@usb0.service` 是 Valve 自己 masked 的**
  （`/etc/systemd/system/usb-ncm-dnsmasq@usb0.service -> /dev/null`，
  Feb 24 2026），所以 `10.86.200.233` 在干净开机后**不会出现**。能用的地址是
  initramfs 在 `steamos.usbshell=1` 时无条件配的 `172.16.42.1`，它在
  switch_root 之后仍然在，而正式系统的 sshd 监听全部地址。
- **initramfs 的 nc root shell 活过了 switch_root**，所以 23 端口（无认证
  root）和 22 端口（steamos 的 sshd）在同一个地址上并存。要 root 用前者。
- **Steam 的黑边不是缺陷**：DRM plane 是满屏 1080x2400+0+0，是 Steam 自己按
  16:9 做信箱（2400−1920=480，两侧各 240 px）。
- **电源管理**：`schedutil`（policy0 1.07 GHz / policy4 2.42 GHz /
  policy7 2.07 GHz）、cpuidle `cpu-sleep-0-0` 进入 149754 次累计 648 秒、
  GPU devfreq `simple_ondemand`、`mem_sleep` 只有 `[s2idle]`（主线 sm8250 无
  deep）。
- **s2idle 挂起/恢复不卡死**（2026-10-24 实测，`rtcwake -m freeze -s 20`）：
  `PM: suspend entry (s2idle)` → `Restarting tasks: Done` → `PM: suspend exit`，
  rtcwake 退出 0，设备存活、uptime 连续。但它只睡了 **1.8 秒**而不是要求的
  20 秒 —— 插着 USB 时 gadget 和 ttyGS0 控制台本身就是唤醒源
  （`/sys/kernel/debug/wakeup_sources` 有 15 项）。真正的待机掉电表现要
  拔线之后才能测，那不在阶段 2 范围内。
- **电池**：充电中 96%、4362781 µV（在 4.45 V 上限之下），没有热区超过 45 °C。
- **`reboot bootloader` 在这台机器上没有**：pon 节点没有 `mode-*` 属性，
  整棵 sm8250 DTS 里也没有 `syscon-reboot-mode`/imem 节点。要进 fastboot
  只能按住音量下 + 电源。给 imem 加 `syscon-reboot-mode` 需要一个本地无法
  核实的 IMEM 偏移，所以没做。
- **构建机**：`build-alioth-kernel.sh` 可以后台跑，但要给它一个 pty
  （`setsid script -qefc …`）—— 之前「不能后台跑」的结论来自 `nohup`，
  真因是没有终端。全量重建 `-j20` 约 6 分钟。

## 以后不用再碰手机：设备自己写 boot 槽（2026-10-24）

换一版内核原本要人按住音量下 + 电源进 fastboot，而改内核是这个项目里重复
次数最多的循环。现在一轮是「送文件 + 重启」，PC 上一条命令：

```
./scripts/alioth-selfflash-boot.sh [--reboot]
```

三件东西组成：

| 在哪 | 做什么 |
| --- | --- |
| `alioth-overlay/usr/lib/steamos-arm/alioth-write-boot` | 设备侧，root。校验 `ANDROID!` 魔数与大小、按 PARTLABEL 认分区、`dd`、读回比 sha256 |
| `/etc/sudoers.d/zz-alioth-write-boot` | 只放开上面那一个命令和 `systemctl reboot`，而且只在 `ALIOTH_SSH_PUBKEY` 的 opt-in 块里装 |
| `scripts/alioth-selfflash-boot.sh` | PC 侧。先跑 `assert-alioth-boot-image.sh`，再送镜像、在设备上比 sha256，一致才让设备动笔 |

**为什么这条路不比 fastboot 危险。** 写 boot 分区写坏了不会砖 —— 退路和
原来完全一样，按住音量下 + 电源进 fastboot，再 `./flash-alioth.sh`。它换
掉的只是「谁来写」，不是安全边界。边界在 `alioth-write-boot` 里：它只认
PARTLABEL 是 `boot_a`/`boot_b` 的块设备，`super`、`userdata`、尤其是 `abl`
一个字节都不写。默认槽位问的是
`alioth-mark-slot-successful --print-active`，不在写入器里再抄一遍 GPT 解析。

断言在 `scripts/assert-alioth-writeboot.sh`（要 root），15 条。A 组对着一个
自造 GPT 的回环盘跑（两个 2 MiB 分区，`boot_a` 和 `bogus`，
`ALIOTH_BOOT_DEV_DIR` 指到测试自己的目录 —— 构建机上真的 `boot_a` 全程碰
不到），其中 7 条是「该拒绝的时候两个分区的 sha256 都没变」。

### 第一次真机自刷暴露的三件事

三件都是「脚本看着跑成功了、但什么都没发生」—— 而这一类恰好是自刷流程
最该不出的错，因为它的全部价值在于不用去碰手机确认。

1. **`alioth-ssh.sh` 把调用者的命令丢了。** 候选地址循环里用 `set -- $c`
   拆 "设备IP 宿主CIDR"，而那正好覆盖掉位置参数，于是结尾的
   `exec ssh ... "$@"` 把候选地址当成命令发了过去：
   `bash: line 1: 172.16.42.1: command not found`。ssh 连上了、退出码看着
   正常，而要跑的那条命令一个字都没跑。改用 `read`。

2. **sudoers 文件名必须排在 `wheel` 后面。** `@includedir` 按文件名排序
   读，而 sudoers 里**后面的规则覆盖前面的**。镜像自带
   `/etc/sudoers.d/wheel` 写着 `%wheel ALL=(ALL) ALL`，而 steamos 在 wheel
   组里（实测 `groups=…,998(wheel),…`）。叫 `50-alioth-write-boot` 时它排
   在 wheel 前面，带密码的那条最后生效，`sudo -n` 照样要密码 —— 症状
   （`sudo: a password is required`）看着像规则没装上，不像装对了但被覆盖。

3. **还得放开 `systemctl reboot`。** steamos 自己重启不了：ssh 会话没有
   本地 seat，polkit 要交互认证
   （`Call to Reboot failed: Interactive authentication required.`，而
   systemctl 退出 0）。少了它，「不用碰手机」在最后一步断掉。

另一条断言（`assert-alioth-kit.sh` 6b）的由来：被 sudoers 放开的那个命令
必须是 `root:root` 且组/其他不可写。一条 NOPASSWD 规则指向一个调用者自己
能重写的脚本，等于白送 root。构建路径本来是对的（`apply-alioth-overlay.sh`
在 sudo 下跑，`install -D` 给 root:root），但手工往设备上装的时候 `tar`
把归档里的 uid 原样还了出来，文件成了 `steamos:steamos`。

### 声卡注册了：pinctrl 撞名是真因

用上面这条路送上修好 DTS 的内核（全程没碰手机），`/proc/asound/cards` 从
空变成：

```
 0 [xiaomialioth   ]: sm8250 - xiaomi-alioth
```

也就是说前一节「删掉自己那份 `tert_mi2s_active`」确实是声卡不注册的原因。
`scripts/assert-alioth-dtb.py` 第 4d 条（同一 pinctrl state 下不许有引脚被
两个 mux 子节点同时认领）现在是 GREEN，19 条全过。

UCM 也对上了：`alsaucm -c xiaomi-alioth list1 _verbs` 列出 HiFi / Speakers，
`TERT_MI2S_RX Audio Mixer MultiMedia1` 这个控件存在且能置 on。
`speaker-test -D hw:0,0` 协商出 48 kHz / S16_LE / 2ch、period 1440、buffer
5760，流真的跑了 6 秒。

## 扬声器通路：四个缺陷串在一起（2026-10-24）

声卡注册之后到「有一个真的 sink」之间还隔着四件事，而每一件单独看都表现为
「没声音」，谁都不提自己。按发现顺序：

### 1. machine driver 从不告诉 codec 位时钟

打开 PCM 能跑起一条流（48 kHz / S16_LE / 2ch / period 1440 全协商好了），
没声音，每颗放大器一行：

```
cs35l41 3-0041: Enable(1) failed: -110
snd-sm8250 sound: ASoC: PRE_PMU: LCV Main AMP event failed: -110
```

-110 是 -ETIMEDOUT，来自 `cs35l41_global_enable()`：`cirrus,boost-type = <0>`
（内部升压）这条路设上 `GLOBAL_EN` 然后轮询 `IRQ1_STATUS1` 等 `PUP_DONE`，
100 ms 超时。放大器上不来电，因为它的 PLL 没有东西可锁 —— `PLL_CLK_CTRL` 的
`REFCLK_FREQ` 还是复位值，芯片不知道喂给它的 SCLK 是多少。

写那个字段的是 `cs35l41_component_set_sysclk()`，而**没有人调它**。
内核里另外两个驱 CS35L41 的 machine driver（`sof_cirrus_common.c`、
`mt8189-nau8825.c`）都成对调 `snd_soc_component_set_sysclk()` +
`snd_soc_dai_set_sysclk()`；`sound/soc/qcom/sm8250.c` 一个都不调，尽管同一个
switch 分支里已经把这个数字告诉了 CPU 侧（`MI2S_BCLK_RATE = 1536000`，在
`cs35l41_pll_sysclk[]` 表里是 `0x1B`）。补丁 `0025-asoc-qcom-sm8250-*` 补上。

### 2. 自刷只换 boot，而 `CONFIG_SND_SOC_SM8250=m`

上面那个补丁第一次是白做的。boot 镜像里只有内核和设备树，模块在 userdata
上 —— 自刷了 boot、重启、**一模一样的 -110**，而设备上那个 `.ko` 还是几小时
前的旧文件。版本字符串一样，所以 modprobe 什么都不报错。

这个移植里一半的东西是 `=m`（`ath11k`、`pci-pwrctrl-pwrseq` …），所以内核镜像
和它的模块必须当成一件东西。`alioth-selfflash-boot.sh` 现在默认两样都送，
设备侧是 `alioth-install-modules`（验归档每个成员的路径/类型/链接目标，只往
`/usr/lib/modules/<版本>` 写，最后 `depmod`）。

### 3. Frame 把 ACP 关了，而 ACP 正是读 UCM 的那一半

放大器修好了还是没有 sink，只有 `Dummy Output`：

```
Failed to create ALSA node alsa_output.platform-sound.playback.0.0:
Object activation aborted: PipeWire proxy destroyed
Failed to create ALSA node alsa_input.platform-sound.capture.0.0: ...
```

Frame 自己的 `50-alsa-config.conf` 设 `api.alsa.use-acp = false`。ACP 关着时
WirePlumber 完全不看 UCM，改去枚举裸 PCM —— 于是它会去给一张**没有采集 PCM**
的卡建 `alsa_input...capture.0.0`。认出来的线索是节点名：裸形式是
`alsa_{output,input}.<bus>.<playback|capture>.<卡>.<设备>`，而 UCM 来的节点以
UCM 的 verb 和 device 命名。ACP 关着时 UCM 的 `EnableSequence` 也不会跑，所以
`TERT_MI2S_RX Audio Mixer MultiMedia1` 会停在 0，就算有 sink 也是静音。

`76-alioth-alsa.conf` 把 ACP 打开（和 `52-sm8550-alsa.conf` 同样的理由），
并把 period-size 从 Frame 要的 256 提到 1440 —— 这个 PCM 的下限是 480
（`aplay --dump-hw-params`: `PERIOD_SIZE: [480 3360]`、`PERIODS: [2 8]`）。
放在 `/etc` 而不是 `/usr/share`：WirePlumber 先合并 `/usr/share` 再合并
`/etc`，放在 `/usr/share` 的片段无论叫什么都会输给 Frame 的那个 50-。

### 4. Frame 的 microphone-tracker hardcode 的 sink 名正好是我们的

ACP 打开之后 UCM 终于被读了 —— 节点名变成
`alsa_output.platform-sound.HiFi__Speaker__sink`，路由 `[Out] Speaker` 找到，
它还被设成 `default.audio.sink` —— 然后 wireplumber 立刻 SIGSEGV。每次开机崩
5 次，最后停在 `failed`，于是唯一的 sink 还是 `Dummy Output`。日志里崩溃前
一行是「set default node for default.video.source gamescope」，什么都没提到
原因，systemd-coredump 的栈全是 `n/a`。怎么看出来的：
`WIREPLUMBER_DEBUG=3 wireplumber` 前台跑一次，看它走到哪一步为止。

`/etc/wireplumber/scripts/microphone-tracker.lua`（被 `40-mic-processing.conf`
标成 `required`）开头：

```lua
local BUILTIN_SOURCE_NAME = "alsa_input.platform-sound.HiFi__Mic__source"
local BUILTIN_SINK_NAME   = "alsa_output.platform-sound.HiFi__Speaker__sink"
```

第二个**正好**是这台手机产出的名字 —— 节点名由总线路径（`platform-sound`，
和 Frame 一样）加 UCM 的 verb 和 device（`HiFi` / `Speaker`，来自我们自己的
`ucm2/Xiaomi/Alioth`）拼出来。于是那个脚本像在 Frame 上一样接管，然后去动
mic 那一半 —— 而这台机器没有采集通路。`75-alioth-no-frame-scripts.conf` 把它
和 `spatial-node-config` 一起 disable（两个都是「Frame 专属脚本被标成
required，而这台机器缺它依赖的东西」）。

### 冷启动实测结果

```
state=active   crashes=0
Sinks:  * 52. Built-in Audio Playback   [vol: 0.70]
TERT_MI2S_RX Audio Mixer MultiMedia1 : values=on
dmesg 里 "Main AMP event failed" 条数 = 0
```

`pw-play` 放一个文件能跑满，放大器一条报错都没有。

### 还没做的

- **声道映射**。两颗放大器都默认取 ASP RX1（slot 0），所以立体声内容会在两个
  扬声器里都放左声道。要 `snd_soc_dai_set_channel_map()`，参考
  `mt8189-nau8825.c` 里 `rx_slot[] = {0, 1}` 的做法。
- **麦克风**。本版 DTS 显式 `disabled` 了 `&vamacro` 和 `&lpass_tlmm`，没有
  采集通路。要做得开这两个、加 DMIC pinctrl、加 VA DMIC 采集后端和采集前端、
  UCM 加采集设备。注意上面第 4 条：真做出一个
  `alsa_input.platform-sound.HiFi__Mic__source` 之后，Frame 的
  microphone-tracker 也许就能重新打开了。

## 更正：后端不是 MI2S，是 Tertiary TDM（2026-10-24）

上一节「扬声器通路：四个缺陷串在一起」里修的四项都是真缺陷，但结论错了。
那四项修完之后 `pw-play` 能跑满、放大器一条报错都没有 —— 而扬声器**一声
都没有出**。「跑满」只说明 PCM 在前进，不说明有功率送到喇叭上。

### 功放查得过，但零输出功率

绕开 PipeWire 直开 `hw:0,0`，PCM 确实进 `state: RUNNING`（PipeWire 侧
`pcm0p status: closed`，说明之前看到的「流已链接」全在 PipeWire 图里）。
此时把两颗 CS35L41 的寄存器全读了一遍：

| 寄存器 | 值 | 含义 |
|---|---|---|
| `0x2014` PWR_CTRL1 | GLOBAL_EN=1 | 芯片使能 |
| `0x2018` PWR_CTRL2 | AMP_EN=1, BST_EN=0b10 | 功放和升压都开 |
| `0x2C04` REFCLK_INPUT | `0x370` | CLK_SEL=SCLK, CLK_EN=1, REFCLK_FREQ=0x1B（1536000） |
| `0x10018` IRQ1_STATUS3 | bit1 置位 | **PLL 已锁** |
| `0x10010` IRQ1_STATUS1 | `0x00400000` | 只有 bit22，**一个故障都没记下** |
| `0x6000` AMP_DIG_VOL_CTRL | `0x8000` | 0 dB |
| `0x6C04` AMP_GAIN_CTRL | 第 0 档 | 见下 |

「噪声一直放、只切换 `Analog PCM Volume` 0↔16」做 A/B 电流测量，三轮里
增益 16 的平均电流**都比增益 0 还低**（99201→58267、53222→40608、
78368→28482 µA）。CPU 负载恒定，所以这是功放零额外功率输出，不是测量噪声。

### 真因：数据线根本没接到 MI2S 的 SD0 上

从 `vendor_boot_a` 里把原厂 DTB 提出来（`dtbo_a`/`dtbo_b` 两个分区全是零，
没有板级覆盖层，所以 vendor_boot 里那份就是全部），引脚组是：

```
tert_mi2s_sck_active  = gpio133   mi2s2_sck
tert_mi2s_sd0_active  = gpio134   mi2s2_data0
tert_mi2s_ws_active   = gpio135   mi2s2_ws
tert_mi2s_sd1_active  = gpio137   mi2s2_data1
```

对照 pmOS 的 `alioth_pmos-nikroks.dts`（真机能出声）：功放的 ASP_SDIN 接的是
**gpio137 / `mi2s2_data1`**，gpio134 是 VI sense 从功放回传 SoC 的方向。而
上游 `sm8250.dtsi` 的 `tert_mi2s_active` 只有 133/134/135 —— 把它当扬声器的
pinctrl 用，等于把时钟和帧同步都配对了，唯独数据线悬空。功放于是看到完整的
时钟、锁上 PLL、一个故障都不报，然后一直收到静音。

同一份参考 DTS 还定下了后端：**Tertiary TDM**（`TERTIARY_TDM_RX_0` = 56），
不是 MI2S。两颗功放共用一条总线、各取一个槽，MI2S 做不到。

### 三层修复

1. **DTS**：`&q6afedai` 换成 `dai@56`，补齐 TDM 帧参数
   （`sync-mode=0` short sync、`sync-src=1` internal、`invert-sync=1`、
   `data-delay=1`）；`&sound` 的 cpu dai 指向 `TERTIARY_TDM_RX_0`；`&tlmm` 下
   自己定义 `alioth_tert_tdm_active`，四条线齐全，含 **gpio137**。节点名刻意
   和上游的 `tert-mi2s-active-state` 不同 —— 同名会在 `&tlmm` 下合并，导致
   gpio134 被认领两次。

2. **0026**：`q6afe_tdm_port_prepare()` 从不把 `data-out` / `invert-sync` /
   `data-delay` 送给 ADSP —— `struct q6afe_tdm_cfg` 里根本没有这三个字段，
   而 `q6afe_dai_priv_data` 里有，DTS 里读到的值就卡在那儿。补上字段和搬运。

3. **0027**：`sm8250.c` 原本 `grep -i tdm` 零命中。`q6tdm_set_tdm_slot()` 是
   唯一写 `nslots_per_frame` / `slot_width` 的地方，没人调它，ADSP 就收到一份
   「0 个槽、每槽 0 位」的配置并拒收。加 `TERTIARY_TDM_RX_0` 的 startup 分支
   和一个 `hw_params` op。

### ADSP 的 EBADPARAM 是怎么定到的

前两轮刷完仍然是：

```
qcom-q6afe: cmd = 0x100ef returned error = 0x2      (ADSP_EBADPARAM)
qcom-q6afe: AFE enable for port 0x9020 failed -22
q6afe-dai: ASoC error (-22): at snd_soc_dai_prepare() on TERTIARY_TDM_RX_0
```

猜了两次都没中（先是 CPU 侧 channel map 传槽序号，改成字节偏移仍然失败），
所以第三轮改成拿数据：在 `q6afe_dai_prepare()` 的 TDM 分支里把整份配置
`dev_info` 打出来（设备上 `CONFIG_DYNAMIC_DEBUG` 没开，`/sys/kernel/debug/
dynamic_debug/control` 不存在，`dev_dbg` 是编译掉的）。一眼就看见了：

```
TDM port 56: 2 ch, 48000 Hz, 24 bit, ... 2 slots of 16, mask 0x3
```

**24 位的样本装不进 16 位的槽。** `sm8250_be_hw_params_fixup()` 钉了采样率和
声道数，却把格式留给协商，前端的 S24_LE 就一路传到了后端。TDM 的槽宽是固定
的，所以后端格式必须跟着槽宽走。

教训：两次盲猜的代价，比一开始就把配置打出来高得多。

## GPU 占用率恒为 0：msm 缺一个 debugfs 文件（2026-10-24）

Game Mode 的性能叠加面板里 GPU 占用率一直是 0。不是驱动没起来 —— 内核确实
导出了 msm DRM fdinfo（`drm-engine-gpu`、`drm-cycles-gpu`、`drm-maxfreq-gpu`），
`/sys/class/devfreq/3d00000.gpu` 的 `trans_stat` 也有真实的档位跳转。

### fdinfo 这条路走不通

叠加面板是独立进程 `mangoapp`，不是注入到游戏里的 `libMangoHud.so`。fdinfo 的
引擎时间是**按 client 统计**的，所以 mangoapp 读到的是自己的 GPU 时间 ≈ 0。
amdgpu 有系统级的 `gpu_busy_percent`，Steam Deck 上因此没有这个问题；msm 没有
对应的节点。

### 上游 MangoHud 的 msm 后端读的是别的东西

读了 MangoHud 源码才发现根本不需要改它。驱动名取自
`/sys/class/drm/renderD128/device/driver` 的符号链接，我们这台是 `msm_dpu`，
走 `MSM_DPU` 这个后端，而它的 `get_load()` 读的是：

```
/sys/kernel/debug/dri/<N>/perf_now
```

一个浮点百分比，别的什么都不读。这个文件 mainline msm 里没有（是 Valve 的
下游补丁），我们内核里也没有 —— 所以修法在内核侧，不在 MangoHud 侧。

### 0028：perf_now

数字本来就在：`a6xx_gpu_busy()` 给 devfreq governor 喂一个单调递增的忙周期
计数器。governor 消费的是自己那份采样（`df->busy_cycles`），所以再加一个标记
（`load_busy_cycles` / `load_time`）和一个 debugfs 文件就够了，不碰 governor。

权限上不用动 overlay：镜像里 `/sys/kernel/debug` 已经是 `root:perf 0750`，
而 `steamos` 在 `perf` 组里，所以 0444 的文件它读得到。

这条通路掉了的表现是「叠加面板里 GPU 恒为 0」，和驱动根本没起来长得一模一样，
所以 `assert-alioth-boot-image.sh` 的 C 组里直接查 `System.map` 有没有
`msm_devfreq_get_load`。

## 事故：把听筒烧出了糊味（2026-10-24）

声音通了之后我做了一次听音确认，命令是：

```
speaker-test -D hw:0,0 -c 2 -t sine -f 440 -l 0
```

放了几分钟，用户闻到糊味，位置在**机身上方听筒附近**。记在这里不是为了留个
教训性的段落，是因为其中两件事是**配置缺陷**，不是操作失误，不修就会复现。

### 操作上错的三处

1. **`-D hw:0,0` 绕过了 PipeWire**，走的是功放满刻度。UCM 里的增益是「系统
   音量 100% 时的上限」，不是「测试音量」。
2. **正弦波**。波峰因数 1.41，粉噪约 4 —— 同样峰值电压下，正弦波送进音圈的
   平均功率高得多。而**音圈没有任何温度传感器**。
3. **`-l 0` 是无限循环**，开了就去做别的事。

### 配置缺陷一：两颗功放不该同增益

参考配置（pmOS）两颗都是 `Analog PCM Volume 18` = +18.5 dB，我照搬了。但
`3-0040` = RCV 驱动的是**听筒** —— K40 / POCO F3 的上方声道由听筒兼任，振膜
和音圈比底部主扬声器小一个量级。糊味出现在听筒附近，不是底部，这不是巧合。

现在是：

| 功放 | 位置 | `Analog PCM Volume` |
|---|---|---|
| LCV `3-0041` | 底部主扬声器 | 10 = +10.5 dB |
| RCV `3-0040` | 上方听筒 | 4 = +4.5 dB |

由 `assert-alioth-overlay.py` 的「听筒增益低于主扬声器」守住。

### 配置缺陷二：−12 dB 的数字衰减从来没有生效过

事故之后重启验证时才发现：`Digital PCM Volume` 读回来是 **817**（芯片复位默认
0 dB），不是 `Alioth.conf` 的 `BootSequence` 里写的 721（−12 dB）。

`BootSequence` 要 `alsactl init` 或 `alsaucm boot` 去执行，而这台机器上**没有
任何东西执行它**。真正会跑的是 `HiFi.conf` 的 `SectionVerb.EnableSequence`
—— PipeWire 的 ACP 执行那一段（证据：模拟增益改成 4/10 之后重启读回来就是
4/10）。

**所以事故当时的真实增益是 0 dB 数字 + 18.5 dB 模拟 = +18.5 dB**，不是我以为
的 −12 + 18.5 = +6.5 dB。比我的估计高 12 dB。

这个缺陷不报错、不留日志，只是让衰减静悄悄地不生效。现在全部增益都在
`HiFi.conf` 的 `EnableSequence` 里，并由 `assert-alioth-overlay.py` 两条断言
守住：「Alioth.conf 里没有 cset」和「数字衰减写在 HiFi.conf 里」。

冷启动实测：

| | 数字 | 模拟 | 合计 |
|---|---|---|---|
| RCV（听筒） | 721 = −12 dB | 4 = +4.5 dB | −7.5 dB |
| LCV（底部主扬声器） | 721 = −12 dB | 10 = +10.5 dB | −1.5 dB |

比事故当时分别低 26 dB 和 20 dB。

### 配置缺陷三：没有限幅器，而过温保护保护不到音圈

原厂 Android 下有 Cirrus 的 DSP 调音固件做限幅，那份固件不可再分发，我们没有
—— `PCM Source` 只能设 `ASP`（设 `DSP` 在 DSP1 未加载时就是静音），所以信号
是**直通**的，没有任何限幅。

而 CS35L41 的 `TEMP_WARN` / `TEMP_ERR` 测的是**芯片结温**。音圈没有传感器。
事故后读两颗功放的 `IRQ1_STATUS1`：

```
3-0040  0x00c00230
3-0041  0x00c00230
```

置位的是 bit 4/5/9/22/23。六个故障位（6 BST_OVP、7 BST_DCM_UVP、8 BST_SHORT、
15 TEMP_WARN、17 TEMP_ERR、31 AMP_SHORT）**一个都没亮**，而
`CS35L41_INT1_MASK_DEFAULT` 确认这六位是解除屏蔽的 —— 不是屏蔽了才看不见。
bit 23 是 `PDN_DONE`（正常断电完成，`CS35L41_INT1_UNMASK_PDN` 清的就是它），
bit 22 同类。温度上同样没有异常：电池 36.0 °C，SoC 51–52 °C。

**也就是说芯片视角一切正常，而听筒已经在烧。** 这两档模拟增益是唯一的护栏。

### 以后怎么测

`scripts/alioth-speaker-test.sh [秒数=3] [音量=0.35]`：只走 PipeWire（`-D`
永远不是 `hw:*`）、只用粉噪、时长硬上限 5 秒且由 `timeout --signal=KILL` 兜底
（不靠播放器自己停）、放之前放之后各读一次两颗功放的 `IRQ1_STATUS1` 并解码
故障位，放之前就有故障位直接拒绝执行。

## 所有应用都没声音：又一次撞名，这次撞在权限管理器上（2026-10-24）

TDM 修好之后 `speaker-test -D hw:0,0` 能出声（而且太响，见上面的事故），但
**经 PipeWire 的一切都没有声音** —— 包括 Steam 游戏。表现和「扬声器烧了」
完全一致，所以它一度被当成硬件损伤。

### 排查链条

绕开 PipeWire 直开 `hw:0,0` 放全零样本：PCM 进 `RUNNING`，内核零报错 ——
硬件通路是好的。而经 PipeWire 时：

```
PCM=closed                     声卡从来没被打开
wpctl status                   sink 在、默认、音量正常
TERT_TDM_RX_0 Audio Mixer      values=on
Digital PCM Volume             721（UCM 的 EnableSequence 确实跑了）
pw-link -l                     一条链接都没有
```

WirePlumber 日志：

```
wp-event-dispatcher: link failed: 2 of 2 PipeWire links failed to activate
```

PipeWire 日志（`pw-metadata -n settings 0 log.level 4` 打开）：

```
link-factory: can't link ports 60 and 65: Operation not permitted
```

EPERM 来自 `impl-link.c` 的 `check_permission()`：节点的**所属客户端必须看得见
对方节点**。而 `module-access` 的文档写明，`access` 不是 `unrestricted` 的
客户端一开始**什么权限都没有**，要等会话管理器来发。

带 `WIREPLUMBER_DEBUG=I` 重启 wireplumber，一眼看到发了什么：

```
Updating permissions on client 57 (Balatro.exe): any=rwxm-
Updating permissions on client 52 (WirePlumber):  any=rwxml
```

**缺的就是 `l`（link）。** 应用根本没有建立链接的权限。

### 真因

`/etc/wireplumber/wireplumber.conf.d/10-access.conf` 里给普通应用用的权限管理器
叫 `steamos-default`。它的 `default_permissions` 是 `"all"`，但规则里对一串节点
执行 `set-permissions = ""`（剥夺全部权限），而那串节点里逐字写着：

```
{ node.name = "alsa_output.platform-sound.HiFi__Speaker__sink" }
```

**这正是这台手机 sink 的节点名。** 第三次撞名了 —— 节点名由总线路径
（`platform-sound`，和 Frame 一样）加 UCM 的 verb 与 device（`HiFi` / `Speaker`，
来自我们自己的 `ucm2/Xiaomi/Alioth`）拼出来，两边逐字相同。前两次是
`microphone-tracker.lua` 的 `BUILTIN_SINK_NAME`，和 `&tlmm` 下的
`tert-mi2s-active-state`。

在 Frame 上这条规则是故意的：把裸 ALSA sink 对应用藏起来，强迫它们走空间音频的
filter chain。而这台机器上 filter chain **不存在** —— `vraudiocompositor.so` 这个
rootfs 不带，所以我们禁掉了 `steamos.spatial-node-config`。于是应用既看不见裸
sink、又没有 filter chain 可连，什么都链接不到。

### 修法

Valve 已经为「没有空间音频」准备了一个管理器：`steamos-default-nospatial`。
`default_permissions` 同样是 `"all"`，但剥夺列表里只有 filter chain 那几个节点，
**没有**我们的 sink。

`alioth-overlay/etc/wireplumber/wireplumber.conf.d/77-alioth-access.conf` 把
`access = "default"` 的客户端指到它。**关空间音频和换这个管理器是一件事的
两半，之前只做了一半。**

修完立刻：PCM `RUNNING`、8 条链接、功放 `PWR_CTRL2=0x21`（`AMP_EN=1`，之前一直
是 `0x20`），底部主扬声器出声。

由 `assert-alioth-overlay.py` 的「关了空间音频就选 nospatial 权限管理器」守住 ——
那一条把两件事绑在一起，禁了脚本却没换管理器就会失败。

### 代价：之前判断「听筒烧了」的证据被削弱了

事故那次用户闻到糊味是真的。但后来几轮「还是没声音」现在知道是这个权限问题，
和硬件无关。所以「听筒已经损坏」这个结论此前拿到的证据比我以为的少。

## GPU 占用率仍然为 0：MangoHud 把路径写死成了 dri/0（2026-10-24）

0028 把 `perf_now` 加进了 msm 的 debugfs，真机也读得出数（4 / 5），但叠加面板
里的 GPU 占用率依然是 0。

原因是镜像自带的 MangoHud（20260922.1-1）**把路径写死了**：

```
$ strings /usr/bin/mangoapp | grep perf_now
/sys/kernel/debug/dri/0/perf_now
```

上游 master 的 `MSM_DPU::open_load()` 是遍历 `/sys/class/drm/<node>/device/drm`
找 `card*` 再拼路径的，镜像里这个版本还没有。

而这台机器上 **`card0` 不存在**：

```
$ ls /sys/class/drm/card[0-9]
card1 -> msm_dpu
$ sudo ls /sys/kernel/debug/dri/
1  128  ae01000.display-controller  client-*
```

`simpledrm` 在开机早期占了 DRM minor 0（`CONFIG_DRM_SIMPLEDRM=y`，给
`/chosen/framebuffer` 用），msm 通过 aperture 接管后它退场，但 minor 号不回收 ——
所以 msm 落在 `dri/1`。Frame 上 msm 就是 `card0`，Valve 才敢写死。

内核那一侧是对的，错在用户态找错了地方。

### 修法：让 msm 拿到 minor 0

不重编 MangoHud —— 仓库里 `scripts/build-mangohud-in-rootfs.sh` 建的是 v0.8.4，
而镜像自带的是 20260922.1-1（新得多的 `mangohud-next` 代码），换过去等于把一整套
降级。

改成在 cmdline 里加 `initcall_blacklist=simpledrm_platform_driver_init`：
simpledrm 不注册，msm 就拿到 minor 0，MangoHud 写死的那个路径随之成立。
`CONFIG_DRM_SIMPLEDRM` 在配置里仍然是 `y`，屏蔽只在 cmdline 这一层 —— 去掉这个
token 就全恢复。

代价是失去 msm 绑定之前那几秒的 framebuffer 控制台，也就是阶段 1 依赖的那条
通道。msm 绑定之后 fbcon 走 `CONFIG_DRM_MSM_KMS_FBDEV`，面板上的控制台照旧。
真要调早期启动，删掉这个 token 重做镜像即可。

真机实测：

```
card0 -> msm_dpu
/sys/kernel/debug/dri/0/perf_now = 42
```

由 `assert-alioth-boot-image.sh` 的 cmdline 断言守住 —— 这个 token 掉了的表现
同样是「面板上 GPU 占用率恒为 0」，离原因极远。

### 听筒没有损坏

权限管理器修好之后分别单独驱动两颗功放（另一颗静音）：底部主扬声器和上方听筒
都出声，听筒音质正常、音量比底部小一点 —— 正好是 6 dB 增益差应有的结果
（RCV +4.5 dB / LCV +10.5 dB）。

所以事故那次的糊味是真的，但听筒挺过来了。

## 阶段 2 验收（2026-10-24）

逐项对 spec §8。证据行取自真机，设备唯一标识已脱敏。

**十二项里十一项 PASS，唯一未测的是 s2idle 待机一夜掉电（需要一夜）。**

| 项 | 结论 | 证据 |
|---|---|---|
| 开机直接进 Game Mode | **PASS** | `gamescope --backend drm --prefer-output DSI-1 --scaler fit --filter linear`；`start-gamescope-session gamescope-session.target`。去 VR 化（`--backend openvr --vr-session-manager`）生效 |
| 横屏，2400x1080 | **PASS** | `card0-DSI-1/modes` = `1080x2400`，面板驱动向 DRM 报 `rotation=270`，合成器横屏 |
| 纯触摸完成 Steam 登录 | **PASS** | 本会话用 Steam 自带屏幕键盘完成登录 |
| 一个 Windows 独立游戏经 Proton 11 ARM64 跑通 | **PASS** | PipeWire 图里出现客户端 `Balatro.exe`，有音频输出端口 |
| mangoapp 性能浮层 | **PASS** | 浮层显示，GPU 占用率有数（需要补丁 0028 + `initcall_blacklist=simpledrm_platform_driver_init`，见上文） |
| 扬声器 | **PASS** | 两颗 CS35L41 都出声，Tertiary TDM / gpio137 / nospatial 权限管理器三者齐备 |
| 边充边玩，电池 ≤ 45 °C | **PASS** | 充电 + Game Mode 下电池 38.0 °C，SoC 最热 61 °C |
| 蓝牙 BD_ADDR 跨重启稳定 | **PASS** | 重启前后 `hciconfig hci0` 的 BD Address 逐字相同（md5 一致）。注意它后三字节是 ASCII `"149"`，像是固件读不到 NVM 时的占位值 —— 但稳定就够了，手柄配对不会丢 |
| 蓝牙手柄识别为 Deck 手柄 | **PASS** | 用户实测：配对后正常，按键图标正确 |
| 音量键呼出 Steam 快捷菜单 / 电源键待机唤醒 | **PASS** | 用户实测正常 |
| Game Mode 里显示电量 | **PASS** | 用户实测正常；sysfs 侧 `capacity=94`、`status=Charging` |
| s2idle 待机一夜掉电 | **未测** | 需要一夜，唯一待测项 |

### 麦克风：仍然没有

本版 DTS 显式 `disabled` 了 `&vamacro` 和 `&lpass_tlmm`，`aplay -l` 只有一个
PCM、playback only，没有采集通路。要做得开这两个、加 DMIC pinctrl、加 VA DMIC
采集后端和采集前端、UCM 加采集设备。

注意做出 `alsa_input.platform-sound.HiFi__Mic__source` 之后会同时触发两处撞名：
`microphone-tracker.lua` 的 `BUILTIN_SOURCE_NAME`，以及权限管理器剥夺列表里的
`steamos.mic_filter` 一类条目 —— 参见上面那两节。

### 固化：设备上的手工改动与仓库对齐（2026-10-24）

阶段 2 的真机调试里，有四样东西是手工装到设备上去的（改一次重刷一次镜像不
现实）：`77-alioth-access.conf`、两个 UCM 文件、`alioth-install-modules`。
验收通过之后要回答的问题是：**仓库里的 overlay 是不是设备现状的唯一事实
来源** —— 也就是说，一次干净的 `--install` 装出来的系统，和现在这台跑着
的、我手工改过的系统，是不是同一个东西。

不重装（会擦掉已装的游戏和 Steam 登录），改为逐文件比 sha256。
`alioth-overlay/` 下 `etc/` 与 `usr/` 共 17 个文件，设备上对应路径：

- **16 个 sha256 完全相同**，且全部 `root:root`，脚本 0755、配置 0644。
- **1 个不同**：`etc/wireplumber/wireplumber.conf.d/76-alioth-alsa.conf`。
  差异只有一行注释 —— 设备上那份还写着 `TERT_MI2S_RX Audio Mixer
  MultiMedia1`，而后端改成 Tertiary TDM 之后仓库里已经是
  `TERT_TDM_RX_0`。配置项一个字节没差，不影响行为。已把仓库那份推到设备，
  现在两边 sha256 相同。

sudoers 不在 overlay 里（它由 `make-steamos-alioth.sh` 在
`ALIOTH_SSH_PUBKEY` 块里现生成），单独查了设备现状：
`root:root 0440`、三行规则与脚本里的字面量一致、`visudo -c -q` 过、
`/etc/sudoers.d` 按 `LC_ALL=C sort` 排最后的是 `zz-alioth-write-boot`
（前面是 `proxy_vars`、`wheel`）、`/var/lib/overlays/etc/upper/sudoers.d/`
里也有一份。

另外顺带查了 `/etc/wireplumber`、`/usr/share/alsa/ucm2/Xiaomi`、
`/usr/lib/steamos-arm` 下有没有手工操作留下的 `*.bak`/`*.orig`/`*~`：没有。

**补的两条断言**（`scripts/assert-alioth-kit.sh` A 组，静态、不需要 kit）：

1. **sudoers 语法**。把脚本里那三行字面量抠出来喂 `visudo -c`。值得单独守
   是因为 `sudoers.d` 里任何一个文件有语法错，sudo 会**整体**罢工而不是只
   忽略坏的那条 —— 于是 steamos 连 `sudo true` 都跑不了，自刷和重启一起
   断掉，而 Game Mode 里没有别的拿 root 的途径。
2. **sudoers 必须进 `/etc` 的 overlayfs upperdir**。只写下层的话开机后这条
   规则不存在，症状是「sudo 要密码」—— 和「文件名排序不对被
   `sudoers.d/wheel` 覆盖」（同一天踩过）长得一模一样，而修法完全不同。
   `assert-alioth-overlay-applied.sh` 的第 2 条替 overlay 里的文件守了这件
   事，sudoers 不在 overlay 里，所以得单独守。

### 独立审查的四条修复（2026-10-24）

阶段 2 验收之后派了一个 fresh reviewer 审整个分支（35 个提交 / 53 个文件）。
它判定分区安全那部分找不到办法让脚本去写 `super`/`abl_*`，但指出四条必须先
修的 —— 其中三条是同一个失效模式的三个侧面。

**1. 功放增益的唯一护栏没有上限。** `assert-alioth-overlay.py` 原来只断言
`RCV < LCV`，不管绝对值。反例：`RCV 19 / LCV 20` 顺序成立，断言全绿，而那是
听筒 +19.5 dB —— 比烧出糊味那次（18 → +18.5 dB）还高 1 dB。控件刻度是
`SOC_SINGLE_TLV(..., CS35L41_AMP_GAIN_CTRL, 5, 0x14, 0, amp_gain_tlv)` 配
`DECLARE_TLV_DB_SCALE(amp_gain_tlv, 50, 100, 0)`，档位 n = (0.5 + n) dB，
上限 `0x14` = +20.5 dB。现在加了一条绝对上限断言，取值就是真机实测安全的那
一对（4 / 10）。往上调不是改配置，是一个硬件决定。

**2. 听音脚本查了时长，没查电平。** 而 `wpctl` 接受大于 1.0 的值 —— 当天在
设备上实测：`set-volume 1.5` 读回来就是 `1.50`，PipeWire 会老老实实加上那段
软增益。`alioth-speaker-test.sh 5 1.5` 是把已经 0.25 满刻度的粉噪推上去削波，
五秒削波宽带信号送进一个没有限幅器的 D 类功放 —— 和当初 `-D hw:0,0` 到达的是
同一个地方，只是这次**穿过** PipeWire。真正危险的量是电平×时长，所以两个都
得拦：电平硬上限 1.0，正则先限成「数字和一个小数点」（它要拼进远端命令），
再用 awk 比大小。顺带把放完不恢复系统音量这件事也修了 —— 否则测试的电平会
留在 Game Mode 里。

**3. 故障位检查读不到寄存器时「无故障」通过。** 原来那段解码嵌在听音脚本的
heredoc 里，`bad` 初值 0，解析不出两个字段的行一律跳过 —— 空输入、半截输入、
`sudo: a password is required`，一律退出 0。也就是说 debugfs 没挂、regmap 调试
关了、或者放完之后 ssh 没连上，操作者都会读到「没有故障位」，而事实是一个
字节都没读到。和第 2 条凑在一起是最坏的组合：电平没有上限，而故障报告不会
失败。已拆成 `scripts/alioth-amp-faults.py`：两颗功放的寄存器缺一个就退出
非零，并明说「这不是没有故障，这是没读到」。

**4. 不可逆的 `--install` 之前没有任何东西拦住「固件是通用签名版」的 kit。**
审查指出的是一处不对称：boot 镜像的那套规则是**接线进写入路径**的
（`flash-alioth.sh` 在任何写之前跑 `assert-alioth-boot-image.sh`），而「固件
是不是机内签名版」只靠记性 —— `make-steamos-alioth.sh` 原来在没有
`ALIOTH_FW_DIR` 时只打印四行 `!!` 然后继续，照样产出完整的 9 GB kit。之后
会发生的事：警告滚出屏幕、十几分钟后刷机、输入 `ERASE`，**Android 的
`/data` 就此消失**，而装出来的系统是黑屏加没声音，然后要重新取固件 —— 从一台
Android 已经被擦掉的手机上取。

两道闸：`--install` 在最前面就要求 `ALIOTH_FW_DIR`（在 rsync 之前退出），
而构建时往 kit 里写一份 `DEVICE-FIRMWARE`（含固件的 sha256），
`flash-alioth.sh --install` 要求看到它才肯写 `userdata`。要的是**正面**凭据
而不是「没有 GENERIC 标记就放行」—— 否则这个检查存在之前构建的 kit、手工拷
过来的 kit，都会被当成好的。不可逆的一步要有人签过字，不是没人反对。明知
要刷一个黑屏镜像：构建和刷机两次都设 `ALIOTH_FW_GENERIC_OK=1`。

#### 顺带记一次：验护栏的测试自己把护栏越过去了

`scripts/assert-alioth-speaker-test.sh` 的第一版没有桩，直接拿真设备跑那些
越界用例 —— 于是「电平 1.5」那条**真的在设备上放了三秒**。事后读两颗的
`IRQ1_STATUS1` 都是 `0x00400000`（只有 bit 22 PUP_DONE，六个故障位一个没
亮），电池 32.0 °C，系统音量已复位。没有损伤，但这正是第 2 条描述的那条路，
而走上去的是那个用来防止它的测试。现在那个断言脚本用 `ALIOTH_SSH` 覆盖成一个
桩，一个字节都不送到设备上。

### 截图：gamescopectl 只抓基础层（2026-10-24）

`gamescopectl screenshot <路径>` 抓到的是 base plane —— 只有游戏/Steam UI
那一层。mangoapp 的性能浮层在另一层上，所以无论浮层开着没开着，截出来都一样，
第二个参数（试过 0..3）也不改变这一点。

全合成画面要走 gamescope 的调试截图原子，它写死输出到 `/tmp/gamescope.png`：

```sh
DISPLAY=:1 xprop -root -f GAMESCOPECTRL_DEBUG_REQUEST_SCREENSHOT 8c \
  -set GAMESCOPECTRL_DEBUG_REQUEST_SCREENSHOT 0
```

DISPLAY 是 `:0` 还是 `:1` 要看 `/tmp/.X11-unix/` 下有哪些（本机两个都在，对两个
都设一遍最省事，不对的那个 xprop 自己会报错）。

还有一个坑：`gamescopectl screenshot` 写 `/home/steamos/...` 会返回 0 但不产出
文件，写 `/tmp` 才正常。
