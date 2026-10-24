#!/usr/bin/env python3
"""断言 alioth 的开机模块清单与音频 UCM 自洽。

这个项目被 "=m 在没有 rootfs 时等于没有" 坑过三次（FSA4480、SDAM、
PCI_PWRCTRL_PWRSEQ）。阶段 2 有了 rootfs，=m 可以靠 modules-load.d 加载 ——
前提是清单里的名字**真的对应一个编出来的 .ko**。写错一个字母，modprobe
静默失败，表现为「WiFi 没了」或者「没有声卡」，离原因很远。第 4 条断言
就是守这个的。

照 scripts/assert-alioth-dtb.py 的样式：PASS/FAIL 加证据，结尾汇总，
任一失败退出非零。

用法: python3 scripts/assert-alioth-modules.py [overlay-dir] [modules-dir]
"""

from __future__ import annotations

import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OVL = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "alioth-overlay")
MODLIST = os.path.join(OVL, "usr/lib/modules-load.d/alioth.conf")
UCMDIR = os.path.join(OVL, "usr/share/alsa/ucm2")
DTS = os.path.join(ROOT, "external-and-mods/kernel-sm8250/dts/sm8250-xiaomi-alioth.dts")

if len(sys.argv) > 2:
    MODTREE = sys.argv[2]
else:
    found = glob.glob(os.path.join(ROOT, "work/kernel-sm8250/output/*/modules/*/modules.dep"))
    MODTREE = os.path.dirname(found[0]) if found else ""

fails = 0


def check(name: str, ok: bool, evidence: str) -> None:
    global fails
    print(f"{'PASS' if ok else 'FAIL'}  {name} — {evidence}")
    if not ok:
        fails += 1


def listed_modules() -> list[str]:
    try:
        with open(MODLIST, encoding="utf-8") as fh:
            return [ln.strip() for ln in fh
                    if ln.strip() and not ln.lstrip().startswith("#")]
    except FileNotFoundError:
        return []


def dts_sound_model() -> str:
    """取 &sound 节点的 model —— UCM 按声卡名查找，声卡名来自这里。"""
    try:
        src = open(DTS, encoding="utf-8").read()
    except FileNotFoundError:
        return ""
    i = src.find("&sound {")
    if i < 0:
        return ""
    depth, j = 0, i
    while j < len(src):
        if src[j] == "{":
            depth += 1
        elif src[j] == "}":
            depth -= 1
            if depth == 0:
                break
        j += 1
    m = re.search(r'model\s*=\s*"([^"]+)"', src[i:j])
    return m.group(1) if m else ""


mods = listed_modules()

# 1. pci-pwrctrl-pwrseq。阶段 1 实测：不加载它就没有 PCIe 总线，WiFi 和蓝牙
#    一起消失，症状是「总线上什么都没有」，看着像硬件坏了。没有任何东西
#    依赖它（隐藏 tristate，值由 ath11k 的 select 决定），所以必须显式列出。
check("pci-pwrctrl-pwrseq 在清单里", "pci-pwrctrl-pwrseq" in mods,
      "已列出" if "pci-pwrctrl-pwrseq" in mods
      else f"{MODLIST} 里没有 —— 没有它就没有 PCIe 总线，WiFi 和蓝牙一起没")

# 2. WiFi 与蓝牙。
want_net = ["ath11k_pci", "hci_uart", "btqca", "bluetooth"]
miss = [m for m in want_net if m not in mods]
check("WiFi 与蓝牙模块", not miss,
      "ath11k_pci / hci_uart / btqca / bluetooth 都在" if not miss
      else f"缺少 {', '.join(miss)}")

# 3. 音频。声卡是 qcom,sm8250-sndcard，唯一的 codec 链路接两颗 CS35L41
#    功放（DTS speaker-dai-link）。少了功放驱动，codec 永远不 probe，
#    DAI link 配不齐，**整张声卡都不注册** —— 不是「没有扬声器」。
want_audio = ["snd-soc-sm8250", "snd-soc-cs35l41-i2c"]
miss_a = [m for m in want_audio if m not in mods]
check("音频模块", not miss_a,
      "snd-soc-sm8250 与 snd-soc-cs35l41-i2c 都在" if not miss_a
      else f"缺少 {', '.join(miss_a)}")

# 4. 清单里的每个名字都要对应一个真编出来的 .ko。拼错一个字母 modprobe
#    静默失败，没有任何提示。
if not mods:
    check("模块都真的编出来了", False, f"{MODLIST} 是空的或不存在")
elif not MODTREE or not os.path.isdir(MODTREE):
    check("模块都真的编出来了", False,
          "找不到构建好的模块树（work/kernel-sm8250/output/*/modules/*），无法核实")
else:
    built = set()
    for dirpath, _, names in os.walk(MODTREE):
        for n in names:
            if n.endswith(".ko"):
                built.add(n[:-3].replace("_", "-"))
    absent = [m for m in mods if m.replace("_", "-") not in built]
    check("模块都真的编出来了", not absent,
          f"{len(mods)} 个全部在 {os.path.basename(MODTREE)} 里" if not absent
          else f"模块树里没有: {', '.join(absent)}（内核没开这些选项，或名字写错）")

# 5. UCM 的文件名必须等于 &sound 的 model。ALSA 按声卡名找 UCM；声卡名由
#    机器驱动从这个 model 取。两边一旦不一致，UCM 根本不会被加载，表现为
#    「有声卡但没有声音」。AYANEO 的先例：根 model 是 "AYANEO Pocket MICRO 2"，
#    而 &sound 的 model 是 "PocketMICRO2"，UCM 文件就叫 PocketMICRO2.conf。
model = dts_sound_model()
if not model:
    check("UCM 文件名 = 声卡名", False, f"没能从 {os.path.basename(DTS)} 的 &sound 里读到 model")
else:
    want = os.path.join(UCMDIR, "conf.d/sm8250", f"{model}.conf")
    check("UCM 文件名 = 声卡名", os.path.isfile(want),
          f"conf.d/sm8250/{model}.conf 存在，与 &sound 的 model 一致" if os.path.isfile(want)
          else f"缺 conf.d/sm8250/{model}.conf（&sound 的 model 是 {model!r}）")

# 6. UCM 里 File "..." 指到的、属于我们自己 overlay 的那些文件要真的存在。
#    指不到的 File 会让 UCM 加载整个失败。以 / 开头的路径是相对 ucm2 根的。
refs, missing_refs = 0, []
for conf in glob.glob(os.path.join(UCMDIR, "**/*.conf"), recursive=True):
    for ref in re.findall(r'File\s+"([^"]+)"', open(conf, encoding="utf-8").read()):
        rel = ref.lstrip("/")
        # /lib/ 与 /codecs/ 来自 Valve 镜像自带的 alsa-ucm-conf，不在本 overlay 里
        if rel.startswith(("lib/", "codecs/")):
            continue
        refs += 1
        if not os.path.isfile(os.path.join(UCMDIR, rel)):
            missing_refs.append(f"{os.path.basename(conf)} → {ref}")
check("UCM 内部引用都指得到", not missing_refs,
      f"{refs} 处引用全部命中" if not missing_refs
      else f"指不到: {'; '.join(missing_refs)}")

print()
if fails:
    print(f"{fails} 条断言失败")
    sys.exit(1)
print("全部断言通过")
