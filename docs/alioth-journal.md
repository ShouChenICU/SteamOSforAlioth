# alioth 折腾记录

这份文档记**过程**：试了什么、为什么不行、怎么绕过去、花了多久。
结论性的内容（怎么构建、怎么刷机、未知项的答案）在 `docs/alioth.md`，不要混进来。

格式：每条一个小节，标题是日期 + 在做什么。失败的尝试一样要留着 —— 它们是这份文档的主要价值。

---

## 2026-10-22 立项与计划

设备到手前的纸面工作。关键判断有三个：

1. **"移植 SteamOS"这个说法本身是错的** —— SteamOS 3 是 x86_64 的 Arch 衍生，没有公开 ARM64 镜像。能用的是 Valve 为 Steam Frame 发的官方 SteamOS ARM 镜像。
2. **pmOS 不是性能损耗层** —— 一开始想"去掉 pmOS 减少中间层"，这个前提不成立：pmOS 就是操作系统本身，没有运行时开销；distrobox 也是 namespace 不是 VM。真正有开销的只有 FEX 和 DXVK，都删不掉。换掉 pmOS 的真正理由是拿到 Valve 的真货 + 不用套 glibc 容器。
3. **上游已经有手机移植模板** —— `hashtagbasit/SteamOS-ARM-Port` 的 REDMAGIC 6（SM8350）移植和 alioth 的约束几乎一一对应：手机、无 SD 卡、原厂已解锁 bootloader、无 ABL、A/B 槽、无内置手柄、固件不可分发。这是整个项目最大的一个发现，把工作量从"研究"降到"适配"。

### 几个一开始没想到的坑（在真机之前就识别出来了）

- **`fastboot erase dtbo` 是必需的** —— ABL 会用 libufdt 把厂商 dtbo 覆盖到 DTB 上，这在 mainline DTB 上会炸。REDMAGIC 6 必须这么做。
- **DT 要加 `rotation = <270>`** —— 否则 Game Mode 会竖着跑。手机是竖屏面板，Steam 的 Deck UI 是横屏设计。
- **实验要刷 slot a 而不是 slot b** —— REDMAGIC 6 的配方用 slot b，因为它的 `current-slot` 是 a。alioth 的 `current-slot` 是 b，照抄就会擦掉唯一能开机的 Android。
- **模块 vermagic 不匹配会直接失去全部可见性** —— 调试 shell 起不来，而它是阶段 1 唯一的观测手段。
- **`boot_a`/`boot_b` 各 192MiB** —— 内核只要 30-50MiB，所以 A/B 内核回滚是免费的。
  （**这一条我改过两次**：原文写「bootloader 自带 `slot-retry-count:7` 自动回退」，
  审查后改成「这台机器没有自动回退」，2026-10-23 实测证明**自动回退存在**。
  三版结论和各自的依据见 docs/alioth.md 的
  「自动回退：存在，但不是退路」一节。
  A/B 回滚仍然是免费的，退路仍然是手动 `fastboot --set-active=b` —— 但理由
  是「自动回退会花掉启动尝试并弄坏好槽的标记」，不是「自动回退不存在」。）

### 自查抓到的自己的错误

写 spec 时把三处推断写成了断言（cmdline 的 `steamos.root=` 理由、ROCKNIX 基线是否开 PREEMPT/MGLRU/4K 页）。写计划时生成了两条语法能跑但什么也不检查的 `fdtget` 命令，还有一条 Review Focus 的"测试"其实只是一句注释。

教训：**看起来已经确定的事实不会有人再去验证**，所以把推断写成断言比留个空白更危险。

## 2026-10-22 Task 1：上游基线验证

### 计划里没写到的四个前提

读了上游 `kernel-common/build.sh` 和 `build-gcc15.sh` 之后才发现的：

1. **`build.sh` 读 `WORK`，不是 `STEAMOS_WORK`。** 后者是镜像脚本（`make-steamos-*.sh`、`apply-overlays.sh`）用的。我在计划里把两者搞混了。
2. **`build-gcc15.sh` 断言源码树必须在 `$MOUNT` 之下**（默认 `/work`），我们的树在 `~/Projects/` 里，不满足。
3. **ROCKNIX 检出不会自动 clone。** `build.sh:410` 直接 die，而且要求有 `.git` 元数据来校验固定 ref。
4. **busybox 的检查只验静态链接，不验架构。**

