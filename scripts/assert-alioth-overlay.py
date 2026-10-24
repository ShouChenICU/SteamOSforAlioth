#!/usr/bin/env python3
"""断言 alioth-overlay/ 的 InputPlumber 配置满足 spec §7.1。

每条断言对应一个会静默失效的决定 —— InputPlumber 不会因为配置写错而报错，
它只是**不匹配**，于是手柄以原始蓝牙设备的身份进入 Steam：按键图标是 Xbox
而不是 Deck、社区 Deck 配置套不上、快捷菜单呼不出来。症状离原因很远。

照 scripts/assert-alioth-dtb.py 的样式：每条打印 PASS/FAIL 加证据，结尾汇总，
任一失败退出非零。本仓库没有 tests/ 也没有 pytest。

用法: python3 scripts/assert-alioth-overlay.py [overlay-dir]
"""

from __future__ import annotations

import glob
import re
import io
import os
import sys

import yaml

OVL = sys.argv[1] if len(sys.argv) > 1 else "alioth-overlay"
DEVICES = os.path.join(OVL, "etc/inputplumber/devices.d/02-xiaomi-alioth.yaml")
KEYMAP = os.path.join(OVL, "etc/inputplumber/capability_maps.d/alioth_keys.yaml")
RULES = os.path.join(OVL, "usr/lib/udev/rules.d/70-alioth.rules")
DROPIN_DIR = os.path.join(OVL, "etc/systemd/user/gamescope-session.target.d")
# steamos-overlay 的这个 drop-in 把 Wants= 清空后只留 steam 那三个，所以我们
# 加 Wants= 的 drop-in 必须按文件名排在它**后面**。见下面第 7 条。
VENDOR_DROPIN = "99-odin.conf"
# steamos-overlay 的会话脚本。alioth 用的是 Valve 镜像里**原版**的 gamescope，
# 不是本项目补丁过的那份，所以不能无条件传补丁版独有的参数。见下面第 8 条。
SESSION = "steamos-overlay/usr/lib/steamos/gamescope-session"
PATCHED_ONLY_ARG = "--use-rotation-shader"

# 触摸的 libinput 校准矩阵。gamescope 以 2400x1080 横向合成，面板物理是
# 1080x2400 竖屏，所以归一化触摸坐标要从 (nx, ny) 变成 (ny, 1 - nx)。
# 2026-10-23 真机实测确认的值。
TOUCH_MATRIX = "0 1 0 -1 0 1"
# steamos-powerbuttond 按这个 udev 属性找电源键，见下面第 6 条。
POWER_ENV = "STEAMOS_POWER_BUTTON"

# DTB 的 model，由 scripts/assert-alioth-dtb.py 断言为这个值。InputPlumber 靠
# /sys/firmware/devicetree/base/model 匹配，所以两边必须逐字相同。
DT_MODEL = "Xiaomi Poco F3"

fails = 0


def check(name: str, ok: bool, evidence: str) -> None:
    global fails
    print(f"{'PASS' if ok else 'FAIL'}  {name} — {evidence}")
    if not ok:
        fails += 1


def load(path: str):
    with open(path, encoding="utf-8") as fh:
        return yaml.safe_load(fh)


# 1. 匹配条件必须逐字等于 DTB 的 model。
try:
    dev = load(DEVICES)
    dumped = yaml.dump(dev, allow_unicode=True)
    check("device model 匹配", DT_MODEL in dumped,
          f"{DEVICES} {'含' if DT_MODEL in dumped else '不含'} {DT_MODEL!r}")
except FileNotFoundError:
    check("device model 匹配", False, f"没有 {DEVICES}")
    dumped = ""

# 2. alioth 没有物理摇杆。抄掌机配置时最容易留下的就是 joystick 源，
#    而一个匹配不到的源会让整个 CompositeDevice 不生效。
check("无物理摇杆源", bool(dumped) and "joystick" not in dumped.lower(),
      "未出现 joystick" if dumped and "joystick" not in dumped.lower()
      else "出现了 joystick 源，或文件缺失")

# 3. 音量键是这台机器上仅有的两个可用按键（spec §7.1）：
#    音量上 → Steam 键 (Guide)，音量下 → 快捷菜单 (QuickAccess)。
try:
    km = yaml.dump(load(KEYMAP), allow_unicode=True)
    check("音量上 → Guide", "Guide" in km, "capability map 含 Guide" if "Guide" in km
          else "capability map 里没有 Guide")
    check("音量下 → QuickAccess", "QuickAccess" in km,
          "capability map 含 QuickAccess" if "QuickAccess" in km
          else "capability map 里没有 QuickAccess")
