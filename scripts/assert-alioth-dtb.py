#!/usr/bin/env python3
"""断言 alioth DTB 满足 spec 的硬性约束。

用法: scripts/assert-alioth-dtb.py <sm8250-xiaomi-alioth.dtb> [--module <x.ko>]...

给出 --module 时，还会断言该模块声明的 OF compatible **至少有一个**能在
DTB 里找到对应节点（Review Focus #3：驱动与 DTS 的 compatible 不一致会静默
失败 —— 模块装上了，节点也在，但谁都不认识谁）。不要求全中：一个驱动会声明
它支持的全部型号，而一块板子只有其中一两个。

注意不要用 `strings dtb | grep -qx <compat>` 做这件事：DTB 是二进制，相邻
属性值的尾字节会和字符串并成同一个 token（实测 compatible 前面挨着一个
'2'），于是断言产生假阴性。

每条断言对应一个会静默失效的 spec 决定 —— 它们在编译期都不报错，
只会在真机上表现为「屏幕是竖的」「GPU 没起来」「电池鼓包」这类
与原因相距很远的症状。Task 6 的修正循环每轮都要重跑这个脚本。
"""
import re
import subprocess
import sys

PANEL_COMPAT = "xiaomi,alioth-ams667xx01"
EXPECT_MODEL = "Xiaomi Poco F3"          # spec §249：InputPlumber 与 Decky 的匹配键
EXPECT_ZAP = "qcom/sm8250/a650_zap.mbn"  # 固件 kit 实际提供的路径

# GPU 时钟上限。见下面第 4b 条：高于这个值的档位 GMU 投不出去。
# 2026-10-25：从 587 提到 670（SD870 的原厂上限），**真机验过**：GMU 正常起来，
# 没有 HFI 超时，devfreq 在 performance 下稳在 670 MHz。670 要 NOM_L1（0x140），
# 而已知失败的 925 要 TURBO_L1，高两个 corner —— 所以 700 及以上仍然禁止，
# 它们没有被验过。
GPU_MAX_HZ = 670_000_000
# 音频后端端口。id 见 include/dt-bindings/sound/qcom,q6dsp-lpass-ports.h。
SPEAKER_PORT_ID = 56                     # TERTIARY_TDM_RX_0
# 真正把音频送到两颗 CS35L41 的 ASP_SDIN 的那根线。见下面第 4c / 4e 条。
SPEAKER_DATA_PIN = "gpio137"
SPEAKER_DATA_FUNC = "mi2s2_data1"
# TDM 帧参数。补丁 0026 之前这四项会被解析后丢掉，所以它们必须和那个补丁
# 一起存在才有意义；这里只断言 DTS 侧写全了。
EXPECT_TDM_PROPS = {
    "qcom,tdm-sync-mode": 0,
    "qcom,tdm-sync-src": 1,
    "qcom,tdm-invert-sync": 1,
    "qcom,tdm-data-delay": 1,
}
EXPECT_ROTATION = 90                     # 竖屏面板，Game Mode 要横屏
# 90 而不是 270，是 2026-10-23 真机实测定的。厂商 DTS（pmaports、
# LineageOS）都写 270，照抄过来控制台横是横了，但上下颠倒 180 度 ——
# Qualcomm 下游的旋转约定和 mainline DRM 的 DRM_MODE_PANEL_ORIENTATION_*
# 反向，<270>=RIGHT_UP 与 <90>=LEFT_UP 差的正好是 180 度。
# 这个值离机无法确定（simpledrm 不读 rotation，只有面板驱动的
# .get_orientation 会用它），所以它必须由真机结论锁住。
FB_BASE = 0x9C000000                     # 原厂 cont_splash_region@9c000000
FB_W, FB_H = 1080, 2400
FB_SIZE = FB_W * FB_H * 4
FB_FORMAT = "a8r8g8b8"


STATE_PINS = {}


