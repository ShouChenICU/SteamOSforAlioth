# alioth 硬件清单（从原厂 Android 取得，2026-10-23）

这份清单是在原厂 Android（MIUI `V816.0.3.0.TKHMIXM`，Android 13，slot b，
已 root）上用 adb 直接读 sysfs / getprop 得到的，不是从 DTS 推断的。原始
转储在 [logs/2026-10-23-android-hardware-inventory.txt](logs/2026-10-23-android-hardware-inventory.txt)。

「mainline 状态」一列是已知情况，**不是实测**——除了标了「已实测」的几项。
Task 6 的外设验收就是把这一列逐项变成实测。

## 整机

| 项 | 值 |
|---|---|
| 机型 | POCO F3 / Redmi K40（`alioth`，`sku=pro`、`hwc=CN`、`hwlevel=MP`） |
| SoC | Snapdragon 870（`kona` / sm8250-ac），`cpuid=<cpuid redacted>` |
| 存储 | WDC **SDINFDK4-128G** UFS，245202944 × 512B ≈ 125.5 GB |
| 电池 | 设计容量 4520 mAh，`voltage_max_design = 4.45 V`（充电上限约束见 docs/alioth.md） |
| 序列号 | `<已脱敏>` —— 仓库里没有任何脚本依赖它，所以开源前去掉了 |

## 显示与输入

| 器件 | 型号 / 位置 | mainline 状态 |
|---|---|---|
| 面板 | `k11a_38_08_0a`，DSC 命令模式，1080×2400@60（`card0-DSI-1 ... 183357cmd`） | **已实测可用** —— `panel-samsung-ams667xx01`（补丁 0017） |
| 背光 | `panel0-backlight`，`max_brightness = 2047` | 待验证 |
| 触摸 | **FocalTech**，`soc/spi@990000/focaltech@0`，驱动 `fts_ts`；`IC ID:0x5652`（寄存器 0xA3=0x56、0x9F=0x52），固件版本 `0x1d`，`Vendor ID:0x8d`，`fts_lockdown_info = 0x48,0x38,<unit serial redacted>`；reset gpio 33、int gpio 39、SPI mode 0、max 10 MHz | 进行中（补丁 0018 + 0020–0024），详见 docs/alioth.md |
| 触摸面板码 | `panel_color=2`、`panel_display=8`、`panel_vendor=H`、`touch_vendor=3` | — |
| 按键 | `gpio-keys`、`qpnp_pon`（电源键） | 待验证 |
| 指纹 | **FPC** 侧边式（`persist.vendor.sys.fp.vendor=fpc`，驱动 `fpc1020`，`sensor_location=1080\|965\|115`） | mainline 无驱动 |
| 震动 | **Awinic AW8697**，`soc/i2c@a8c000/aw8697_haptic@5A`，固件 `aw8697_haptic.bin` + 6 个 RTP 波形 | mainline 无驱动 |

## 音频

| 器件 | 型号 / 位置 | mainline 状态 |
|---|---|---|
| 扬声器功放 | **2× Cirrus Logic CS35L41**，`soc/i2c@98c000/cs35l41@40` 与 `@41`（立体声双扬） | mainline 有 `cs35l41-i2c`；需要 `/vendor/firmware/cs35l41-dsp1-spk-prot*.wmfw/.bin` |
| 主 codec | `wcd938x_codec`（WCD9385）+ bolero macros（`rx_macro` / `tx_macro` / `va_macro` / `wsa_macro`） | mainline 有 `wcd938x` 与 `lpass-*-macro` |
| 声卡 | `kona-mtp-snd-card`（Headset / Button / USB_3_5 Jack） | 待验证 |
| USB-C 音频切换 | **FSA4480**，`soc/i2c@884000/fsa4480@42` | mainline 有 `fsa4480` |
| 校准数据 | `/vendor/firmware/spk{1,2}_{playback,voice}_delta.txt`、`rcv_voice_delta.txt` | — |

## 无线

| 器件 | 型号 | mainline 状态 |
|---|---|---|
| Wi-Fi | **QCA6390**（`cnss2` + `qca_cld`，PCIe），`wlan0` / `wlan1` / `p2p0` / `wifi-aware0` | mainline 有 `ath11k`（PCI）；固件在 soc.env 的 `BUILTIN_FW` 里 |
| 蓝牙 | **QCA6390**（`/vendor/bt_firmware/image/htbtfw20.tlv` + `htnv20.bin`） | mainline 有 `hci_qca` / `btqca` |
| NFC | **NXP NQ**（`soc/i2c@984000/nq@28`，驱动 `nq-nci`） | mainline 有 `nxp-nci-i2c`，待验证 |
| 红外 | `soc/spi@988000/ir-spi@0`，驱动 `ir-spi-led` | mainline 有 `ir-spi` |
| 基带 | `androidboot.baseband=mdm`，`rmnet_*` / `rmnet_ipa0` / `rmnet_mhi0` | 不做（已接受失去通话） |