except FileNotFoundError:
    check("音量上 → Guide", False, f"没有 {KEYMAP}")
    check("音量下 → QuickAccess", False, f"没有 {KEYMAP}")

# 5. 触摸坐标变换。gamescope 的 --force-composition-rotation 只决定旋转在哪
#    做（合成器还是扫描输出），**不设角度**，所以 gamescope 并不知道面板朝向，
#    也就不会去变换触摸坐标。2026-10-23 真机实测：画面方向正确，但触摸相对
#    界面逆时针偏 90 度 —— 点按钮点不中，任何点击和滑动都被当成手势，表现是
#    「一碰就回主页」。修在 libinput 这一层（校准矩阵）而不是 gamescope 参数，
#    因为前者不动画面，而 --force-orientation 会把已经正确的输出再转一次。
try:
    rules = io.open(RULES, encoding="utf-8").read()
except OSError:
    rules = ""
    check("触摸校准矩阵", False, f"没有 {RULES}")
    check("电源键标记", False, f"没有 {RULES}")
else:
    want = f'ENV{{LIBINPUT_CALIBRATION_MATRIX}}="{TOUCH_MATRIX}"'
    check("触摸校准矩阵", want in rules,
          f"70-alioth.rules 里有 {TOUCH_MATRIX}" if want in rules
          else f"缺 {want} —— 触摸会相对界面偏 90 度")

    # 6. 电源键。steamos-powerbuttond 用 udev 枚举 input/event*，然后只认带
    #    STEAMOS_POWER_BUTTON 这个属性的设备（它的二进制里一共只有 "event*"、
    #    "input" 和 "STEAMOS_POWER_BUTTON" 三个筛选字符串）。alioth 的
    #    pm8941_pwrkey 没有任何通用规则给它打这个标，于是守护进程枚举完所有
    #    设备后**直接以 0 退出** —— 不报错、journal 里一行都没有，表现是电源键
    #    完全没反应：不熄屏、不弹关机菜单。2026-10-23 真机实测，补上属性后它
    #    打印 "Found power button device at /dev/input/event0"。
    has_pwr = POWER_ENV in rules and "pm8941_pwrkey" in rules
    check("电源键标记", has_pwr,
          f"70-alioth.rules 给 pm8941_pwrkey 打了 {POWER_ENV}" if has_pwr
          else f"缺 {POWER_ENV}（pm8941_pwrkey）—— 守护进程会静默退出，电源键无反应")


# 7. drop-in 的排序。systemd 按文件名字典序合并 drop-in，而
#    steamos-overlay 的 gamescope-session.target.d/99-odin.conf 里有一条空的
#    `Wants=`（重置 Frame 那一串 steamvr 依赖）。排在它之前的 drop-in 加的
#    Wants= 会被整条清掉 —— systemd 对此一声不吭，表现是电源键在 Game Mode
#    里没反应。原来的名字 99-alioth-powerbuttond.conf 正好排在 99-odin.conf
#    之前，一直是靠 sm8250-overlay 的 99-sm8250-powerbuttond.conf（排在后面）
#    偶然救回来的；单独装 alioth-overlay 就会失灵。
pbd = sorted(os.path.basename(f) for f in glob.glob(os.path.join(DROPIN_DIR, "*.conf")))
late = [f for f in pbd if f > VENDOR_DROPIN]
check("drop-in 排在厂商 drop-in 之后", bool(pbd) and len(late) == len(pbd),
      f"{', '.join(pbd)} 都排在 {VENDOR_DROPIN} 之后" if pbd and len(late) == len(pbd)
      else (f"{', '.join(f for f in pbd if f not in late)} 排在 {VENDOR_DROPIN} 之前"
            f" —— Wants= 会被它清掉" if pbd else f"{DROPIN_DIR} 下没有 drop-in"))


# 8. 补丁版独有的 gamescope 参数必须先探测再用。
#    --use-rotation-shader 只存在于本项目补丁过的 gamescope。alioth 按
#    spec §4 原样用 Valve 镜像里的 gamescope 3.16.30，它不认这个参数 ——
#    而且不是忽略，是**退出**：
#      gamescope: unrecognized option '--use-rotation-shader'
#    于是 gamescope-session.service 每轮都失败，sddm 反复重登，屏幕全程不亮。
#    2026-10-23 真机实测；原版支持的等价参数是 --force-composition-rotation。
try:
    session = io.open(SESSION, encoding="utf-8").read()
