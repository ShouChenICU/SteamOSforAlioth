# alioth 阶段 1：内核移植与启动验证 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 Xiaomi alioth 用 ROCKNIX 7.2.8 内核启动到上游的 USB 调试 shell，并在此过程中收口 spec §9 中全部 7 项待验证未知。

**Architecture:** fork `hashtagbasit/SteamOS-ARM-Port`，在其 `kernel-sm8250` 配方（ROCKNIX 7.2.8）里加入 alioth 的 DTS、面板驱动与触摸驱动，用上游共享的 `mkbootimg-v0.py` 打成 Android boot image，经小米原厂 bootloader 刷入**非活动槽 slot a**。不触碰 ABL、不触碰 `userdata`、不触碰 Android 所在的 slot b。阶段 1 不需要 Valve rootfs。

**Tech Stack:** Linux 7.2.8 (ROCKNIX SM8250 基线)、arm64 DTS、DRM panel driver (MIPI DSI 命令模式)、I2C 触摸驱动、Android boot image header v0、fastboot、容器化 GCC（`build-gcc15.sh`）

**Spec:** `docs/superpowers/specs/2026-10-22-steamos-alioth-port-design.md`

## Global Constraints

- 内核基线：ROCKNIX `ROCKNIX_REF=20261001`，`KVER=7.2.8`，`SOC=sm8250`，`ROCKNIX_DEVICE=SM8250`，platform `kona`
- DTB 名称一律 `sm8250-xiaomi-alioth`；DT `model` 字符串一律 `"Xiaomi Poco F3"`（阶段 2 的 overlay 与 InputPlumber 靠它匹配）
- 新增内核配置仅两行：`CONFIG_DRM_PANEL_SAMSUNG_AMS667XX01=m`、`CONFIG_TOUCHSCREEN_FT8756=m`
- boot image 优先 header **v0**（`mkbootimg-v0.py`，`EMBED_INITRAMFS=1`，DTB 附加在内核镜像后）；v0 被 bootloader 拒绝才切 `mkbootimg-v3.py` + `vendor_boot`
- cmdline：`steamos.root=PARTLABEL=userdata` + sm8250 的 `CMDLINE_SOC`（`usbcore.interrupt_interval_override=045e:028e:2 mem_sleep_default=s2idle fw_devlink.sync_state=timeout`）
- **4K 页是 FEX 的硬性前提**：`CONFIG_ARM64_4K_PAGES=y` 必须成立，否则整个方案终止
- 设备事实：`current-slot:b`、`slot-count:2`、`unlocked:yes`、`boot_a`/`boot_b` 各 192 MiB、`max-download-size` 768 MiB
- **阶段 1 禁止写入的分区**：`userdata`、`super`、`abl_a`、`abl_b`、以及 slot b 的任何分区
- **阶段 1 禁止做 A/B successful 标记**（保留 bootloader 的 `slot-retry-count:7` 自动回退）
- 失败退路始终是 `fastboot --set-active=b`
- 面板必须提供 120Hz（`DRM_MODE_TYPE_PREFERRED`）、90Hz、60Hz 三个模式
- DTS 必须含 `rotation = <270>`

## Review Focus

spec 隐含但没有任务天然覆盖的失效模式，按"最可能咬人"排序。每条都已在下面对应任务里加了验证步骤：

1. **刷机脚本把镜像写进活动槽** → 擦掉唯一能开机的 Android，失去全部退路。脚本必须运行时读 `fastboot getvar current-slot` 并拒绝写入活动槽（Task 5）
2. **`--test` 模式含有写 `userdata`/`abl` 的代码路径** → 一次手滑或一个参数解析 bug 就毁掉设备。需要静态断言脚本文本中不出现这些分区名（Task 5）
3. **面板驱动的 `compatible` 与 DTS 不一致** → 面板不亮，且 `dmesg` 里没有明显报错（静默失败），极难定位。需要交叉断言两边字符串相同（Task 3）
4. **内核模块版本/路径与 initramfs 不匹配** → 调试 shell 起不来，直接失去全部可见性，而这正是阶段 1 唯一的观测手段（Task 5）
5. **DT `model` 字符串写错** → 阶段 1 看不出任何问题，到阶段 2 overlay 匹配失败时才暴露，届时已很难联想到根因（Task 2）