## GPU

| 项 | 值 |
|---|---|
| GPU | Adreno 650（`kgsl-3d`，`gpu_cc-kona`） |
| 固件（机内） | `/vendor/firmware/` 里有 `a650_gmu.bin`、`a650_sqe.fw`、`a650_zap.{elf,mdt,b00,b01,b02}` |
| 注意 | mainline 要的是 `qcom/a650_zap.mbn`。机内是旧的 `.mdt` + `.bXX` 分段格式。阶段 2 配 Mesa/Turnip 时如果 linux-firmware 的签名 zap 在这台机器上过不了，机内这份才是能用的那份 |

## 电源与充电

| 器件 | 位置 | 备注 |
|---|---|---|
| 主 PMIC | PM8150 / PM8150B / PM8150L（`qcom,qpnp-smb5`、`qcom,fg-gen4`） | **阶段 1/2 都不加载充电驱动** —— 社区 PM8150B 驱动会把上限设到约 4.87 V，本机安全值 4.435 V（实测 `voltage_max_design` 4.45 V） |
| 电荷泵 | **BQ25970**（`soc/i2c@884000/bq25970-standalone@66`，驱动 `bq2597x-charger`）、`smb1390_slave@18`、`ln8282@55` | — |
| 相机 PMIC | **PM8008**（`soc/i2c@888000/qcom,pm8008@8` 与 `@9`） | — |
| 电池认证 | `maxim_ds28e16`（onewire） | — |
| 无线充电节点 | `idtp9415@3b`、`rx1619@61`、`rx1619@67` —— **均未绑定驱动**（`drv=` 为空） | K40 无无线充电，这些是平台 DTS 继承下来的空节点 |
| 电源节点 | `battery`（Li-poly，4513/4520 mAh）、`bms`、`bq2597x-standalone`、`dc`、`main`、`usb`、`pc_port`、`batt_verify` | — |

## 摄像头（不是移植目标，仅记录）

`qcom,camera` / `cam_*` 一整套 CAMSS；传感器在 DTS 里是 `cam_imx582`、
`s5k5e9`、`imx355`。闪光灯 `qcom,qpnp-flash-led-v2`。固件
`/vendor/firmware/CAMERA_ICP.elf`。

## 传感器

Android 走 `sensors-ssc`（SLPI DSP）+ `us_prox`，没有独立的 i2c 传感器
节点暴露出来，`/sys/class/sensors/` 为空。这一套在 mainline 上没有对应
实现 —— 加速度计/陀螺仪/光距感在阶段 2 要另行评估（Game Mode 不依赖它们）。

## 原厂 cmdline 里值得留意的几项

```
msm_drm.dsi_display0=qcom,mdss_dsi_k11a_38_08_0a_dsc_cmd:
androidboot.bootdevice=1d84000.ufshc
androidboot.oled_wp=<oled_wp redacted>
androidboot.slot_suffix=_b
androidboot.verifiedbootstate=orange
```

---

# 第二轮：更深的枚举（2026-10-23）

原始转储：[logs/2026-10-23-android-device-enumeration.txt](logs/2026-10-23-android-device-enumeration.txt)

## USB-C（接有线手柄要用的那条链）

| 项 | 实测值 |
|---|---|
| 控制器 | `a600000.ssusb` → `a600000.dwc3`；`androidboot.usbcontroller=a600000.dwc3` |
| UDC 状态 | `a600000.dwc3 state=configured speed=high-speed`（USB 2.0 only，DTS 已 `maximum-speed = "high-speed"`） |
| Type-C 口 | `/sys/class/typec/port0`：`port_type=[dual] source sink`、`data_role=host [device]`、`power_role=source [sink]`、`preferred_role=sink`、PD rev 3、Type-C rev 1.3 |
| PD PHY | PM8150B `qcom,usb-pdphy@1700` |
| extcon | `qcom,qpnp-smb5` 提供 `USB` / `USB-HOST`；`pdphy@1700` 提供 `USB` / `USB-HOST` / `DP`；`88e0000.qcom,msm-eud` 提供 `USB` / `SDP` |
| SBU 切换 | **FSA4480** `soc/i2c@884000/fsa4480@42`（我们 DTS 里是 `&i2c15` 的 `typec-mux@42`） |