except OSError:
    check("补丁版参数先探测", False, f"没有 {SESSION}")
else:
    if PATCHED_ONLY_ARG not in session:
        check("补丁版参数先探测", True, f"会话脚本不传 {PATCHED_ONLY_ARG}")
    else:
        # 探测的形态：先问 gamescope --help 有没有这个参数，没有就退回原版参数。
        probed = ("gamescope --help" in session
                  and "--force-composition-rotation" in session)
        check("补丁版参数先探测", probed,
              f"{PATCHED_ONLY_ARG} 由 gamescope --help 探测后才用" if probed
              else f"无条件传了 {PATCHED_ONLY_ARG} —— 原版 gamescope 会直接退出")


# 9. NTP 服务器。Valve 镜像里 /etc/systemd/timesyncd.conf 的 [Time] 全是
#    注释，timesyncd 只能回落到编译期的 arch 池；真机实测（2026-10-24，设备
#    连上 WiFi 后）那些域名在这张网上一个都解析不出来，timesyncd 卡在
#    "Idle."，`System clock synchronized: no`。
#
#    这和 usr/lib/clock-epoch 是两件事，缺一不可：clock-epoch 只保证开机时间
#    不早于构建日期（挡住 PAM 的 "password changed in future" 和「证书尚未
#    生效」），它管不了时间**偏后**或慢慢漂 —— 真机实测时钟差了整一天。
#    Steam Guard 和临期证书都吃这个。
#
#    所以服务器列表要跨得过去：全球通用的排前面，中国大陆能解析的排后面，
#    timesyncd 按顺序试，解析不出来的直接跳过。真机实测这个列表能同步上
#    （Contacted time server … (cn.pool.ntp.org)）。
ntp_conf = os.path.join(OVL, "etc/systemd/timesyncd.conf.d/50-alioth-ntp.conf")
if not os.path.isfile(ntp_conf):
    check("NTP 服务器", False, f"没有 {ntp_conf}")
else:
    body = open(ntp_conf, encoding="utf-8").read()
    # 必须是 NTP=（而不是只写 FallbackNTP=）：FallbackNTP 只在 NTP= 为空
    # **且**编译期默认也为空时才轮得到，而这个镜像的编译期默认不为空 ——
    # 写 FallbackNTP= 根本不会被用上。
    line = [l for l in body.splitlines() if l.strip().startswith("NTP=")]
    servers = line[0].split("=", 1)[1].split() if line else []
    check("NTP 服务器", len(servers) >= 2 and "[Time]" in body,
          f"NTP= 列了 {len(servers)} 个: {' '.join(servers)}" if servers
          else f"{ntp_conf} 里没有 NTP= 一行（只有 FallbackNTP= 的话不会生效）")


# 3a. Frame 专属的两个 wireplumber 脚本都必须被 disable 掉。两个都会让
#     wireplumber 以 SIGSEGV 死在启动里，而后果都不是「少了个功能」而是
#     「整个会话管理器起不来，唯一的 sink 是 Dummy Output」：
#       steamos.spatial-node-config  要 /usr/lib/ladspa/vraudiocompositor.so，
#                                    这个 rootfs 里没有
#       steamos.microphone-tracker   hardcode 了
#                                    alsa_output.platform-sound.HiFi__Speaker__sink
#                                    （正是这台手机产出的节点名）和一个
#                                    不存在的 mic source
#     两个都被上游标成 "required"，所以少 disable 一个就是每次开机崩溃 5 次。
vr_conf = os.path.join(
    OVL, "etc/wireplumber/wireplumber.conf.d/75-alioth-no-frame-scripts.conf")
WANT_DISABLED = ("steamos.spatial-node-config", "steamos.microphone-tracker")
if not os.path.isfile(vr_conf):
    check("Frame 脚本已禁用", False, f"没有 {vr_conf}")
else:
    body = open(vr_conf, encoding="utf-8").read()
    not_off = [c for c in WANT_DISABLED
               if not re.search(r'"%s"\s*=\s*"disabled"' % re.escape(c), body)]
    check("Frame 脚本已禁用", not not_off,
          "两个都是 disabled: " + ", ".join(WANT_DISABLED) if not not_off
          else "还没 disable: " + ", ".join(not_off))