---

## File Structure

```
新建
  external-and-mods/kernel-sm8250/dts/sm8250-xiaomi-alioth.dts
      alioth 设备树。从 nasaarmas patch 提取，加 rotation，剥离 modem/sensor
  external-and-mods/kernel-sm8250/patches/0017-drm-panel-add-samsung-ams667xx01.patch
      面板驱动（120/90/60Hz 命令模式），对照 patch 0009 的 AR18 驱动前向移植
  external-and-mods/kernel-sm8250/patches/0018-input-add-focaltech-ft8756.patch
      I2C 触摸驱动，对照 patch 0010 的 ST7123 驱动前向移植
  make-steamos-alioth.sh
      阶段 1 只实现 --kernel-only：打 boot-debug.img
  flash-alioth.sh
      只实现 --test：刷非活动槽，含槽位安全检查
  docs/alioth.md
      构建、刷机、调试说明；7 个未知项的实测结论记录在此

修改
  external-and-mods/kernel-sm8250/soc.env            DTBS 追加 sm8250-xiaomi-alioth
  external-and-mods/kernel-sm8250/steamos.config     追加 2 个 CONFIG
```

---

### Task 1: fork 落地与上游基线验证

先证明**在引入任何 alioth 变量之前**上游的构建流水线在本机能跑通，并顺便用生成的 `.config` 收口两个无需真机的未知项（4K 页、PREEMPT/MGLRU）。

**Files:**
- Modify: `.git/config`（加 upstream remote）
- Create: `docs/alioth.md`

**Interfaces:**
- Consumes: 无
- Produces: 内核输出目录（`*/output/current/`，实际路径由 Step 5 的 `find` 发现并记入 `docs/alioth.md`）；`docs/alioth.md` 的"未知项结论"小节

- [ ] **Step 1: 确认前置工具与磁盘**

Run:
```bash
for t in git curl fastboot podman 7z fdtget; do command -v $t >/dev/null && echo "ok $t" || echo "MISSING $t"; done
df -h /home/shouchen | tail -1
```
Expected: 无 `MISSING`（`fdtget` 来自 `dtc` 包，`fastboot` 来自 `android-tools`）；可用空间 ≥ 40 GiB

- [ ] **Step 2: 接入上游**

Run:
```bash
cd /home/shouchen/Projects/SteamOSforAlioth
git remote add upstream https://github.com/hashtagbasit/SteamOS-ARM-Port.git
git fetch upstream
git merge --allow-unrelated-histories upstream/main -m "merge: 接入 SteamOS-ARM-Port 上游"
```
Expected: 合并成功，`docs/superpowers/` 与上游文件并存

- [ ] **Step 3: 写下基线断言（先验证它会失败）**

Run:
```bash
export STEAMOS_WORK=/home/shouchen/Projects/SteamOSforAlioth/work
find "$STEAMOS_WORK" -path '*output/current/boot/KERNEL' | grep -q . && echo PASS || echo FAIL
```
Expected: `FAIL` —— 还没构建

上游文档对输出目录有两种说法（`kernel-work/output/<release>/` 或 `$WORK/output/<release>/`），所以全计划统一用 `find` 发现，不硬编码。

- [ ] **Step 4: 构建未修改的 sm8250 内核**

Run:
```bash
export STEAMOS_WORK=/home/shouchen/Projects/SteamOSforAlioth/work
bash external-and-mods/kernel-common/build-gcc15.sh sm8250
```
构建失败且原因与工具链/容器相关时，先修环境再重跑；此时**不要**改任何上游文件 —— 本任务的全部价值在于确认"未改动的上游能构建"。

- [ ] **Step 5: 基线断言转为通过**