### 第 4 条是个静默失败，值得单独说

`build.sh:322`：

```sh
file "$bb" 2>/dev/null | grep -q "statically linked" \
  || die "need a static busybox (apt install busybox-static)"
```

在 x86_64 宿主上，`/bin/busybox` 如果是静态的，这条检查会**通过** —— 然后把一个 x86_64 二进制塞进 aarch64 的 initramfs。结果是设备黑屏、调试 shell 起不来。而调试 shell 是阶段 1 唯一的观测手段，所以我们会对着一个其实没问题的内核/DTS 反复排查。

这正是写计划时列在 Review Focus #4 的那个失效模式，只是触发点比预想的早得多 —— 我以为它会在打 boot image 时才出现，实际上在构建 initramfs 时就埋下了。

所以写了 `build-alioth-kernel.sh` 把这四条固化成每次构建都执行的断言，而不是靠记忆手敲环境变量。

### busybox 从哪来

busybox.net 的预编译二进制目录里**只有 i686 和 x86_64**，没有 aarch64。最后从 Alpine 的 aarch64 包取：
`https://dl-cdn.alpinelinux.org/alpine/v3.22/main/aarch64/busybox-static-1.37.0-r20.apk`，
解包后 `bin/busybox.static` 是 `ELF 64-bit LSB executable, ARM aarch64, statically linked`。

### 一个意外的提速

原计划要等 40GB 构建跑完、再 grep 生成的 `.config`，才能知道 4K 页（项目终止条件）满不满足。
但 ROCKNIX 稀疏克隆下来之后，基线配置 `projects/ROCKNIX/devices/SM8250/linux/linux.aarch64.conf`
就在本地了，直接 grep 即可。三项全 PASS，几秒钟而不是几小时。

写计划时我把"验证点"默认绑在了"构建产物"上，其实很多配置问题在**源码层面**就能回答。
下次写这类计划应该先问：这个断言真的需要构建产物吗？

## 2026-10-22 容器运行时：podman → docker

计划里写的是 `podman`，实际装的是 `docker`。改成自动探测（podman 优先，因为
上游默认 rootless，产物归属更干净），但过程中暴露了三件上游没管的事：

1. **`command -v docker` 不等于 docker 可用。** 服务没启动时这条检查照样通过，
   失败发生在 `build-gcc15.sh` 里 `docker run` 拉 Fedora 镜像的那一刻，错误
   信息跟真正的原因（`systemctl start docker`）离得很远。加成前提 5。
2. **`DOCKER='sudo docker'` 不生效。** 上游 `build-gcc15.sh:30` 写的是
   `exec "$DOCKER" run`，带引号，于是 shell 去找一个名叫 "sudo docker" 的
   二进制。解法是在 `$WORK/.shim` 放一个 `docker` 脚本并前置到 PATH，上游
   脚本一个字都不用改。
   
   没有选"把用户加进 docker 组"——那等于授予 root 等价权限，是用户自己的
   决定，而且要重新登录才生效，这个会话用不上。
3. **rootful docker 的产物归 root。** 容器里没有 `--user`，容器内 root 就是
   宿主 root。不 chown 回来，后面 `fdtget` / `ufs-bootimg.py` / `git add`
   全会失败。成败都 chown ——失败时的中间产物同样需要能读能删。加成前提 6。

## 2026-10-22 Task 1 Step 4/5：基线构建

一次通过，退出码 0。两个意外：

- **KERNEL 只有 16 MB**，spec 估的 30–50 MB 偏高。boot 分区 192 MiB，余量比
  预想的大得多，这让后面「把固件编进内核」的选项变得完全可行（见下）。
- **`find` 不穿越符号链接。** 计划 Step 5 的断言是
  `find "$WORK" -path '*output/current/boot/KERNEL'`，而 `current` 就是个指向
  `7.2.8-sm8250-steamos` 的符号链接 —— 这条断言**在任何情况下都不可能通过**。
  构建明明成功了，断言却报 FAIL。改用 `find -L`。

  教训与上次「把验证点绑在构建产物上」同源：写断言时想的是"找到那个文件"，
  写出来的却是"沿着这条路径走下去"，而中间有一节是链接。