# 3b. WirePlumber 必须被告知这个 PCM 的条件。少了它 WirePlumber 根本建不出
#     sink（日志：Failed to create ALSA node alsa_output.platform-sound.
#     playback.0.0: Object activation aborted），`wpctl status` 里唯一的
#     sink 是 "Dummy Output"，而所有程序都往那里放 —— 没有任何一句话提到
#     period size 或采样格式。
#
#     三件事缺一不可：
#       use-acp      Frame 的 50-alsa-config.conf 把 ACP 关了，而 ACP 正是
#                    读 UCM 的那一半。关着的话 WirePlumber 根本不看我们的
#                    UCM，改去枚举裸 PCM —— 于是它会去给一张没有采集 PCM
#                    的卡建 alsa_input...capture.0.0，然后 SEGV。
#       period-size  那个文件还要 256 帧，而这个 PCM 的下限是 480
#                    （aplay --dump-hw-params: PERIOD_SIZE [480 3360]）。
#       audio.format UCM 有 PlaybackRate / PlaybackChannels，但没有采样格式
#                    的键。内核把这些后端钉在 S16LE。
wp_conf = os.path.join(
    OVL, "etc/wireplumber/wireplumber.conf.d/76-alioth-alsa.conf")
if not os.path.isfile(wp_conf):
    check("WirePlumber ALSA 规则", False, f"没有 {wp_conf}")
else:
    body = open(wp_conf, encoding="utf-8").read()
    want_card = "alsa_card.platform-sound" in body
    want_acp = re.search(r"api\.alsa\.use-acp\s*=\s*true", body)
    want_fmt = re.search(r'audio\.format\s*=\s*"S16LE"', body)
    m = re.search(r"api\.alsa\.period-size\s*=\s*(\d+)", body)
    psize = int(m.group(1)) if m else 0
    missing = []
    if not want_card:
        missing.append("没有匹配 alsa_card.platform-sound")
    if not want_acp:
        missing.append("没有 api.alsa.use-acp = true —— ACP 关着 UCM 就不会被读")
    if not want_fmt:
        missing.append('没有 audio.format = "S16LE"')
    if psize < 480:
        missing.append(f"period-size={psize or '缺'}，低于这个 PCM 的下限 480")
    check("WirePlumber ALSA 规则", not missing,
          f"ACP 打开、S16LE、period-size={psize}" if not missing
          else "; ".join(missing))


# 4. 整棵 overlay 的 YAML 都要能解析。一个语法错会让 InputPlumber 跳过该文件，
#    并且它不把这当作致命错误 —— 没有任何提示。
bad = []
found = sorted(glob.glob(os.path.join(OVL, "**/*.yaml"), recursive=True))
for path in found:
    try:
        load(path)
    except yaml.YAMLError as exc:
        bad.append(f"{path}: {str(exc).splitlines()[0]}")
check("全部 YAML 可解析", bool(found) and not bad,
      f"{len(found)} 个文件全部解析通过" if found and not bad
      else (f"解析失败: {'; '.join(bad)}" if bad else f"{OVL} 下一个 yaml 都没有"))

# 听筒（RCV）的模拟增益必须严格小于底部主扬声器（LCV）。这一条是一次真实
# 硬件损伤换来的：两颗给了同一个 +18.5 dB，满刻度信号把听筒烧出了糊味。
# CS35L41 的过温保护测的是芯片结温，音圈没有传感器 —— 那次六个故障位一个
# 都没亮。所以这两档增益是唯一的护栏，而护栏需要有人看着它还在。
HIFI = os.path.join(OVL, "usr/share/alsa/ucm2/Xiaomi/Alioth/HiFi.conf")
gains = {}
if os.path.exists(HIFI):
    with open(HIFI, encoding="utf-8") as fh:
        for line in fh:
            if line.lstrip().startswith("#"):
                continue
            m = re.search(r"""name='(RCV|LCV) Analog PCM Volume'\s+(\d+)""", line)
            # DisableSequence 也会命中，它把两颗都归零 —— 取第一次出现的，
            # 也就是 EnableSequence 里那一对。
            if m and m.group(1) not in gains:
                gains[m.group(1)] = int(m.group(2))
check("听筒增益低于主扬声器", len(gains) == 2 and gains["RCV"] < gains["LCV"],
      f"RCV={gains.get('RCV')} LCV={gains.get('LCV')}" if len(gains) == 2
      else f"在 {HIFI} 里没找到两颗功放的 Analog PCM Volume（找到 {gains}）")