**结论**：硬件是真正的 DRP 口，OTG host 模式可行。我们内核缺的只是
`vdd-vbus-supply`（见 docs/alioth.md 的 USB-C 一节）。手柄侧的 HID 驱动
（xpad / PlayStation / Nintendo / Sony / Microsoft / joydev）已经全部编入。

## PCIe

| 设备 | 实测 |
|---|---|
| `0000:00:00.0` | `17cb:010b`，根桥（`pci-msm-rc`） |
| `0000:01:00.0` | **`17cb:1101` = QCA6390**（Android 驱动 `cnss_pci`；mainline 走 `ath11k_pci`） |
| `0002:00:00.0` | `17cb:010b`，第二个根桥 |
| `0002:01:00.0` | `17cb:0306`，基带（`mhi`）—— 不做 |

## ramoops / 预留内存

原厂设备树的 `reserved-memory` 下有 **`ramoops`**，`reg = <0x0 0xb0000000
0x0 0x00100000>`，`record-size = 0x00100000`，`max-reason = 4`，并且驱动
确实绑定（`/sys/bus/platform/devices/b0000000.ramoops`）。这块地址我们现在
用上了（见 docs/alioth.md）。

同一份 `reserved-memory` 里还有 `cont_splash_region@9c000000`（我们的
simpledrm framebuffer 用的就是这块）、`disp_rdump_region@9c000000`、
`dfps_data_region@9e300000`、`mem_dump_region`、`removed_region@80b00000`、
`pil_*`（各 DSP/子系统固件）、`res_xbl_uefi_log_region`、`tzlog@146bf720`。

## LED

```
flashlight max=750          led:flash_0 / flash_1 max=1500
led:torch_0 / torch_1 max=500    led:switch_0..3 max=255
hr_led1 / hr_led2 max=255
```

闪光灯走 `qcom,qpnp-flash-led-v2`（我们 DTS 已启用 `&pm8150l_flash`）。
**没有通知指示灯** —— `qcom,tri-led` 驱动在列，但没有对应的 LED 设备。

## ADC / 传感器

| 项 | 实测 |
|---|---|
| IIO | `iio:device0/1/2` = PM8150 / PM8150B / PM8150L 的 `vadc@3100`；`iio:device3 = distance` |
| hwmon | `hwmon0 bms`、`hwmon1 battery` |
| 距离感 | **没有硬件距离传感器** —— `iio:device3 distance` + `us_prox` 是听筒超声方案（Elliptic Labs） |
| 其余传感器 | 全部走 `sensors-ssc`（SLPI DSP），`/sys/class/sensors/` 为空 |

## 充电链（完整）

| 器件 | 位置 / 驱动（Android） | 我们这边 |
|---|---|---|
| PMIC 充电器 | PM8150B `qcom,qpnp-smb5` | **已启用** `&pm8150b_charger`（`CONFIG_CHARGER_QCOM_SMB5=y`），浮充 clamp 4.45V、电流 2A |
| 电量计 | `qcom,fg-gen4`（PM8150B） | 已启用 `&pm8150b_fg`（`CONFIG_BATTERY_QCOM_FG=y`） |
| 电荷泵（快充） | **BQ25970** `i2c@884000` 0x66，驱动 `bq2597x-charger` | 无驱动 —— 所以没有 33W 快充 |
| 从机电荷泵 | `smb1390_slave@18` | 无 |
| 另一颗 | `ln8282@55`（未绑定驱动） | 无 |
| 电池认证 | `maxim_ds28e16`（onewire，`onewire_gpio`） | 无 |
| 电源节点 | `battery` / `bms` / `main` / `usb` / `pc_port` / `dc` / `batt_verify` / `bq2597x-standalone` | — |

## 其它值得记的

- **IR 发射** `soc/spi@988000/ir-spi@0`，驱动 `ir-spi-led`（mainline 有 `ir-spi`）
- **NFC** `soc/i2c@984000/nq@28`，`nq-nci`；`ro.boot.product.hardware.sku=nfc`
- **CPU** 4 个 cpufreq policy（1+3+4 的 SD870 拓扑）
- **xiaomi-touch** 是一个虚拟 input 设备（`/sys/class/touch/touch_dev` 的那套
  手势/边缘抑制参数接口），不是硬件