Run:
```bash
export STEAMOS_WORK=/home/shouchen/Projects/SteamOSforAlioth/work
KERNEL=$(find "$STEAMOS_WORK" -path '*output/current/boot/KERNEL' | head -1)
test -n "$KERNEL" && echo "KERNEL ok: $KERNEL"
python3 external-and-mods/ufs-install/ufs-bootimg.py info "$KERNEL"
```
Expected: `KERNEL ok`；`info` 输出 header v0 且 page size 为 2048 或 4096

把发现到的输出目录记入 `docs/alioth.md`，后续任务直接引用。

- [ ] **Step 6: 收口未知项 —— 4K 页与 PREEMPT/MGLRU**

Run（`.config` 路径由构建输出决定，必要时 `find $STEAMOS_WORK -name .config`）：
```bash
C=$(find "$STEAMOS_WORK" -name .config -path '*linux*' | head -1)
grep -E '^CONFIG_ARM64_4K_PAGES=y' "$C" && echo "4K PASS" || echo "4K FAIL — 方案终止条件"
grep -E '^CONFIG_PREEMPT(_FULL|_DYNAMIC)?=y' "$C" || echo "PREEMPT 未开 — 需加入 steamos.config"
grep -E '^CONFIG_LRU_GEN=y' "$C" || echo "MGLRU 未开 — 需加入 steamos.config"
```
Expected: `4K PASS`。`CONFIG_ARM64_4K_PAGES` 不为 `y` 时**停止整个项目并报告** —— FEX 无法在非 4K 页内核上运行。

`PREEMPT` 或 `LRU_GEN` 未开时，把缺的项追加到 `external-and-mods/kernel-sm8250/steamos.config`（这是对 Global Constraints 中"仅两行"的唯一允许的扩充，且必须在 `docs/alioth.md` 记录原因）。

- [ ] **Step 7: 记录结论并提交**

把 Step 6 的实测结果写入 `docs/alioth.md` 的"未知项结论"小节（每项一行：项、结论、依据命令）。

```bash
git add docs/alioth.md external-and-mods/kernel-sm8250/steamos.config
git commit -m "chore: 接入上游并验证 sm8250 基线构建；收口页大小与调度配置"
```

---

### Task 2: alioth DTS

**Files:**
- Create: `external-and-mods/kernel-sm8250/dts/sm8250-xiaomi-alioth.dts`
- Modify: `external-and-mods/kernel-sm8250/soc.env`（`DTBS` 行末追加 ` sm8250-xiaomi-alioth`）

**Interfaces:**
- Consumes: Task 1 的构建流水线
- Produces: DTB `sm8250-xiaomi-alioth.dtb`；DT `model = "Xiaomi Poco F3"`；面板节点 `compatible` 字符串（Task 3 必须与之一致）；触摸节点 `compatible`（Task 4 必须与之一致）

- [ ] **Step 1: 写下 DTS 断言（先验证失败）**

Run:
```bash
D=$(find work -name 'sm8250-xiaomi-alioth.dtb' | head -1)
test -n "$D" && echo PASS || echo FAIL
```
Expected: `FAIL`

- [ ] **Step 2: 提取并改写 DTS**

从 `nasaarmas/pmaports-alioth` 的 `linux-postmarketos-qcom-sm8250-alioth/0001-Added-POCO-F3-dts-panel-and-touchscreen-drivers.patch` 中取出 `arch/arm64/boot/dts/qcom/sm8250-xiaomi-alioth.dts` 全文，放到 `external-and-mods/kernel-sm8250/dts/`，并做三处改动：

1. 根节点加 `model = "Xiaomi Poco F3";`（若原文不同，改成这个 —— Review Focus #5）
2. 面板节点加 `rotation = <270>;`
3. 删除 modem / sensor / `hexagonrpcd` 相关节点

结构上对照 `external-and-mods/kernel-sm8250/dts/sm8250-ayaneo-pocketmicro2.dts`，确认 include 的平台 dtsi 路径与节点 label 在 7.2.8 下成立。

- [ ] **Step 3: 注册到 soc.env 并构建**