# 光有「RCV < LCV」不够 —— 它只管两颗的相对关系，不管绝对值。独立审查给的
# 反例：把 HiFi.conf 改成 RCV 19 / LCV 20，顺序仍然成立，断言照样全绿，而
# 那是听筒 +19.5 dB，比烧出糊味那次（18 → +18.5 dB）还高 1 dB。
#
# 控件的刻度：SOC_SINGLE_TLV(..., CS35L41_AMP_GAIN_CTRL, 5, 0x14, 0,
# amp_gain_tlv) 配 DECLARE_TLV_DB_SCALE(amp_gain_tlv, 50, 100, 0)，也就是
# 档位 n = (0.5 + n) dB，上限 0x14 = +20.5 dB。
#
# 所以这里钉的是绝对上限，取值就是**真机上实测安全的那一对**。往上调不是
# 改配置，是一个硬件决定：这条通路上没有限幅器（没有可再分发的 Cirrus
# wmfw/bin，PCM Source 走 ASP 直通），而 CS35L41 的过温保护测芯片结温，
# 音圈上没有任何传感器 —— 烧那次六个故障位一个都没亮。要动它，先把
# docs/alioth.md 的「事故：把听筒烧出了糊味」读完，然后连这个常数一起改，
# 让下一个人知道有人想过。
GAIN_MAX = {"RCV": 4, "LCV": 10}
over = {k: v for k, v in gains.items() if v > GAIN_MAX[k]}
check("模拟增益不超过实测安全值", len(gains) == 2 and not over,
      f"RCV={gains.get('RCV')}≤{GAIN_MAX['RCV']} LCV={gains.get('LCV')}≤{GAIN_MAX['LCV']}"
      if len(gains) == 2 and not over
      else f"超了: {over}（上限 {GAIN_MAX}，档位 n = 0.5+n dB）" if over
      else f"取不到两颗的增益（找到 {gains}）")

# 增益必须写在 HiFi.conf 的 SectionVerb.EnableSequence 里，不能写在
# Alioth.conf 的 BootSequence 里。BootSequence 要 `alsactl init` /
# `alsaucm boot` 去执行，这台机器上没有任何东西执行它 —— 实测写 721 进去，
# 重启后读回来是 817（芯片复位默认 0 dB）。这个缺陷不报错、不留日志，只是
# 让衰减静悄悄地不生效，所以事故当时的真实增益比我以为的高 12 dB。
CARD = os.path.join(OVL, "usr/share/alsa/ucm2/Xiaomi/Alioth/Alioth.conf")
hifi_src = open(HIFI, encoding="utf-8").read() if os.path.exists(HIFI) else ""
card_src = open(CARD, encoding="utf-8").read() if os.path.exists(CARD) else ""
card_csets = [l.strip() for l in card_src.splitlines()
              if l.strip().startswith("cset")]
check("Alioth.conf 里没有 cset", not card_csets,
      "BootSequence 不执行，所以这里一条 cset 都不该有"
      if not card_csets else f"有 {len(card_csets)} 条: {card_csets[:2]}")
digital = len(re.findall(r"""name='(?:RCV|LCV) Digital PCM Volume'""", hifi_src))
check("数字衰减写在 HiFi.conf 里", digital >= 2,
      f"HiFi.conf 里 {digital} 处 Digital PCM Volume（EnableSequence 两颗各一）")

# 关掉 Frame 的空间音频脚本之后，必须同时把普通应用的权限管理器换成
# steamos-default-nospatial，否则**所有应用都没有声音**且不报任何错：Frame 的
# steamos-default 管理器对 alsa_output.platform-sound.HiFi__Speaker__sink
# 执行 set-permissions = ""，而那正好是这台机器 sink 的节点名（又一次撞名）。
# 应用于是拿不到 l（link）权限，PipeWire 的 check_permission() 回 EPERM，
# 一条链接都建不起来。声卡、sink、路由、UCM 增益全都正常，PCM 却从不打开。
# 这两件事是一件事的两半，所以一起断言。
WPD = os.path.join(OVL, "etc/wireplumber/wireplumber.conf.d")
wp_src = ""
for name in sorted(glob.glob(os.path.join(WPD, "*.conf"))):
    with open(name, encoding="utf-8") as fh:
        wp_src += "".join(l for l in fh if not l.lstrip().startswith("#"))
spatial_off = '"steamos.spatial-node-config" = "disabled"' in wp_src
nospatial_pm = 'permission_manager_name = "steamos-default-nospatial"' in wp_src
check("关了空间音频就选 nospatial 权限管理器", spatial_off == nospatial_pm,
      f"spatial-node-config 被禁={spatial_off}，选了 nospatial 管理器={nospatial_pm}")

print()
if fails:
    print(f"{fails} 条断言失败")
    sys.exit(1)
print("全部断言通过")
