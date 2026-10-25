# 放自己的游戏进去（非 Steam 游戏）

这台机器上的 Steam 库之外，还能跑你自己手上的 Windows 游戏 —— 包括很老的那种。
下面这份流程是 2026-10-24 真机走通的，样例是 2003 年的《东方妖妖梦》
（th07，32 位 x86，DirectX 8），从拷文件到主菜单跑起来一共十几分钟。

![东方妖妖梦在 alioth 上](images/custom-game.jpg)

---

## 先确认三件事成立

这三样决定了一个 Windows 程序在这台机器上有没有可能跑起来，装好的系统上就能查：

```sh
P=~/.steam/steam/steamapps/common/"Proton 11.0 (ARM64)"

# 1. 32 位 x86 支持。老游戏基本都是 32 位的。
ls "$P"/files/lib/wine/aarch64-windows/libwow64fex.dll

# 2. 你的游戏那一代图形 API 有没有对应的 DXVK 实现。
ls "$P"/files/lib/wine/dxvk/i386-windows/      # d3d8 d3d9 d3d10 d3d11 dxgi

# 3. 空间。
df -h /
```

`libwow64fex.dll` 是 FEX 的 wow64 路径，32 位 x86 指令经它翻译；少了它，32 位
的 exe 一个都起不来。`dxvk/i386-windows/d3d8.dll` 在，意味着 DirectX 8 会被翻成
Vulkan 交给 Turnip —— 妖妖梦能跑就是靠这两样。

**跑不了的，别浪费时间：**

| 情况 | 为什么 |
|---|---|
| 带 Easy Anti-Cheat / BattlEye 的联机游戏 | 反作弊内核模块在 ARM 上无解，没有变通 |
| 带 Denuvo 的新作 | 在翻译层上经常直接起不来 |
| 重 3D（3A 级） | Adreno 650 + 翻译开销，不现实 |
| 大量视频过场 | 可能缺解码器，症状是黑屏有声 |

---

## 第一步：把文件拷进去

整目录打包走 USB 网口，实测 36 MB/s：

```sh
tar -C "/path/to/游戏目录" -cf - . \
  | scripts/alioth-ssh.sh 'mkdir -p ~/Games/<名字> && tar -C ~/Games/<名字> -xf -'
```

目录名建议用 ASCII，省得之后在 wine 路径里折腾编码。

---

## 第二步：加成 Steam 的非 Steam 游戏

**必须由 Steam 启动。** 这一条不是风格问题：gamescope 的焦点跟着 Steam 的
「当前应用」属性走，自己在 shell 里直接调 Proton 起的进程，窗口上没有 Steam 的
appID，合成器永远不会把它放到前台。症状非常具有迷惑性 —— **能听到游戏的音乐，
但屏幕上还是 Steam 的界面**，而日志里一切正常。

桌面模式下用 Steam 的「添加非 Steam 游戏」最省事。这台机器是 Game Mode only，
所以直接写配置文件：

```python
# 在设备上跑：python3 -I /tmp/add-game.py
import os, struct, zlib, shutil

HOME = os.path.expanduser("~")
UID  = "<你的 userdata 子目录名>"        # ls ~/.steam/steam/userdata/
SC   = f"{HOME}/.steam/steam/userdata/{UID}/config/shortcuts.vdf"

name     = "东方妖妖梦"
exe      = '"/home/steamos/Games/th07/th07.exe"'   # 引号是 Steam 自己的格式，要带上
startdir = '"/home/steamos/Games/th07/"'

appid_u = zlib.crc32((exe + name).encode("utf-8")) | 0x80000000
appid_s = struct.unpack("<i", struct.pack("<I", appid_u))[0]

def s(k, v): return b"\x01" + k.encode() + b"\x00" + v.encode("utf-8") + b"\x00"
def i(k, v): return b"\x02" + k.encode() + b"\x00" + struct.pack("<i", v)

entry = b"".join([
    i("appid", appid_s), s("AppName", name), s("Exe", exe), s("StartDir", startdir),
    s("icon", ""), s("ShortcutPath", ""),
    s("LaunchOptions", "LANG=zh_CN.UTF-8 LC_ALL=zh_CN.UTF-8 %command%"),
    i("IsHidden", 0), i("AllowDesktopConfig", 1), i("AllowOverlay", 1),
    i("OpenVR", 0), i("Devkit", 0), s("DevkitGameID", ""),
    i("DevkitOverrideAppID", 0), i("LastPlayTime", 0), s("FlatpakAppID", ""),
    b"\x00tags\x00\x08",
])
blob = b"\x00shortcuts\x00" + b"\x000\x00" + entry + b"\x08\x08\x08"

if os.path.exists(SC): shutil.copy2(SC, SC + ".bak")
open(SC, "wb").write(blob)
print("appid", appid_u)
```

`shortcuts.vdf` 是二进制 VDF：`\x01` 开一个字符串字段，`\x02` 开一个 32 位整数
（小端），`\x00` 开一个子表，`\x08` 收一层。**上面这段是从零写一个新文件** ——
已经有快捷方式的话，先读出来再追加一条，别覆盖（脚本会留 `.bak`）。