Run:
```bash
export STEAMOS_WORK=/home/shouchen/Projects/SteamOSforAlioth/work
bash external-and-mods/kernel-common/build-gcc15.sh sm8250
```
Expected: 构建成功，无 dtc 报错

- [ ] **Step 4: DTS 断言转为通过 + Review Focus #5**

Run:
```bash
D=$(find work -name 'sm8250-xiaomi-alioth.dtb' | head -1); echo "$D"
test "$(fdtget "$D" / model)" = "Xiaomi Poco F3" && echo "model PASS" || echo "model FAIL"
fdtget "$D" / compatible
```
Expected: `model PASS`；`compatible` 含 `xiaomi,alioth` 与 `qcom,sm8250`

`rotation` 属性断言 —— 反编译回 DTS 后确认它挂在面板节点上，而不是只在字符串表里出现：
```bash
dtc -I dtb -O dts "$D" 2>/dev/null | grep -B20 'rotation *= *<0x10e>\|rotation *= *<270>' \
  | grep -E 'panel|dsi' | tail -3
dtc -I dtb -O dts "$D" 2>/dev/null | grep -cE 'rotation *= *<(0x10e|270)>'
```
Expected: 上一条打印出面板/DSI 节点名，下一条输出 `1`（dtc 把 270 显示为 0x10e）

- [ ] **Step 5: 提交**

```bash
git add external-and-mods/kernel-sm8250/dts/sm8250-xiaomi-alioth.dts external-and-mods/kernel-sm8250/soc.env
git commit -m "feat(dts): 加入 sm8250-xiaomi-alioth 设备树（含 rotation=270）"
```

---

### Task 3: 面板驱动前向移植（Samsung AMS667XX01）

对照 `external-and-mods/kernel-sm8250/patches/0009-drm-panel-add-the-ayaneo-ar18-panel.patch` —— 它是**针对同一内核版本、同一 SoC** 的 DSI 面板驱动，用它确定 7.2.8 下 `drm_panel_funcs` 签名、`mipi_dsi_multi_*` 辅助函数与面板分配方式的正确形状。不要靠逐个编译错误猜 API。

**Files:**
- Create: `external-and-mods/kernel-sm8250/patches/0017-drm-panel-add-samsung-ams667xx01.patch`
- Modify: `external-and-mods/kernel-sm8250/steamos.config`（追加 `CONFIG_DRM_PANEL_SAMSUNG_AMS667XX01=m`）

**Interfaces:**
- Consumes: Task 2 的 DTS 面板节点 `compatible`
- Produces: 内核模块 `panel-samsung-ams667xx01.ko`，`compatible` 与 DTS 一致；三个显示模式 120/90/60Hz

- [ ] **Step 1: 写下模块断言（先验证失败）**

Run:
```bash
find work -name 'panel-samsung-ams667xx01.ko*' | grep -q . && echo PASS || echo FAIL
```
Expected: `FAIL`

- [ ] **Step 2: 移植驱动并生成 patch**

把 nasaarmas 的 `drivers/gpu/drm/panel/panel-samsung-ams667xx01.c` 连同 `Kconfig` / `Makefile` 改动移植到 7.2.8，形状对照 AR18 驱动。保留 `alioth_modes[]` 的三个模式：120Hz 带 `DRM_MODE_TYPE_DRIVER | DRM_MODE_TYPE_PREFERRED`，另有 90Hz 与 60Hz，以及驱动内按 `drm_mode_vrefresh()` 分支的 DDIC 初始化序列。

产物保存为 `patches/0017-drm-panel-add-samsung-ams667xx01.patch`，命名与编号延续上游 0001–0016。

- [ ] **Step 3: 构建**

Run: `STEAMOS_WORK=$PWD/work bash external-and-mods/kernel-common/build-gcc15.sh sm8250`
Expected: 构建成功；`build.sh` 不报告被 Kconfig 拒绝的 CONFIG

- [ ] **Step 4: 模块断言转为通过 + Review Focus #3（compatible 交叉断言）**