## 2026-10-22 Task 2：DTS 前向移植，三处真实断裂

pmaports 的 patch 基线是 **6.19.6**，目标 7.2.8，跨 6.19 → 7.0 → 7.1 → 7.2
三个大版本。三个主要文件都是新增文件，没有冲突要解，但有三处实质问题。

### 1. `cpu7_opp21` label 撞车（编译期就炸）

alioth DTS 给 `&cpu7_opp_table` 加 SD870 的 3.1872 GHz boost 档，用的 label
是 `cpu7_opp21`。6.19.6 的 `sm8250.dtsi` 顶到 `cpu7_opp20`（2.8416 GHz），
label 是空的；7.2.8 期间上游补了 `cpu7_opp21: opp-3091200000`，于是撞车：

```
ERROR (duplicate_label): Duplicate label 'cpu7_opp21' on
  opp-3187200000 and opp-3091200000
```

改成 `cpu7_opp22`。没有任何地方引用这个 label，改名零成本。

这是**唯一一个编译期就暴露的**问题，也是最不危险的那个。

### 2. 五处 `firmware-name` 指向不存在的路径（静默失效）

pmaports 把五处固件路径写成 `qcom/sm8250/xiaomi/alioth/*`（pmOS 的固件包从
Android vendor 分区抽设备专属 blob 放那里），而本项目的固件 kit 一处都不提供。

其中 **GPU 的 zap shader 最要命**：加载不到它，Adreno 650 出不了 secure mode，
GPU 整个不可用 —— 而症状只是 dmesg 里一条 msm/adreno probe 失败。整个项目的
意义就建在这块 GPU 上。

本来想「删掉覆盖块、回退到 `sm8250.dtsi` 的默认值」，查了才发现
**7.2.8 的 `sm8250.dtsi` 全文件 0 处 `firmware-name`** —— 没有默认值可退，
设备 DTS 必须自己给。所以 zap 和 adsp 改路径，`&cdsp`/`&slpi`/`&venus`
三个节点整块删掉（照上游 ayaneo DTS 的做法，它一个都不带）。

### 3. 面板 `rotation` 是条死属性（静默失效，且会骗过断言）

计划 Task 2 要求「面板节点加 `rotation = <270>`」，Step 4 还有断言去验。
问题是 **pmaports 的面板驱动根本不读它** —— 没有 `.get_orientation` 回调，
probe 里也不调 `of_drm_get_panel_orientation()`。DT 里的属性不会传到
connector 的 `panel-orientation`，gamescope 无从知道要横屏。

所以这条断言会**通过**，而功能是坏的，要到阶段 2 跑起 Game Mode 才发现屏幕
是竖的。上游 patch 0009（AR18 面板）三样齐全：结构体字段、`.get_orientation`
回调、probe 里的 `of_drm_get_panel_orientation`。Task 3 照它补。

顺带发现计划 Step 4 的另一条断言也不对：它数整棵树里 `rotation` 的出现次数并
期望等于 1，但上游 alioth DTS 的三个摄像头 sensor 子节点本来各自就带一条
`rotation`，计数必然不是 1。改成按面板节点的 compatible 定位、断言 rotation
是它的直接属性。

### 固化成脚本

这三类问题的共同点是**编译期全都不报错**，症状离原因很远。所以写了
`scripts/assert-alioth-dtb.py`，六条断言一次跑完：DT model、根 compatible、
面板节点的 rotation、zap shader 的固件路径、没有残留的 `xiaomi/alioth/` 路径、
充电器已禁用。Task 6 是「改一处、重建、重刷、重采 dmesg」的循环，这些断言每轮
都要重跑，值得固化。

## 2026-10-22 阶段 1 的固件缺口（Task 5 的伏笔）

`soc.env` 里 `FW_BUILTIN=0`，上游注释解释得很清楚：
「like ROCKNIX, nothing is built in: the GPU microcode loads once the root is
mounted」。对阶段 2 完全正确。