`LaunchOptions` 里那个 `LANG=` 是给汉化/日文游戏用的，见下面「中文显示成乱码」
那一节；英文游戏留空就行。

appid 的算法是 Steam 的老规矩：`crc32(Exe + AppName) | 0x80000000`，文件里存的是
它的有符号形式，而配置里引用的是无符号那个。

然后显式给它指定兼容层，别指望默认项：

```python
conf = f"{HOME}/.steam/steam/config/config.vdf"
txt  = open(conf, encoding="utf-8").read()
idx   = txt.find('"CompatToolMapping"')
brace = txt.find("{", idx)
ind   = "\t" * 5
block = (f'\n{ind}"{appid_u}"\n{ind}{{\n{ind}\t"name"\t\t"proton-stable"\n'
         f'{ind}\t"config"\t\t""\n{ind}\t"priority"\t\t"250"\n{ind}}}')
shutil.copy2(conf, conf + ".bak")
open(conf, "w", encoding="utf-8").write(txt[:brace+1] + block + txt[brace+1:])
```

`proton-stable` 就是这台机器上的 Proton 11.0 (ARM64)。

---

## 第三步：让 Steam 重读，然后启动

```sh
scripts/alioth-ssh.sh 'systemctl --user restart steam.service'
```

重启的是 Steam 这一个 unit，不是整个 gamescope 会话 —— 屏幕不会黑，手柄连接也不
掉。Steam 起来之后库里就有这一条了，手柄上直接点开即可。

想从命令行启动的话，gameid 是 appid 左移 32 位再或上 `0x02000000`：

```sh
python3 -c 'print((APPID << 32) | 0x02000000)'
scripts/alioth-ssh.sh 'steam steam://rungameid/<上面那个数>'
```

确认真的在跑（注意 `pkill -f` / `pgrep -f` 会匹配到你自己这条 ssh 命令行，
所以模式里加个方括号）：

```sh
scripts/alioth-ssh.sh 'ps -eo pid,args | grep "th0[7]" | head -3'
```

启动链条应该长这样：`reaper SteamLaunch AppId=…` → `_v2-entry-point` →
`proton waitforexitandrun` → 你的 exe。

---

## 已知的坑

**「有声音，没画面」** —— 没有经 Steam 启动。见第二步。

**中文显示成乱码**（`ó_ɼ¹ÈÊÃÃc…` 这种）—— Proton 前缀是按默认 locale 建的，
ANSI 代码页不是 936。游戏自带的贴图文字不受影响，受影响的是用 ANSI API 画的那
部分，所以症状是「标题和菜单都好好的，只有某几行是乱码」。

修法是用中文 locale **重建前缀**：在 `LaunchOptions` 里加上

```
LANG=zh_CN.UTF-8 LC_ALL=zh_CN.UTF-8 %command%
```

然后**删掉已经建好的前缀**，让它重新生成（不删的话改了也没用，代码页是建前缀时
写进注册表的）：

```sh
scripts/alioth-ssh.sh 'rm -rf ~/.steam/steam/steamapps/compatdata/<appid>'
```

注意字符集写 `UTF-8` 就行，不必是 `GBK` —— 这台机器上根本没有 `zh_CN.GBK` 这个
locale，而 wine 的 ANSI 代码页是按 locale 的**语言/地区**定的，`zh_CN` 即 936。
日文游戏同理，用 `ja_JP.UTF-8` 得到 932。

验证生效：前缀的 `user.reg` 里 `[Control Panel\\International]` 下应该是
`"iCountry"="86"`，`International\\Geo` 下是 `"Name"="CN"`。

**截图截不到性能浮层** —— `gamescopectl screenshot` 只抓基础层。要全合成画面走
gamescope 的调试截图原子，见 [alioth.md](alioth.md) 的「截图：gamescopectl 只抓
基础层」。

**老游戏锁 60 却跑不满** —— 已定位并修掉了。原因是调速器爬坡跟不上：
CPU 的 schedutil 和 GPU 的 simple_ondemand 在帧与帧之间掉频，下一帧再爬。
`alioth-game-tune` 这个服务会在检测到 Steam 游戏 scope 时把两边都切到
performance，游戏退出再切回来，妖妖梦因此从 48.40 回到 60.00（它自己的上限）。
完整的 A/B 见 [alioth.md](alioth.md) 的「帧率：瓶颈是升频速度」。

顺带一提：**不要**自己去 `taskset` 把游戏绑到大核上，实测是负优化
（schedutil 下 48.40 → 36.79）。

**手柄不按你想的那样工作** —— 非 Steam 游戏默认套的是桌面布局（手柄模拟键鼠）。
键盘操作的游戏（东方系列要方向键 + Z + X + Shift）需要在 Steam 的控制器设置里
配一套布局。

---

## 空间

游戏装在 `userdata` 分区（`/`，约 106 GiB）。这是安装 SteamOS 时就已经不可逆地
拿过来的那块，往里放游戏不涉及任何分区操作，删了就回来了。