Run:
```bash
KO=$(find work -name 'panel-samsung-ams667xx01.ko*' | head -1); echo "$KO"
D=$(find work -name 'sm8250-xiaomi-alioth.dtb' | head -1)
# 驱动声明的 compatible 必须出现在 DTB 里
for c in $(modinfo -F alias "$KO" | sed -n 's/^of:N\*T\*C//p' | tr -d '*'); do
  strings "$D" | grep -qx "$c" && echo "compatible 匹配: $c" || echo "compatible 不匹配: $c"
done
```
Expected: 至少一条 `compatible 匹配:`，无 `不匹配`

同时断言三个显示模式都在（每个模式各有一条 `.clock =`）：
```bash
test "$(grep -cE '^\+.*\.clock *=' external-and-mods/kernel-sm8250/patches/0017-*.patch)" -eq 3 \
  && echo "三模式 PASS" || echo "三模式 FAIL"
grep -cE '^\+.*DRM_MODE_TYPE_PREFERRED' external-and-mods/kernel-sm8250/patches/0017-*.patch
```
Expected: `三模式 PASS`；`DRM_MODE_TYPE_PREFERRED` 恰好 `1` 处（只有 120Hz 带它）

- [ ] **Step 5: 提交**

```bash
git add external-and-mods/kernel-sm8250/patches/0017-*.patch external-and-mods/kernel-sm8250/steamos.config
git commit -m "feat(panel): 前向移植 Samsung AMS667XX01 面板驱动到 7.2.8"
```

---

### Task 4: 触摸驱动前向移植（FocalTech FT8756）

对照 `external-and-mods/kernel-sm8250/patches/0010-input-add-the-sitronix-st7123-touchscreen.patch` —— 同内核版本、同 SoC 的 I2C 触摸驱动。

**Files:**
- Create: `external-and-mods/kernel-sm8250/patches/0018-input-add-focaltech-ft8756.patch`
- Modify: `external-and-mods/kernel-sm8250/steamos.config`（追加 `CONFIG_TOUCHSCREEN_FT8756=m`）

**Interfaces:**
- Consumes: Task 2 的 DTS 触摸节点 `compatible`
- Produces: 内核模块 `ft8756.ko`，`compatible` 与 DTS 一致

- [ ] **Step 1: 写下模块断言（先验证失败）**

Run:
```bash
find work -name 'ft8756.ko*' | grep -q . && echo PASS || echo FAIL
```
Expected: `FAIL`

- [ ] **Step 2: 移植驱动并生成 patch**

把 nasaarmas 的 `drivers/input/touchscreen/ft8756.c` 连同 `Kconfig` / `Makefile` 改动移植到 7.2.8，形状对照 ST7123 驱动（`input_device` 注册、多点触控 slot、`devm_` 资源管理、I2C probe 签名）。

- [ ] **Step 3: 构建**

Run: `STEAMOS_WORK=$PWD/work bash external-and-mods/kernel-common/build-gcc15.sh sm8250`
Expected: 构建成功

- [ ] **Step 4: 模块断言转为通过 + compatible 交叉断言**

Run:
```bash
KO=$(find work -name 'ft8756.ko*' | head -1); echo "$KO"
D=$(find work -name 'sm8250-xiaomi-alioth.dtb' | head -1)
for c in $(modinfo -F alias "$KO" | sed -n 's/^of:N\*T\*C//p' | tr -d '*'); do
  strings "$D" | grep -qx "$c" && echo "compatible 匹配: $c" || echo "compatible 不匹配: $c"
done
```
Expected: 至少一条匹配，无不匹配

- [ ] **Step 5: 提交**

```bash
git add external-and-mods/kernel-sm8250/patches/0018-*.patch external-and-mods/kernel-sm8250/steamos.config
git commit -m "feat(input): 前向移植 FocalTech FT8756 触摸驱动到 7.2.8"
```

---

### Task 5: boot image 打包、刷机脚本与首次启动

本任务收口四个未知项：boot header v0 是否被接受、是否必须 `erase dtbo`、是否必须禁用 vbmeta、模块与 initramfs 是否匹配。

