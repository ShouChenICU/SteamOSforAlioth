#!/usr/bin/env python3
"""解码两颗 CS35L41 的 IRQ1_STATUS1，有故障或者**读不到**时退出非零。

从 stdin 读 scripts/alioth-speaker-test.sh 里 probe() 的输出：

    3-0040 00000000
    3-0041 00000000
    battery 380        (可选)

为什么单独一个文件：原来这段解码嵌在听音脚本的一个 heredoc 里，没法喂输入，
于是它的失败模式一直没人验过 —— 2026-10-24 的独立审查发现它**空输入也退出
0**（`bad` 初值 0，解析不出两个字段的行一律跳过）。那意味着 debugfs 没挂、
regmap 调试关了、sudo 要密码、或者播放之后 ssh 没连上，操作者都会读到
「没有故障位」，而事实是一个字节都没读到。拆出来之后
scripts/assert-alioth-speaker-test.sh 能把这些情况逐个喂进来。

退出码：0 两颗都读到了且干净 / 1 有故障位 / 3 读不到或读不全。
"""
import sys

# include/sound/cs35l41.h。bit 22/23 是 PUP_DONE / PDN_DONE，正常的上下电
# 完成标志，**不是**故障 —— 事故那天我正是把 bit 23 的出现当成了可疑信号，
# 而真正的六个故障位一个都没亮。
FAULTS = {6: "BST_OVP", 7: "BST_DCM_UVP", 8: "BST_SHORT",
          15: "TEMP_WARN", 17: "TEMP_ERR", 31: "AMP_SHORT"}

# 两颗功放的 i2c 地址。少一颗就是读不全：RCV 是听筒，LCV 是底部主扬声器，
# 烧掉的那颗是 RCV，所以「只读到 LCV」恰恰是最不能放过的那种残缺。
AMPS = ("3-0040", "3-0041")

seen = {}
bad = 0
malformed = []

for raw in sys.stdin:
    line = raw.strip()
    if not line:
        continue
    f = line.split()
    if len(f) != 2:
        malformed.append(line[:60])
        continue
    if f[0] == "battery":
        try:
            print("  电池 %.1f C" % (int(f[1]) / 10))
        except ValueError:
            malformed.append(line[:60])
        continue
    if f[0] not in AMPS:
        malformed.append(line[:60])
        continue
    try:
        v = int(f[1], 16)
    except ValueError:
        malformed.append(line[:60])
        continue
    seen[f[0]] = v
    hit = [n for b, n in FAULTS.items() if v >> b & 1]
    bad += len(hit)
    print("  %s IRQ1_STATUS1=%#010x %s"
          % (f[0], v, " ".join(hit) if hit else "无故障"))

missing = [a for a in AMPS if a not in seen]
if missing or malformed:
    if missing:
        print("  !! 没读到: %s" % " ".join(missing), file=sys.stderr)
    if malformed:
        print("  !! 读到了认不出来的行: %s" % " | ".join(malformed[:3]),
              file=sys.stderr)
    print("  !! 这不是「没有故障」，这是**没读到**。先把寄存器读通再放音。",
          file=sys.stderr)
    sys.exit(3)

sys.exit(1 if bad else 0)
