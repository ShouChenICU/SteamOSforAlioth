# `alioth-overlay/`

Xiaomi Redmi K40 / POCO F3（alioth，SM8250-AC）特有的用户空间配置，装到
Valve Frame rootfs 上。

## 为什么独立于 `sm8250-overlay/`

alioth 和那些机器同为 SM8250，但 `sm8250-overlay/` 里的 44 个文件全是掌机的
**物理摇杆与按键** InputPlumber 配置（AYANEO Pocket MICRO 2、Retroid Pocket 5 /
Flip 2 / Mini、MANGMI Air Y Pro / Pocket Max、AYN Thor Lite），与 alioth 的
「触摸 + 蓝牙手柄 + 两个音量键」没有交集。

分开放的真正理由是 merge 面：每次 `git merge upstream/main` 都要分得清哪些
文件是上游的、哪些是我们的（spec §4）。

**但两个 overlay 不是按目录互斥的。** `scripts/apply-alioth-overlay.sh` 在
`apply-overlays.sh` 之后跑，只做加法，一个 `sm8250-overlay/` 的文件都不删：

- 掌机的 5 个 InputPlumber profile 全都 gate 在各自的 DT model 上
  （`Retroid Pocket 5`、`AYN Thor Lite`、`MANGMI …`、`AYANEO …`），对
  `Xiaomi Poco F3` 一个都匹配不上，本来就是惰性的；
- 而 `sm8250-overlay/etc/systemd/user/steamos-powerbuttond.service` 恰恰是
  **我们要用的** —— 下面那个 drop-in 只写了 `Wants=`，把它当掌机文件删掉
  `Wants=` 就悬空了，systemd 对此一声不吭，表现为电源键在 Game Mode 里没反应。

互斥因此按 profile 粒度断言（没有第二个 profile 认领我们的 model），不按目录
粒度删除 —— 见 `scripts/assert-alioth-overlay-applied.sh`。

## 内容

| 路径 | 作用 |
|---|---|
| `etc/inputplumber/devices.d/02-xiaomi-alioth.yaml` | 把两个音量键组成一个虚拟 Deck 手柄 |
| `etc/inputplumber/capability_maps.d/alioth_keys.yaml` | 音量上 → Steam 键，音量下 → 快捷菜单 |
| `etc/systemd/user/gamescope-session.target.d/99-zz-alioth-powerbuttond.conf` | 电源键交给 `steamos-powerbuttond`（Frame 自带的 unit 依赖 SteamVR） |
| `usr/lib/udev/rules.d/70-alioth.rules` | FT8756 触摸屏标记为 seat0 的指针设备 |
| `usr/lib/modules-load.d/alioth.conf` | 开机加载 PCIe pwrctrl、WiFi、蓝牙、音频模块 |
| `usr/share/alsa/ucm2/Xiaomi/Alioth/` | 扬声器 UCM（本机只有扬声器，无 3.5 mm 口） |
| `usr/share/alsa/ucm2/conf.d/sm8250/xiaomi-alioth.conf` | UCM 入口，文件名 = 声卡名 |
| `usr/lib/steamos-arm/alioth-firstboot` | 首次开机把根文件系统扩展到 106 GiB，然后标记 A/B successful |
| `usr/lib/systemd/system/alioth-firstboot.service` | 上面那个脚本的 unit（+ `sysinit.target.wants/` 里的 enable 链接） |

## 这台机器上「没有按键」意味着什么

alioth 一个物理游戏按键都没有。触摸由 Deck UI 原生处理，蓝牙手柄由
InputPlumber 自带的 Xbox / DualSense / 8BitDo profile 处理（它们本来就
target `deck-uhid`，我们不去覆盖）。真正需要我们做的只有一件事：Deck UI 的
**Steam 键**和**快捷菜单**在纯触摸下没有可靠入口，游戏全屏捕获触摸时尤其如此。
那两个音量键就是为此而来，代价是失去硬件音量调节 —— 快捷菜单里有音量滑条，
所以是两次按键而不是一次，不是失去。

按键归属（阶段 1 在真机 `/proc/bus/input/devices` 实测）：

```
gpio-keys       音量上    pm8150 gpio6，DTS 里的 vol_up_n
pm8941_resin    音量下    power-key block，上报 KEY_VOLUMEDOWN
pm8941_pwrkey   电源      不归 InputPlumber，归 steamos-powerbuttond
```

## 音频

声卡是 `qcom,sm8250-sndcard`，唯一的 codec 链路接 i2c3 上两颗 Cirrus
**CS35L41** 功放（`sound-name-prefix` 分别是 `RCV` 和 `LCV`），由
`TERTIARY_TDM_RX_0` 喂。没有 WCD938x，没有 WSA881x，没有 3.5 mm 口 ——
耳机走蓝牙，不经过 ALSA。

两件容易踩的事：