**需要真机 + USB 线，由持有设备的人执行刷机步骤。**

**Files:**
- Create: `make-steamos-alioth.sh`（阶段 1 仅 `--kernel-only`）
- Create: `flash-alioth.sh`（阶段 1 仅 `--test`）
- Modify: `docs/alioth.md`

**Interfaces:**
- Consumes: Task 1–4 的内核输出目录（路径见 `docs/alioth.md`，由 Task 1 Step 5 记录）
- Produces: `work/steamos-alioth/boot-debug.img`；`flash-alioth.sh --test`

- [ ] **Step 1: 写下产物断言（先验证失败）**

Run: `test -f work/steamos-alioth/boot-debug.img && echo PASS || echo FAIL`
Expected: `FAIL`

- [ ] **Step 2: 实现 `make-steamos-alioth.sh --kernel-only`**

照 `make-steamos-sm8350.sh` 的结构。用 `external-and-mods/kernel-common/mkbootimg-v0.py` 把 Task 1–4 的内核打成 `work/steamos-alioth/boot-debug.img`，cmdline 取 Global Constraints 中的值，initramfs 用上游的 debug 变体（`external-and-mods/kernel-common/initramfs/bootdebug`）。

- [ ] **Step 3: 实现 `flash-alioth.sh --test`（含两条安全检查）**

必须包含 Review Focus #1 的运行时检查：读 `fastboot getvar current-slot`，计算非活动槽，**若目标槽等于活动槽则拒绝执行并退出非零**。脚本只允许写 `boot_<非活动槽>`、`dtbo_<非活动槽>`、`vbmeta_<非活动槽>`。

- [ ] **Step 4: Review Focus #2 —— 静态断言 `--test` 路径不含危险分区**

Run:
```bash
# --test 的实现中不得出现这些分区名
grep -nE 'userdata|\bsuper\b|abl_a|abl_b' flash-alioth.sh && echo "DANGER: 危险分区名出现在刷机脚本中" || echo "静态检查通过"
# 槽位保护必须存在
grep -q 'current-slot' flash-alioth.sh && echo "槽位保护存在" || echo "DANGER: 缺少槽位保护"
```
Expected: `静态检查通过` 且 `槽位保护存在`

- [ ] **Step 5: Review Focus #4 —— 模块与 initramfs 匹配断言**

真正会咬人的是模块 `vermagic` 与打包进 boot image 的内核不一致 —— 模块加载失败，调试 shell 起不来，而那是阶段 1 唯一的观测手段。

Run:
```bash
BI=work/steamos-alioth/boot-debug.img
python3 external-and-mods/ufs-install/ufs-bootimg.py info "$BI"
python3 external-and-mods/ufs-install/ufs-bootimg.py info "$BI" \
  | grep -q 'steamos.root=PARTLABEL=userdata' && echo "cmdline PASS" || echo "cmdline FAIL"

KREL=$(cat "$(find work -name kernel.release -path '*include/config*' | head -1)")
echo "kernel release: $KREL"
KO=$(find work -name 'panel-samsung-ams667xx01.ko*' | head -1)
modinfo -F vermagic "$KO" | grep -q "^$KREL " \
  && echo "vermagic PASS" || echo "DANGER: 模块 vermagic 与内核不一致，调试 shell 会起不来"
```
Expected: header v0；`cmdline PASS`；`vermagic PASS`

- [ ] **Step 6: 产物断言转为通过**

Run: `test -f work/steamos-alioth/boot-debug.img && echo PASS`
Expected: `PASS`

- [ ] **Step 7: 真机首次启动（持有设备者执行）**

Run:
```bash
# 设备进 fastboot：关机后长按 音量下 + 电源
fastboot getvar current-slot          # 预期 b，确认后目标槽为 a
./flash-alioth.sh --test
fastboot reboot
```

观测，按顺序尝试直到进入调试 shell：
```bash
screen /dev/ttyACM0 115200            # 通道一：USB 串口
# 通道二：PC 侧网卡设 172.16.42.2/24，然后 telnet 172.16.42.1
```

