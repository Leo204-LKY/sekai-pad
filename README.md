# SekaiPad — PlayCover 下 Project SEKAI 的触控板直触方案

> [!WARNING]
> 本项目是非官方的个人工具，代码完全由 Claude 编写，与 SEGA、Colorful Palette、朝夕光年、Crypton Future Media 等公司或团体均无任何关联。目前只在中国大陆版《初音未来：缤纷舞台》上测试过，其他服务器版本未经验证。使用第三方工具可能违反游戏的服务条款，由此导致的封号等后果由使用者自行承担，作者不承担任何责任。
>
> This is an unofficial, fan-made tool written entirely by Claude. It is not affiliated with or endorsed by SEGA, Colorful Palette, Nuverse, Crypton Future Media, or any related company or group. It has only been tested on the Mainland China version of the game (初音未来：缤纷舞台); other regional versions are untested. Using third-party tools may violate the game's Terms of Service; you use it at your own risk, and the author accepts no responsibility for account bans or any other consequences.

SekaiPad 是一个触控板辅助工具，让整个触控板都能用作「Project Sekai: Colorful Stage」（又称 Hatsune Miku: Colorful Stage / 初音未来：缤纷舞台，以下简称 PJSK）的判定区域。

在 PlayCover 里用 macOS 自带的「触控替代」玩 PJSK，有两个问题：

- **越往上越窄**：「触控替代」把触控板映射到整个画面，而 PJSK 的谱面上窄下宽，并且只有下半区域可以触发 Note 判定；触控板越靠上，对应的轨道越窄，只有最底部的区域完全占满宽度，触控板体验最好。

  ![判定区域](https://github.com/user-attachments/assets/c09eb076-2313-4962-be45-fca2ee32af85)
- **必须按住 Option**：打歌时只能拿重物压住键盘。

SekaiPad 的做法：

- **忽略按下的高度**：手指在触控板任何高度按下，都落在判定线上；横向位置按判定线处的轨道宽度线性映射，整块触控板宽度一致。
- **保留 Flick**：按下后手指的竖向**相对位移**照常传给游戏（倍率可调），上划、斜划都能用；横向滑动（Slide 换轨）也实时跟随。
- **不用按住 Option**：不经过「触控替代」，而是用 PlayTools 自带的触摸合成直接生成多点触控。用 **Caps Lock** 开关（亮灯＝生效），按一下切换。
- **不受鼠标干扰**：映射开启时自动隐藏并固定鼠标；画面上会显示触摸点，方便校准（可用 `--hide-touches` 关闭）。

## 结构

```
触控板 ──(MultitouchSupport 私有框架)──> sekai-pad 助手程序（普通 macOS 命令行）
        ──UDP 127.0.0.1:47800──> SekaiPad.dylib（PlayCover 插件，在游戏进程里）
        ──PTFakeMetaTouch──> 游戏收到的真实多点触控
```

分成两部分，是因为游戏进程里大概率读不了触控板原始数据（沙盒 + 平台限制），普通命令行程序可以。

## 使用

### 编译

克隆或下载本仓库，在终端中运行：

```bash
cd sekai-pad
chmod +x build.sh && ./build.sh
```

得到 `build/sekai-pad` 和 `build/SekaiPad.dylib`。

### 安装和游玩

1. 在 PlayCover 的应用库里右键 PJSK 图标 → 设置 → 「杂项」标签页，往下找到 Custom Plugins 区域（PlayCover 翻译不完全，可能显示 `settings.customPlugins.title`），点 **Add…** (`settings.customPlugins.add`) 选择 `build/SekaiPad.dylib`。
2. 关掉 PJSK 的「触控替代」，避免冲突。
3. 系统设置 → 触控板：
   - **关闭「轻点来点按」**；
   - MASTER 谱面推荐在「更多手势」里关掉三指/四指手势。
4. 终端运行：`./build/sekai-pad`，再启动游戏。
5. 通过 Caps Lock 键切换映射开关（键盘亮/灭绿灯表示开/关）

## 启动参数

改参数只需要重启助手程序（`--port` 除外），不用重启游戏。

### 校准

| 参数 | 含义 | 默认 |
|---|---|---|
| `--judge-y` | 判定线高度（窗口高度比例，0 顶 1 底） | 0.82 |
| `--left` / `--right` | 判定线处最左/最右轨道边缘（窗口宽度比例） | 0.12 / 0.88 |
| `--pad-left` / `--pad-right` | 触控板实际使用的左右范围（排除边缘死区） | 0.03 / 0.97 |
| `--flick-gain` | 竖向位移倍率，Flick 不灵就调大 | 1.0 |

例：`./build/sekai-pad --judge-y 0.85 --left 0.10 --right 0.90 --flick-gain 1.5`

### 其他

| 参数 | 含义 | 默认 |
|---|---|---|
| `--toggle MODE` | 开关方式：`capslock` = Caps Lock 亮灯时生效，`always` = 一直生效 | `capslock` |
| `--hide-touches` | 不在游戏画面上显示触摸点 | 显示 |
| `--debug` | 调试模式，在终端打印每帧映射后的坐标 | 关闭 |
| `--port N` | 与插件通信的 UDP 端口（插件固定监听 47800，一般不需要改） | 47800 |
| `--help` | 显示所有参数 | |


## 故障排除

先用 `./build/sekai-pad --debug` 启动助手程序，按下面的顺序排查。

### 助手程序

- **提示「没有找到触控板设备」，或摸触控板时终端没有任何输出**：给运行它的终端 App 开「输入监控」权限（系统设置 → 隐私与安全性 → 输入监控），然后重启终端。
- **摸触控板时一直显示 `[OFF]`**：映射没有开启。确认 Caps Lock 指示灯亮着；如果 Caps Lock 设成了「短按切换输入法」，要**长按**才会亮灯。也可以改用 `--toggle always`。

### 终端显示 `[ON ]`，但游戏没反应

- **刚添加插件、或替换过 `SekaiPad.dylib`**：插件只在游戏启动时加载，需要完全退出游戏再打开。PlayCover 添加插件时会复制一份，重新编译后要在 Custom Plugins 里删掉旧的再添加一次。
- **查看插件日志**：打开「控制台」App，选中本机，点「开始」，在搜索框输入 `SekaiPad`，然后启动游戏：
  - **没有「正在监听 127.0.0.1:47800」**：插件没有加载，检查 PlayCover 的 Custom Plugins 设置。
  - **「绑定 127.0.0.1:47800 失败」**：端口被其他程序占用，可以用 `lsof -nP -iUDP:47800` 查看是哪个进程，关掉它后重启游戏。
  - **「找不到 PTFakeMetaTouch」或「5参=0 3参=0」**：当前 PlayTools 版本的触摸接口与本项目不兼容，请[提交 Issue](https://github.com/Leo204-LKY/sekai-pad/issues)，附上这几行日志和 PlayCover 版本号。
  - **「忽略触摸」**：游戏窗口不在前台，点一下游戏窗口再试。

### 游戏里

- **点的位置偏了 / 轨道对不上**：按画面上的触摸点调整「校准」中的参数。
- **手指一碰，光标位置多出一个触点**：关闭系统设置 → 触控板 →「轻点来点按」。
- **打歌时切到了桌面或调度中心**：在触控板设置的「更多手势」里关掉三指、四指手势。

助手程序退出或卡住超过 0.25 秒时，插件会自动松开所有手指，不会出现「手指卡住」；鼠标也会在 0.5 秒内恢复显示。

其他问题欢迎[提交 Issue](https://github.com/Leo204-LKY/sekai-pad/issues)。