但**阶段 1 只启到 initramfs**，而 initramfs 里只有 busybox 加三个脚本，
没有 `/lib/firmware`。于是 Task 6 的三项验收 —— A650 GPU 初始化、QCA6390
WiFi、BT —— 全部依赖一个阶段 1 根本不存在的 rootfs。不处理的话它们必然 FAIL，
而且极可能被当成 DTS 问题反复排查。

量了一下：GPU 三件固件共 **87 KB**，全套 42 MB（大头是别的机型的 blob：
ayn/thor 的 adsp 15 MB、ath11k 4 MB）。内核 16 MB → 约 58 MB，192 MiB 的
boot 分区装得下。所以阶段 1 的构建设 `FW_BUILTIN=1`。

注意 `build-gcc15.sh:27` 的 env 白名单里没有 `FW_BUILTIN`，不能用环境变量
覆盖，必须改 `soc.env`。

## Task 5：阶段 1 调试镜像

### 先翻参考仓库，再决定要不要用刷机换答案

计划把四件事列为「需要真机首次启动才能知道」：header v0 会不会被接受、要不要
`erase dtbo`、要不要禁 vbmeta、模块是否匹配。实际上前三件在
`pmaports-alioth` 里就有答案，而且是比试错更硬的证据：

- `Notes/uart_logs/` 是**这台机器 bootloader 自己的输出**。vbmeta 未签名
  （`OK_NOT_SIGNED`）照样启动、dtbo 擦除后（`magic mismatch 0`）照样启动、
  按 `board-id 0x2C` 匹配追加的 DTB —— 三条全在日志里。
- `deviceinfo` 没有 `bootimg_header_version` 而 `generate_bootimg="true"`，
  所以 pmOS 产出的就是 header v0，而它起得来。

教训：那个仓库之前只被当成「驱动和 DTS 的来源」。它同时是一份**这台机器
bootloader 的行为记录**，而且早就在本地克隆里了。在用刷机周期换信息之前，
先把手上已有的材料读完。

净收益：刷机配方从 REDMAGIC 6 模板的四次写入降到两次（`erase dtbo_a` +
`flash boot_a`），`vbmeta` 和 `vendor_boot` 都不碰。

### 容器环境变量白名单会静默吞掉变量

`build-gcc15.sh:27` 的 `env_args` 只转发一个固定列表：

```
SM8550_RECIPE SM8650_RECIPE WORK ROCKNIX_DIR JOBS OUT_BASE LOCALVERSION
DTBS_OVERRIDE INITRAMFS_HOTFIX CROSS_COMPILE FRAME_FW_DIR
```

`FW_BUILTIN`、`CMDLINE_QUIET`、`KERNEL_CMDLINE_EXTRA`、`KEEP_IMAGE` **都不在里面**。
在宿主上 `export` 它们再调用构建脚本，不会报错，只是不生效 —— 而我先前为 Task 5
记的三条 ruling 全依赖这几个变量。

分工因此改了：只有 `KEEP_IMAGE=1` 需要写进 `kernel-sm8250/soc.env`（容器内 source）；
cmdline 的两个变量根本不用过容器边界，因为 `make-steamos-alioth.sh` 是在宿主上
用自己的参数重新打包的。

### 推翻 `FW_BUILTIN=1`

先前的 ruling 要把固件编进内核，理由是阶段 1 没有 rootfs。重新看之后撤回：

1. `FW_BUILTIN` 在 `soc.env` 里是 **SoC 级**的，翻成 1 会让同一份 kit 里另外
   10 台 retroid / AYN 设备的内核也从 16MB 涨到 43MB。而 kit 自己的 sm8350 笔记
   记着有个 ABL 拒绝了 47MB 的 Image —— 为一个调试镜像承担这个波及面不值得。
2. 更关键：阶段 1 **不需要** GPU 固件。所有 GPU 固件加载（`adreno_load_fw`、
   `ucode_load`、zap shader）都在 `adreno_load_gpu()` 里，而它只从
   `load_gpu()`（`msm_drv.c:206`）被调用 —— 那是用户态**首次 open DRM 设备**时的
   惰性路径，不是 component 绑定路径。失败只是 `priv->gpu` 留空，DRM 设备本身
   照样活着，显示和控制台不受影响。