未进入 shell 时按此顺序排除（每次只改一个变量，每次都能用 `fastboot --set-active=b` 回到 Android）：
1. `fastboot erase dtbo_a` 后重试（spec §9 判定为高概率需要）
2. 用 `scripts/mk-vbmeta-disabled.py` 生成并刷 `vbmeta_a` 后重试
3. 改用 `mkbootimg-v3.py` + `vendor_boot_a`，照 `docs/redmagic6.md` 的 v3 方案

- [ ] **Step 8: 记录四项结论并提交**

把"v0 是否被接受 / 是否需 erase dtbo / 是否需禁 vbmeta / 模块是否匹配"四项的实测结论写入 `docs/alioth.md`。这四项决定阶段 2 计划的形状，必须写清楚。

```bash
git add make-steamos-alioth.sh flash-alioth.sh docs/alioth.md
git commit -m "feat(boot): alioth boot image 打包与 --test 刷机脚本；记录启动链实测结论"
```

---

### Task 6: 外设验收与 DTS 修正循环

**需要真机。** 本任务是阶段 1 的验收门，并收口最后一项未知（ROCKNIX 平台代码与 alioth DTS 的冲突）。

**Files:**
- Modify: `external-and-mods/kernel-sm8250/dts/sm8250-xiaomi-alioth.dts`（按实测修正）
- Modify: `docs/alioth.md`

**Interfaces:**
- Consumes: Task 5 的调试 shell
- Produces: 阶段 1 验收结论；阶段 2 计划的输入

- [ ] **Step 1: 在调试 shell 内采集 dmesg**

Run（在设备的调试 shell 内）：
```sh
dmesg > /tmp/dmesg.txt
grep -iE 'msm_dpu|msm_dsi|ams667|adreno|a650|gmu' /tmp/dmesg.txt
grep -iE 'ft8756|focaltech' /tmp/dmesg.txt
grep -iE 'ath11k|qca6390|hci|bluetooth' /tmp/dmesg.txt
grep -iE 'ufshcd|scsi 0' /tmp/dmesg.txt
grep -iE 'error|fail|timeout|denied' /tmp/dmesg.txt | head -40
```

- [ ] **Step 2: 逐项核对验收标准**

每项记录 PASS/FAIL 与证据行：
```
□ 面板点亮（屏幕有内容，且 dmesg 有 ams667xx01 probe 成功）
□ drm/msm + A650 GPU 初始化成功（adreno/gmu 无 timeout）
□ UFS 认出（/dev/sd* 存在）
□ FT8756 触摸探测到
□ QCA6390 WiFi 与 BT 探测到
□ fastboot --set-active=b 能回到 Android
```

- [ ] **Step 3: 对 FAIL 项修正 DTS 并回到 Task 5 Step 7**

每轮只改一处，重新构建、重刷非活动槽、重新采集 dmesg。此循环是阶段 1 的主体工作量，spec §9 已预期不会一次通过。

早期挂死且 USB 未起来时，用二分法：已知 pmOS 的 6.19.6 在 alioth 上能开机，逐步把 alioth DTS 的节点分组往 7.2.8 上搬，缩小到具体节点。

- [ ] **Step 4: 阶段 1 验收通过后固化**

把全部 7 项未知的最终结论、以及每个外设的工作状态写入 `docs/alioth.md`。

```bash
git add external-and-mods/kernel-sm8250/dts/sm8250-xiaomi-alioth.dts docs/alioth.md
git commit -m "feat(alioth): 阶段 1 通过 —— 内核启动到调试 shell，外设验收完成"
```

---

## 阶段 1 完成后

`docs/alioth.md` 中的 7 项结论齐备后，为阶段 2（Valve rootfs 组装、`alioth-overlay`、`--install` 模式、Game Mode 验收）单独编写实施计划。阶段 2 的打包与分区步骤形状取决于本阶段 Task 5 的实测结论，因此不在本计划内展开。