def fdt(dtb, *args):
    r = subprocess.run(["fdtget", dtb, *args], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None


def reg_of(dtb, path):
    """节点 reg 的 (base, size)，按 2 个 address cell + 2 个 size cell 解。"""
    words = (fdt(dtb, "-tx", path, "reg") or "").split()
    if len(words) != 4:
        return None
    v = [int(w, 16) for w in words]
    return (v[0] << 32) | v[1], (v[2] << 32) | v[3]


def walk(dtb, path="/"):
    """深度优先遍历，产出每个节点的 (路径, 属性名集合)。"""
    yield path, set((fdt(dtb, "-p", path) or "").split())
    for name in (fdt(dtb, "-l", path) or "").split():
        yield from walk(dtb, ("" if path == "/" else path) + "/" + name)


def module_of_compats(ko):
    """模块声明的 OF compatible 集合。

    modalias 的形状是 of:N<name>T<type>C<compatible>，可能再跟一个尾部 'C*'。
    """
    r = subprocess.run(["modinfo", "-F", "alias", ko], capture_output=True, text=True)
    if r.returncode != 0:
        return None
    out = set()
    for line in r.stdout.split():
        m = re.match(r"^of:N.*?T.*?C(.+?)(?:C\*)?$", line)
        if m:
            out.add(m.group(1))
    return out


def main():
    argv = sys.argv[1:]
    mods = []
    while "--module" in argv:
        i = argv.index("--module")
        mods.append(argv[i + 1])
        del argv[i:i + 2]
    if len(argv) != 1:
        sys.exit(__doc__)
    dtb = argv[0]
    tree = list(walk(dtb))
    fails = []

    def check(ok, label, detail):
        print(("PASS  " if ok else "FAIL  ") + label + " — " + detail)
        if not ok:
            fails.append(label)

    def compat_of(path, props):
        return (fdt(dtb, "-ts", path, "compatible") or "") if "compatible" in props else ""

    # 1. DT model
    model = fdt(dtb, "-ts", "/", "model")
    check(model == EXPECT_MODEL, "model", "%r（期望 %r）" % (model, EXPECT_MODEL))

    # 2. 根 compatible
    root_compat = fdt(dtb, "-ts", "/", "compatible") or ""
    want = ("xiaomi,alioth", "qcom,sm8250")
    check(all(w in root_compat.split() for w in want),
          "root compatible", "%r（须含 %s）" % (root_compat, " + ".join(want)))

    # 3. 面板朝向。必须是面板节点的直接属性 —— 整棵树里 grep 'rotation' 会命中
    #    摄像头 sensor 子节点自带的那几条，计数断言因此不可靠。
    panels = [(p, pr) for p, pr in tree if PANEL_COMPAT in compat_of(p, pr).split()]
    if len(panels) != 1:
        check(False, "panel node", "按 compatible %r 找到 %d 个节点（期望 1）"
              % (PANEL_COMPAT, len(panels)))
    else:
        ppath, pprops = panels[0]
        if "rotation" not in pprops:
            check(False, "panel rotation", "%s 没有 rotation 属性" % ppath)
        else:
            rot = fdt(dtb, "-ti", ppath, "rotation")
            check(rot == str(EXPECT_ROTATION), "panel rotation",
                  "%s rotation=%s（期望 %d）" % (ppath, rot, EXPECT_ROTATION))

    # 4. GPU zap shader 的固件路径。加载不到 zap shader，Adreno 650 出不了
    #    secure mode，GPU 整个不可用。
    zaps = [p for p, pr in tree if p.endswith("/zap-shader") and "firmware-name" in pr]
    if len(zaps) != 1:
        check(False, "zap-shader", "找到 %d 个带 firmware-name 的 zap-shader（期望 1）" % len(zaps))
    else:
        fw = fdt(dtb, "-ts", zaps[0], "firmware-name")
        check(fw == EXPECT_ZAP, "zap-shader firmware", "%r（期望 %r）" % (fw, EXPECT_ZAP))

    # 4b. GPU 时钟上限。GMU 开机就投**最高**那一档（a6xx_gmu_init 把
    #     current_perf_index 设成 nr_gpu_freqs - 1），所以每一档都必须真能投出去，
    #     否则 GPU 根本起不来 —— 不是「慢」，是 adreno_load_gpu 直接 -110。
    #     2026-10-23 真机实测：留着 925 MHz 时 GMU 固件加载、HFI 握手都过，但第一次
    #     GX 投票 HFI_H2F_MSG_GX_BW_PERF_VOTE 无响应，gfx 电源域停在 off-0，
    #     于是 Turnip 拿不到 GPU ID、gamescope 找不到 Vulkan 设备退出、sddm
    #     Relogin 死循环 —— 表现就是全程黑屏。650 MHz 往上那九档要的 RPMh level
    #     在 NOM 之上（0x140 起，587 MHz 是 0x100），正是
    #     sm8250-ayaneo-pocketmicro2.dts 删掉的同一批。
    opp_hz = []
    for path, props in tree:
        if "opp-hz" not in props or "/gpu@" not in path:
            continue
        words = (fdt(dtb, "-tx", path, "opp-hz") or "").split()
        if len(words) == 2:
            opp_hz.append((int(words[0], 16) << 32) | int(words[1], 16))
    if not opp_hz:
        check(False, "GPU 时钟上限", "在 gpu@ 底下找不到任何带 opp-hz 的档位")
    else:
        top = max(opp_hz)
        over = sorted(h for h in opp_hz if h > GPU_MAX_HZ)
        check(not over, "GPU 时钟上限",
              "最高 %d MHz（%d 档，上限 %d MHz）" % (top // 10**6, len(opp_hz),
                                                    GPU_MAX_HZ // 10**6)
              if not over else
              "超上限 %d MHz 的档位: %s —— GMU 会投最高那档并超时，GPU 起不来"
              % (GPU_MAX_HZ // 10**6, ", ".join("%d MHz" % (h // 10**6) for h in over)))

    # 4c. 扬声器后端必须是 TERTIARY_TDM_RX_0，而且 TDM 帧参数必须写全。
    #
    #     这一条的结论和它上一版正好相反（上一版断言「后端不许是 TDM」），
    #     所以理由要写明白，否则下一个人会把它再翻回去。
    #
    #     上一版的观察没错：sm8250_snd_startup 当时只认 MI2S 端口，从不调用
    #     snd_soc_dai_set_tdm_slot()，于是 TDM 后端的槽数与槽宽恒为 0，ADSP
    #     直接拒收，PCM 连打不开：
    #       qcom-q6afe: AFE enable for port 0x9020 failed -22
    #       q6afe-dai: ASoC error (-22): at snd_soc_dai_prepare() on TERTIARY_TDM_RX_0
    #     错的是从那里得出的结论 —— 把后端换成 MI2S 绕开它。这块板子上
    #     MI2S 绕不过去，因为两颗功放的 ASP_SDIN 接在 mi2s2_data1（gpio137）
    #     上，而 sm8250.dtsi 的 tert_mi2s_active 只有 gpio133/134/135，
    #     qcom,sd-lines = <0> 驱动的 gpio134 是功放把 VI sense 送回 SoC 的
    #     方向。结果是一张**每一项都查得过、而且完全不出声**的声卡：
    #     cs35l41_global_enable 的 PUP_DONE 轮询成功（没有有效位时钟它做不到）、
    #     IRQ1_STATUS3 的 PLL_LOCK 置位、GLOBAL_EN/AMP_EN/DAC_PCM1_SRC/
    #     SP_FRAME_RX_SLOT/REFCLK_INPUT 全对、IRQ1_STATUS1 一个故障都没记下，
    #     而功放一点功率都不输出 —— 放着粉噪声把 Analog PCM Volume 在 0 和 16
    #     之间来回切，电池电流毫无变化。2026-10-24 真机实测。
    #
    #     正确做法是给 machine driver 补上 TDM（补丁 0027）并把 DT 里那几个
    #     帧参数真的送到 ADSP（补丁 0026），后端留在 TDM。
    dais = [(p, pr) for p, pr in tree
            if "/service@4/dais/dai@" in p and "reg" in pr]
    if not dais:
        check(False, "音频后端端口", "q6afedai（service@4）底下找不到任何带 reg 的 dai 节点")
    else:
        ids = {}
        for path, _ in dais:
            ids[int(fdt(dtb, "-ti", path, "reg"))] = path
        check(SPEAKER_PORT_ID in ids, "扬声器后端",
              "有 TERTIARY_TDM_RX_0（%d）" % SPEAKER_PORT_ID
              if SPEAKER_PORT_ID in ids else
              "缺 TERTIARY_TDM_RX_0（%d）；现有端口 %s —— MI2S 驱动的是功放的"
              "回传线，不出声" % (SPEAKER_PORT_ID, sorted(ids)))
        if SPEAKER_PORT_ID in ids:
            spk = ids[SPEAKER_PORT_ID]
            bad = []
            for prop, want in sorted(EXPECT_TDM_PROPS.items()):
                got = fdt(dtb, "-ti", spk, prop)
                if got is None or int(got) != want:
                    bad.append("%s=%s（要 %d）"
                               % (prop, "缺" if got is None else got, want))
            check(not bad, "TDM 帧参数",
                  "%d 项齐全" % len(EXPECT_TDM_PROPS) if not bad
                  else "；".join(bad))

    # 4d. 同一个 pinctrl state 里不许有两个子节点认领同一个引脚。
    #
    #     这条是被真机咬出来的。给我们自己的 state 改名成
    #     `tert-mi2s-active-state` 之后它撞上了 sm8250.dtsi:5880 里**已有**的
    #     同名节点 —— &tlmm 下同名节点会合并，于是 gpio134 在一个 state 里出现
    #     了两次（上游的 data0-pins 和我们的 din-pins，子节点名不同所以没合并）。
    #     pinctrl 拒绝第二次认领：
    #       sm8250-pinctrl: pin GPIO_134 already requested by b7:0
    #       snd-sm8250 sound: error -EINVAL: Error applying setting
    #     后果是整张声卡不注册（/proc/asound/cards 空），而 dtc 编译毫无怨言。
    #
    #     检查做在 DTB 上而不是源码上，正是因为它要抓的就是「合并之后才存在」
    #     的东西 —— 看任何单个 .dts 文件都看不见。
    #     规则比「同一个 state 里引脚不重复」更窄，否则会误报一大片：
    #       - 不同 state 之间共用引脚是正常的（qup-i2c19 与 qup-spi19 是同一组
    #         引脚的两种互斥用法，永远不会同时生效）—— 所以只在**一个 state
    #         内部**比；
    #       - 一个 state 里 `mux { pins; function; }` 和 `config { pins; bias-*; }`
    #         同时点同一个引脚也是正常的，那是高通 DTS 的常见写法：只有带
    #         `function` 的子节点才产生 mux setting、才会去认领引脚，纯 config
    #         的子节点不认领。ts-active 就是这么写的，它工作得很好。
    #     所以判据是：同一个 state 下，**带 function 的子节点**不许重复认领。
    dup = []
    for p, pr in tree:
        if "pins" not in pr or "function" not in pr:
            continue
        state, _, leaf = p.rpartition("/")
        # 直接挂在 pinctrl 控制器下的 state（pins 写在 state 自己身上）只有
        # 一个 mux setting，内部无从重复。
        if state.count("/") < 3:
            continue
        for pin in (fdt(dtb, "-ts", p, "pins") or "").split():
            STATE_PINS.setdefault(state, {}).setdefault(pin, []).append(leaf)
    for state, pins in sorted(STATE_PINS.items()):
        for pin, owners in sorted(pins.items()):
            if len(owners) > 1:
                dup.append("%s: %s 被 %s 同时认领"
                           % (state.rsplit("/", 1)[1], pin, "+".join(owners)))
    check(not dup, "pinctrl 引脚不重复",
          "%d 个多子节点 state，没有引脚被同一个 state 的两个 mux 子节点认领"
          % len(STATE_PINS) if not dup else "; ".join(dup))

    # 4e. 必须有一个 pinctrl state 把 gpio137 muxed 成 mi2s2_data1。
    #
    #     这是第 4c 条那个「查得过却不出声」故障的直接守卫。时钟脚
    #     （gpio133 sck / gpio135 ws）MI2S 和 TDM 共用，所以功放照样能锁 PLL、
    #     照样能 PUP_DONE、照样一个故障都不报；唯一的区别是数据走哪根线。
    #     少了这一条，把 pinctrl-0 指回 sm8250.dtsi 的 tert_mi2s_active
    #     （只有 133/134/135）是个编译得过、启动得起来、断言全绿的改动。
    owners = []
    for p, pr in tree:
        if "pins" not in pr or "function" not in pr:
            continue
        if SPEAKER_DATA_PIN not in (fdt(dtb, "-ts", p, "pins") or "").split():
            continue
        if (fdt(dtb, "-ts", p, "function") or "") == SPEAKER_DATA_FUNC:
            owners.append(p)
    check(bool(owners), "扬声器数据线",
          "%s 由 %s 配成 %s" % (SPEAKER_DATA_PIN,
                               ", ".join(o.rsplit("/", 2)[-2] for o in owners),
                               SPEAKER_DATA_FUNC)
          if owners else
          "没有任何 pinctrl state 把 %s 配成 %s —— 功放的 ASP_SDIN 接在这根线"
          "上，时钟到了数据不到，声卡每一项都查得过而完全不出声"
          % (SPEAKER_DATA_PIN, SPEAKER_DATA_FUNC))

    # 5. 没有任何 firmware-name 指向固件 kit 不提供的 xiaomi/alioth/ 子目录
    stray = []
    for p, pr in tree:
        if "firmware-name" in pr:
            fw = fdt(dtb, "-ts", p, "firmware-name") or ""
            if "xiaomi/alioth/" in fw:
                stray.append("%s -> %s" % (p, fw))
    check(not stray, "固件路径", "无指向 xiaomi/alioth/ 的 firmware-name"
          if not stray else "；".join(stray))

    # 6. 充电安全。spec §280 原本的裁决是「不加载充电驱动」，理由是社区
    #    PM8150B 驱动会把浮充上限设到约 4.87V（而安全值 4.435V，有鼓包
    #    与起火风险）。2026-10-23 读了实际参与编译的那份驱动
    #    (drivers/power/supply/qcom_pm8150b_charger.c)，这个理由不成立：
    #
    #        rc = clamp(chip->batt_info->voltage_max_design_uv,
    #                   3600000, 4450000);
    #        rc = (rc - 3600000) / 10000;
    #        regmap_update_bits(..., FLOAT_VOLTAGE_CFG,
    #                           FLOAT_VOLTAGE_SETTING_MASK, rc);
    #
    #    寄存器是 3.6V 起点、10mV 步长（与 Qualcomm 自己 smb5 的
    #    .min_u = 3600000 / .max_u = 4790000 / .step_u = 10000 一致），
    #    而驱动把请求 clamp 在 4.45V —— 正是原厂 Android 的
    #    /sys/class/power_supply/bms/voltage_max_design。
    #
    #    所以这里断言的是真正的安全属性，而不是「必须禁用」：电池节点
    #    声明的最大电压不得超过 4.45V，充电电流上限必须显式写出，启用的
    #    charger 必须指向电池节点。把 4.9V 写进电池节点这种改动会被挡住。
    #
    #    按全局唯一的 simple-battery 节点来断言，而不是去解
    #    monitored-battery 的 phandle —— 下面那条 len == 1 把「只有一个
    #    电池节点」这个前提钉住。
    MAX_BATT_UV = 4450000
    MAX_BATT_UA = 3000000

    def u32(path, prop):
        words = (fdt(dtb, "-tx", path, prop) or "").split()
        return int(words[0], 16) if len(words) == 1 else None

    batts = [p for p, pr in tree if "simple-battery" in compat_of(p, pr)]
    check(len(batts) == 1, "电池节点唯一",
          "找到 %d 个 simple-battery%s" % (len(batts),
                                           "：" + "、".join(batts) if batts else ""))
    for p in batts:
        uv = u32(p, "voltage-max-design-microvolt")
        check(uv is not None and uv <= MAX_BATT_UV, "电池最大电压",
              "%s voltage-max-design-microvolt=%s（上限 %d）"
              % (p, uv, MAX_BATT_UV))
        ua = u32(p, "constant-charge-current-max-microamp")
        check(ua is not None and 0 < ua <= MAX_BATT_UA, "充电电流上限显式",
              "%s constant-charge-current-max-microamp=%s（上限 %d）"
              % (p, ua, MAX_BATT_UA))

    chargers = [(p, pr) for p, pr in tree if "charger" in compat_of(p, pr)]
    if not chargers:
        check(False, "charger", "找不到 compatible 含 charger 的节点")
    for p, pr in chargers:
        st = fdt(dtb, "-ts", p, "status") if "status" in pr else "(无 status)"
        if st == "disabled":
            check(True, "charger " + p, "status=disabled —— 不参与充电")
            continue
        check("monitored-battery" in pr, "charger " + p,
              "status=%r，%s monitored-battery"
              % (st, "有" if "monitored-battery" in pr else "缺"))

    # 7. 驱动与 DTS 的 compatible 交叉断言
    dtb_compats = set()
    for path, props in tree:
        if "compatible" in props:
            dtb_compats.update((fdt(dtb, "-ts", path, "compatible") or "").split())
    for ko in mods:
        compats = module_of_compats(ko)
        name = ko.split("/")[-1]
        if compats is None:
            check(False, "模块 " + name, "modinfo 读不出来")
        elif not compats:
            check(False, "模块 " + name,
                  "没有 of: 别名 —— 驱动缺 .of_match_table，=m 时 udev 不会自动加载")
        else:
            # 至少命中一个就够。一个驱动会声明它支持的**全部**型号
            # （snd-soc-cs35l41-i2c 同时报 cirrus,cs35l40 和 cs35l41，
            # pci-pwrctrl-pwrseq 报 pci17cb,1101/1103/1107），而一块板子
            # 只会有其中一两个。要求全中必然假失败。真正会静默失效的是
            # 一个都不中：模块装上了，节点也在，谁都不认识谁。
            hit = sorted(compats & dtb_compats)
            check(bool(hit), "模块 " + name,
                  "命中 %s（模块共声明 %d 个）" % (", ".join(repr(c) for c in hit), len(compats))
                  if hit else
                  "声明的 %d 个 compatible 在 DTB 里一个都没有: %s"
                  % (len(compats), ", ".join(sorted(compats))))

    # 8. simpledrm 的 bootloader splash framebuffer。
    #    这是阶段 1 最早的一条观测通道（msm DRM 接手之前就有画面）。
    #    真正要断言的不是格式，而是**包含关系**：simplefb 会直接往这段物理
    #    内存写，如果它没有被 reserved-memory 挡住，内核会把同一段内存分给
    #    别人，表现是随机的内存损坏 —— 和「屏幕没输出」完全不像同一个 bug。
    fbs = [(p, pr) for p, pr in tree if "simple-framebuffer" in compat_of(p, pr).split()]
    if len(fbs) != 1:
        check(False, "simple-framebuffer", "找到 %d 个节点（期望 1）" % len(fbs))
    else:
        fbpath, fbprops = fbs[0]
        fb = reg_of(dtb, fbpath)
        if fb is None:
            check(False, "simple-framebuffer reg", "%s 的 reg 读不出来" % fbpath)
        else:
            base, size = fb
            check((base, size) == (FB_BASE, FB_SIZE), "framebuffer reg",
                  "%s reg=<0x%x 0x%x>（期望 <0x%x 0x%x>）"
                  % (fbpath, base, size, FB_BASE, FB_SIZE))
            for prop, want in (("width", FB_W), ("height", FB_H), ("stride", FB_W * 4)):
                got = fdt(dtb, "-ti", fbpath, prop) if prop in fbprops else None
                check(got == str(want), "framebuffer " + prop,
                      "%s=%s（期望 %d）" % (prop, got, want))
            fmt = fdt(dtb, "-ts", fbpath, "format") if "format" in fbprops else None
            check(fmt == FB_FORMAT, "framebuffer format",
                  "%r（期望 %r）" % (fmt, FB_FORMAT))

            # 包含关系：找一个 no-map 的预留区把 [base, base+size) 完整盖住。
            covering = []
            for p, pr in tree:
                if not p.startswith("/reserved-memory/") or "no-map" not in pr:
                    continue
                r = reg_of(dtb, p)
                if r and r[0] <= base and base + size <= r[0] + r[1]:
                    covering.append("%s <0x%x 0x%x>" % (p, r[0], r[1]))
            check(bool(covering), "framebuffer 已预留",
                  "被 %s 覆盖" % covering[0] if covering
                  else "没有 no-map 预留区覆盖 [0x%x, 0x%x) —— simplefb 会写到"
                       "内核分给别人的内存上" % (base, base + size))

    print()
    if fails:
        print("%d 条断言失败: %s" % (len(fails), ", ".join(fails)))
        return 1
    print("全部断言通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