这一条值得记下来，因为 `add_gpu_components()` 确实把 GPU 加成 msm DRM 的**必需**
component，所以「GPU 出问题会不会连带把显示搞死」是个合理的担心 —— 答案取决于
固件是在绑定时还是首次使用时加载，而那只能去读代码。

### `SPI_QCOM_GENI=m`：计划那份配置清单的漏项

计划列了 8 项阶段 1 配置覆盖。逐条对照基线 `.config` 时发现第 9 项：触摸屏挂在
`qcom,geni-spi`（`&spi4`）上，而 `CONFIG_SPI_QCOM_GENI=m`。编进内核的触摸驱动
配一个模块化的总线控制器，等于没有触摸 —— 而这个失败在阶段 1 看起来就是
「触摸没反应」，和「驱动没加载」长得一模一样。

同时发现 `U_SERIAL_CONSOLE` 在基线 `.config` 里**压根没出现**（不是 `is not set`）。
它依赖 `USB_U_SERIAL`，而后者由 `USB_CONFIGFS_ACM` selects；不先开 ACM，这个符号
不会被 offer。只 grep `is not set` 会漏掉这类符号。

### 撤回 `fbcon=rotate:1`

计划的 Global Constraints 里 cmdline 带 `fbcon=rotate:1`。写进去之后撤回：Task 3
刚给面板驱动加了 `.get_orientation`，DRM 现在会拿到 `panel_orientation=270`，
而 DRM 的 fbdev 模拟本身就会据此旋转控制台。再叠一层 `fbcon=rotate` 就是复合
旋转，最终朝向无法离机确定。阶段 1 只需要**能读到**启动日志，手机竖着拿就行；
横屏是 Game Mode（阶段 2）的要求。在唯一依赖的观测通道上做没法验证的猜测，
赔率不对。

### simpledrm 的地址必须带 `no-map`

原厂 `cont_splash_region@9c000000`（`reg = <0x00 0x9c000000 0x00 0x2300000>`）是裸
`reg`，没有 `no-map`。kit 里 REDMAGIC 6 的补丁更干脆 —— 它给 `framebuffer@e1000000`
**压根没加**预留节点。两种都不照抄：

- 不预留：内核会把同一段内存分给别人，而 simplefb 直接往里写，表现是随机内存
  损坏，和「屏幕没输出」完全不像同一个 bug。
- 预留但不 `no-map`：这段内存同时在 cacheable 线性映射里，而 simplefb 自己
  `ioremap_wc()`，在 arm64 上是属性不匹配。

断言脚本里因此加的不是格式检查，而是**包含关系**：必须存在一个 `no-map` 的
reserved-memory 节点，把 framebuffer 的 `[base, base+size)` 完整盖住。现有预留
最高到 `0x92700000`，所以 `0x9c000000` 确实是空的。

ramoops 仍然不加：原厂 DTS 没有对应区域（Qualcomm 用 `mem_dump`/minidump），
而看起来空闲的地址要么是固件的，要么像 `cont_splash_region` 的其余部分一样
会被 bootloader 每次启动重写 —— 那恰恰是崩溃日志必须能活过的东西。

### 断言脚本自己的两个 bug

1. 「写操作只针对目标槽」那条用 `grep -nE '^[[:space:]]*fastboot ...'`，结果命中了
   `flash-alioth.sh` 里**拒绝提示和救砖说明**中的 `fastboot --set-active=b` ——
   那些在 heredoc 里，是给人看的文本，不是会跑的命令。改成按 heredoc 标记先把
   文本段剔掉再找命令。又一次：用正则猜「哪些行会执行」不可靠。
2. `gzip.decompressobj` 不存在（是 `zlib.decompressobj(31)`）。

### 用桩验证唯一能变砖的那段逻辑

`flash-alioth.sh` 的槽位检查不能只靠读代码确认。放一个假的 `fastboot` 到 PATH
最前面，实测三种情形：

| 情形 | 结果 |
|---|---|
| `current-slot: a`（= 目标槽） | 拒绝，`EXIT=1`，**0 条写操作** |
| `current-slot: b`，不输入 YES | `EXIT=1`，**0 条写操作** |
| `current-slot: b`，输入 YES | 恰好 4 条：`erase dtbo_a` / `flash boot_a` / `--set-active=a` / `reboot` |
| `--boot` 模式 | 只有 `boot <img>`，零写入 |