1. ROCKNIX 没开 `CONFIG_SND_SOC_CS35L41_I2C`（它的掌机都不用这颗）。少了
   功放驱动，codec 组件不注册，DAI link 配不齐，**整张声卡都不出现** ——
   不是「没声音」，是 `/dev/snd/controlC0` 都没有。已在
   `external-and-mods/kernel-sm8250/steamos.config` 里补成 `=m`。
2. UCM 按**声卡名**查找，而声卡名来自 `&sound` 节点的 `model`
   （`xiaomi-alioth`），不是根节点的 `model`（`Xiaomi Poco F3`）。所以入口
   文件叫 `conf.d/sm8250/xiaomi-alioth.conf`。
   `scripts/assert-alioth-modules.py` 直接从 DTS 读这个值来比对，防止两边漂移。

两颗功放钉在固定的 −12 dB，音量由 PipeWire 在软件里做：它们是两个独立
codec，`PlaybackMixerElem` 只能指到其中一个；而且
`nasaarmas/pmaports-alioth` 报告这对扬声器推大了声音发散。

2026-10-23 真机实测结论（原「待真机核实」已结）：

- 控件名对了。`amixer -c0 controls` 里 `RCV/LCV Digital PCM Volume` 的
  `dBminmax` 是 `-102.00dB .. 12.00dB`，和注释里「721 = −12 dB」的推导一致；
  `alsaucm -c xiaomi-alioth set _verb HiFi set _enadev Speaker` 干净通过，
  路由控件读回 `on`。
- **后端是 TDM，而且绕不过去。** `TERTIARY_TDM_RX_0` 一开始带着 0 槽 0 槽宽
  到 q6afe，ADSP 直接拒收（`AFE enable for port 0x9020 failed -22`，
  `DSP returned error[2]`），表现不是「没声音」而是 **`snd_pcm_open` 返
  EINVAL** —— ACP 一个 profile 都探测不出来（`spa-acp-tool`:
  `profiles:2 ports:0`），PipeWire 只给一个 Dummy Output。真因是
  `qcom,sm8250-sndcard`（`sound/soc/qcom/sm8250.c`）**从不调用
  `snd_soc_dai_set_tdm_slot()`**。

  换成 `TERTIARY_MI2S_RX` 绕开它是走反了方向，而且代价很隐蔽：两颗功放的
  `ASP_SDIN` 接在 `mi2s2_data1`（gpio137）上，而 `sm8250.dtsi` 的
  `tert_mi2s_active` 只有 gpio133/134/135，`qcom,sd-lines = <0>` 驱动的
  gpio134 是功放把 VI sense 送回 SoC 的方向。时钟脚两种模式共用，所以功放
  照样锁 PLL、照样 `PUP_DONE`、照样零故障 —— 得到的是一张**每一项都查得过、
  完全不出声**的声卡，连功率都不输出（放粉噪声把 `Analog PCM Volume` 在 0
  和 16 之间切，电池电流毫无变化）。

  正确做法是补上缺的东西：补丁 0027 给 machine driver 加 TDM 分支，补丁
  0026 把 `qcom,tdm-invert-sync` / `tdm-data-delay` / `tdm-data-out` 真的送
  到 ADSP（`q6afe_tdm_port_prepare()` 原本把这三项解析完就丢了）。后端留在
  `TERTIARY_TDM_RX_0`，由 `scripts/assert-alioth-dtb.py` 第 4c 条守住端口与
  帧参数、第 4e 条守住 gpio137。

## 首次开机

刷进 `userdata` 的镜像只有几 GB（按内容大小做的），而分区是 106 GiB。
`alioth-firstboot` 在开机早期把根文件系统扩展到整个分区 —— 不扩展的话
Steam 第一次装游戏就没空间，而报错离原因很远。

顺序是这个脚本的全部要点：

```
哨兵存在？ -- 不在就什么都不做（已经跑过了）
扩展
标记 successful
删哨兵                      <-- 只有全都成功才走到这里
```

哨兵 `/var/lib/alioth-firstboot-pending` 由构建时放进镜像，脚本只删不建。
任何中断（掉电、SIGKILL、`resize2fs` 失败）都必然落在「哨兵还在」的状态，
下次开机自然重来。反过来写就会留下一个永远只有几 GB 的根文件系统，而且
没有任何东西会再去修它。`scripts/assert-alioth-firstboot.sh` 真的在
`resize2fs` 跑到一半时 SIGKILL 掉它来验证这件事。

标记 successful 放在扩展成功**之后**：在那之前，bootloader 的自动回退
（连续失败 7 次换槽，spec §6.3）是唯一的兜底，不能提前关掉。

enable 链接放在 `usr/lib/systemd/system/sysinit.target.wants/` 而不是
`/etc` 下，因为 SteamOS 的 `/etc` 是 overlayfs 且挂载很晚，而这个 unit
要在 `sysinit.target` 之前跑。

> **待真机核实（Task 8）：** `qbootctl -u` 的 `-u` 是「mark boot successful」
> （linux-msm/qbootctl），没在真机上验过。脚本在它失败时会把 `qbootctl -h`
> 打进日志并保留哨兵，所以一次开机就能看出正确的用法。