脚本的规则比计划更严一点：它**只写 slot a**，并且在 slot a 已是活动槽时拒绝。
计划的 Global Constraints 同时要求「不写活动槽」和「不写 slot b 的任何分区」；
只做「不写活动槽」的运行时检查，在活动槽曾被切到 a 的情况下会去写 b，与后一条
冲突。固定目标为 a 同时满足两条，代价是测试过一次之后要先
`fastboot --set-active=b` 再重刷。


## 2026-10-23 第一次真机：三个发现，其中一个是我自己造的

Task 5 Step 7。手机进 fastboot，只读检查全过（`product:alioth`、`unlocked:yes`、
`current-slot:b`），38 条断言全过，然后跑 `./flash-alioth.sh --boot`。

### 1. `fastboot boot` 的 `OKAY` 什么也不保证

主机侧输出漂亮得有误导性：

```
Sending 'boot.img' (14440 KB)   OKAY [  0.348s]
Booting                         OKAY [  0.774s]
Finished. Total time: 1.128s
```

屏幕上什么都没有。真相在主机的 USB 上：

```
05:45:02  usb 1-3.4: new high-speed USB device number 9    ← 进 fastboot
（05:45–05:48 一次 disconnect 都没有）                      ← fastboot boot 就在这段里
```

跳进内核意味着 bootloader 放弃 USB 控制器，主机一定会看到 disconnect。**没有
disconnect，就是没跳。** 而 `fastboot devices` 期间一直能列出设备、`getvar` 一直
能应答 —— ABL 应答了 `OKAY`，然后留在 fastboot 命令循环里。

fastboot 协议里 `boot` 的 `OKAY` 是**跳之前**发的，所以它从来不是「启动成功」的
证据。这一点在设计 `--boot` 模式时我没想到，脚本的提示语里也就没有写。

对照证据：`pmaports-alioth` 整个仓库里 `fastboot boot` **一次都没出现过**，它的
安装指引只有 `erase dtbo_b` + `flash boot_b` + `set_active b` + `reboot`。那条路
是被证明过的，`--boot` 这条不是。

### 2. 我设计的「零风险探针」不是零风险

为了判定那个 `OKAY` 有没有意义，我做了个镜像，把 `ANDROID!` 魔数打坏，想法是
「ABL 在解析头部时就会拒绝，绝不可能跳进去执行」。

漏掉的是**主机侧**那一层。`fastboot boot <file>` 看到文件没有 boot 魔数，不会报错
退出，而是把它当**裸内核**，用主机默认参数（page size 2048、默认载入地址）自己套
一个合法的 boot 头重新打包。输出里那行 `creating boot image - 14788608 bytes` 就是
证据 —— 比原文件大了 2048 字节。

所以 ABL 收到的是一个**结构完全合法、内核是垃圾**的镜像。它跳了进去：

```
Booting   FAILED (Status read failed (No such device))
[Fri Oct 23 05:48:07 2026] usb 1-3.4: USB disconnect, device number 9
```

`No such device` 是设备在应答之前就从 USB 上消失了 —— 这次是真跳了，然后崩了。

教训不是「别做探针」，是**探针的风险要算到工具链的每一层**。我只分析了 ABL 会怎么
处理这个文件，没分析 `fastboot` 这个主机程序会怎么处理它。一个声称「不可能执行」
的测试，执行了。

### 3. 自动回退存在 —— 推翻前一天那条 Critical 结论

崩溃之后手机进了循环：亮 Redmi 标志、黑屏、重复。强制断电 + 音量下 + 电源进
fastboot，读变量：

```
current-slot:a          ← 事发前我亲手读到的是 b
slot-unbootable:b:yes
slot-retry-count:a:7
slot-retry-count:b:4
```

`fastboot --set-active` 从头到尾没运行过，分区一个字节都没写过。**是 bootloader
自己把 b 标成不可启动并切到了 a。** 同一次读取里 a:7 对 b:4，说明 b 这边确实在
按失败次数记账。

这直接推翻了前一天独立审查的第一条 Critical 发现 —— 那条是我论证的，依据是 UART
日志里每次都打 `A/B retry count NOT decremented` 加上 retry 计数停在 7。错在两处：
用一行日志的否定式去证明一个机制**不存在**，是拿不完全的证据下完全的结论；而那份
`getvar` 抓取来自 pmaports 仓库里**另一台**机器（序列号与本机不同），
我当成本机基线用了。

循环的来源也清楚了：b 被标 unbootable 之后，bootloader 切到 slot a，而 slot a 里
是起不来的旧 Android。`fastboot --set-active=b` 一条命令就回到了 Android ——
slot b 的**内容**从来没坏过，坏的是它的标记。

### 这三件事改了什么

- 脚本和文档里所有「这台机器不会自己回退」「干等没有用」的说法全部改掉，换成
  「会自己回退，但它会花掉启动尝试、落到另一个槽的旧系统上、并且弄坏被放弃那个
  槽的标记，所以直接手动切回去」。
- 断言第 10 条反向重写，并且拆成两条：不许把「等自动回退」当退路（旧问题），
  也不许宣称「自动回退不存在」（新问题，就是我写进去的那句）。两条都用变异体
  验证过能抓住。
- `--boot` 模式的定位变了：它不是「更安全的先试一下」，而是**一条在这台机器上
  走不通的路**。ABL 应答 `OKAY` 然后不跳，所以它连「不确定」都给不出来。
  真机验证只剩 `--test`（也就是 pmaports 证明过的 flash 路径）。

## 2026-10-23 内核起来了，然后发现我埋了两个空配置

真机日志最后一行是 `Warning: unable to open an initial console.`，顺着它查出两件
性质相同的事：**我加了配置，但没有人去用它**。编译期不报错，断言也查不到，只有
真机才会暴露。

### 空配置 1：`CONFIG_U_SERIAL_CONSOLE=y` 自己什么也不做

我在 Task 5 把它加进 `steamos.config`，注释写的是「ACM 打开后才被 offer」，言下之
意是打开 ACM 就有控制台。实际上这个选项只让内核**多出一个 configfs 属性**：

```
drivers/usb/gadget/function/f_acm.c:805
    f_acm_console_store() -> gserial_set_console()
    CONFIGFS_ATTR(f_acm_, console);
```

必须有人 `echo 1 > $g/functions/acm.usb0/console`，控制台才会挂到 ttyGS0 上。
`initramfs/init` 从来没写过这一句，所以主机那端 `/dev/ttyACM0` 一个字节都收不到 ——
而这正是「拿到可复制的日志」唯一的通道。已补，写在 UDC 绑定之前（绑定后 gserial
会拒绝）。

### 空配置 2：init 的 stdio 根本没连到任何地方

cpio 里没有 `/dev/console` 节点，内核在 `init/main.c:1625` 打
`Warning: unable to open an initial console.` 然后照样执行 init —— PID 1 拿到的
stdio 是无效的。于是 `init` 里**所有** `echo` 都消失在空气里。

这件事的讽刺之处：我前一刻刚把 `usb_shell` 里网络那段的 `2>/dev/null` 全删掉，加了
三条失败时的 `echo` 诊断 —— 而它们一条都不会显示。修法是在
`mount -t devtmpfs dev /dev` 之后立刻 `exec </dev/console >/dev/console 2>&1`。

两条合起来的教训是同一条：**「配置打开了」和「功能生效了」之间还有一步**，而那一步
在内核配置里看不见。这类东西离机验证不了，只能靠真机和一条明确的观测通道 ——
所以第一件事永远是把观测通道做扎实。

### 差点被一条 sed 改掉的相机

屏幕方向反了 180 度，要把面板的 `rotation = <270>` 改成 `<90>`。DTS 里 `rotation`
有四处，我本来准备全改。查了一下，另外三处是摄像头 sensor 节点
（`cam_imx582` / `s5k5e9` / `imx355`）的安装旋转。

断言脚本当初按 `compatible` 定位面板节点、而不是按出现次数计数，这次正好兜住了 ——
`EXPECT_ROTATION` 从 270 改成 90 时，它准确地只检查面板那一处。写那条断言时的理由
是「整棵树里 grep rotation 会命中摄像头 sensor」，当时只是为了避免假阳性，没想到
真正的价值是避免一次误改。

### 一个旧 ruling 的半句话被证伪

`FW_BUILTIN=0` 的理由里写了「GPU 固件在 `adreno_load_gpu()` 里惰性加载，用户态首次
open DRM 才触发」。真机日志显示 `adreno_request_fw` 在 `msm_dpu` bind 阶段（1.26s）
就跑了。结论（缺固件不影响显示）被同一份日志证实，但推导过程是错的 —— 我从
`msm_drv.c:206` 读到 `load_gpu()` 在用户态 open 时调用，就认定那是唯一路径。

## 2026-10-23 触摸：四项排除之后，缺陷在参考实现里

`Chip ID mismatch: expected 0x5652, got 0xefef`。排查顺序是先把"我们改坏了"的可能
一条条砍掉：

| 怀疑 | 怎么排除的 |
|---|---|
| DTS 写错 | 触摸节点与 pmaports 原版**逐字相同**；厂商 LineageOS DTS 里的 focaltech 节点 irq 39 / reset 33 / 6 MHz 也完全一致 |
| 前向移植改坏了驱动 | 从 pmaports 的 patch 里抽出原版 `ft8756.c` 逐行 diff，635 行里唯一差异是我加的 `of_match_table` |
| 上电/时序竞态 | 原始启动时读 ID 在 1.228s、早于 msm DRM 初始化（1.341s）；但系统空闲 403 秒、显示完全起来后手工 `echo spi4.0 > .../ft8756-spi/bind` 重试，读到**完全相同**的两个值 |
| 总线或协议故障 | 驱动在状态字节异常时打 `Failed to read data status`、CRC 不符时打 `crc error`，两条都没出现 —— 芯片按协议应答了，CRC 都对得上 |

认错芯片也排除了：alioth 出厂有 FocalTech 和 Novatek 两种触摸（厂商 DTS 里两个节点
都 `status = "ok"`，靠探测决定）。但 Novatek 芯片按 FocalTech 协议答不出正确 CRC，
而且 vendor cmdline 里的 `k11a_38_08_0a` 对应 display-maker `'8'`，Novatek 那套配置
写的是 `<0x37>` = `'7'`。

### 真正的原因

```c
u8 *txBuf = devm_kzalloc(dev, 4, GFP_KERNEL);   /* 4 字节 */
...
dp    = txlen + 3;            /* 7 */
txlen = dp + val_size;        /* 8 */
if (txBuf[1] & DATA_CRC_EN)
        txlen += 2;           /* 10 */
struct spi_transfer xfer = { .tx_buf = txBuf, .len = txlen };
```

读 1 字节时控制器要发 10 字节，缓冲区只有 4 字节 —— 后 6 字节是相邻的堆内存。

这个 bug 之所以能活到现在，是因为**它不会让任何一层报错**：前 4 个命令字节是对的，
芯片收到合法命令并正常应答，而状态字节和 CRC 都是芯片对**自己发出的数据**算的，与
主机发了什么垃圾无关。于是整条校验链全部通过，驱动的行为却悄悄取决于分配器剩下的
内容 —— 6.15.1 和 7.2.8 的 slab 布局不同，一个读得对，一个读到 `0xef`。

### 这次排查里真正起作用的是什么

不是读代码，是**那四项排除把范围压到了"参考实现本身"**。在那之前我已经写出两个
假设（触摸变体不同、lab 供电缺失），两个都站得住、都讲得通，但都没有证据。手工
rebind 那一步是转折：它把"时序"整类假设一次性砍掉，而且只花了十几秒 —— 因为手机还
连着串口 shell。**把观测通道做扎实，比任何单个假设都值钱。**

### 顺带记下但这次不改

`ft8756_spi_read` 每次调用都 `devm_kzalloc` 两个缓冲区，而 devm 的释放要等到设备
unbind。触摸一旦工作，每个上报事件漏约 20 字节。这是独立缺陷，等触摸能用了单独修 ——
现在一起改会让这次实验说不清是哪一条起的作用。

