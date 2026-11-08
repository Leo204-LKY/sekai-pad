# SekaiPad — PlayCover 下 Project SEKAI 的触控板直触方案

## 它做什么

- **忽略按下的高度**：手指在触控板任何高度按下，都落在判定线上；横向位置按判定线处的轨道宽度线性映射，所以不会越往上越窄。
- **保留 Flick**：按下后手指的竖向**相对位移**照常传给游戏（倍率可调），上划、斜划都能用；横向滑动（Slide 换轨）也是实时跟随。
- **不用按住 Option**：不经过 Apple 的「触控替代」，用 PlayTools 自带的触摸合成直接生成多点触控。开关用 **Caps Lock**（亮灯＝生效），按一下就切换，不用一直按着。

## 结构

```
触控板 ──(MultitouchSupport 私有框架)──> sekai-pad 助手程序（普通 macOS 命令行）
        ──UDP 127.0.0.1:47800──> SekaiPad.dylib（PlayCover 插件，在游戏进程里）
        ──PTFakeMetaTouch──> 游戏收到的真实多点触控
```

分成两部分，是因为游戏进程里大概率读不了触控板原始数据（沙盒 + 平台限制），普通命令行程序可以。

## 编译

在 Mac 上（需要 Xcode 或 Command Line Tools）：

```bash
cd sekai-pad
chmod +x build.sh && ./build.sh
```

得到 `build/sekai-pad` 和 `build/SekaiPad.dylib`。

## 安装与使用

1. PlayCover → 设置 → 杂项 → 自定义插件，添加 `build/SekaiPad.dylib`（需要 PlayCover 4.0+）。
2. 关掉 Project SEKAI 的「触控替代」（游戏菜单栏里），避免和它冲突。
3. 系统设置 → 触控板：
   - **关闭「轻点来点按」**，否则手指一碰就会在光标位置多出一个触点；
   - 「更多手势」里关掉三指/四指手势，防止打歌时切桌面。
4. 终端运行：`./build/sekai-pad --debug`，再启动游戏。
5. 打歌前按一下 Caps Lock（亮灯）开启映射，回菜单再按一下关闭，用光标点按钮。

> 如果你的 Caps Lock 被设成了「切换中/英文输入法」，它不会保持亮灯，改用 `--toggle always`，退出映射就直接 Ctrl+C 停掉助手程序。

## 校准

游戏里手指按住时对应轨道会亮，用这个来调：

| 参数 | 含义 | 默认 |
|---|---|---|
| `--judge-y` | 判定线高度（窗口高度比例，0 顶 1 底） | 0.82 |
| `--left` / `--right` | 判定线处最左/最右轨道边缘（窗口宽度比例） | 0.12 / 0.88 |
| `--pad-left` / `--pad-right` | 触控板实际使用的左右范围（排除边缘死区） | 0.03 / 0.97 |
| `--flick-gain` | 竖向位移倍率，Flick 不灵就调大 | 1.0 |

例：`./build/sekai-pad --judge-y 0.85 --left 0.10 --right 0.90 --flick-gain 1.5`

改参数只需要重启助手程序，不用重启游戏。

## 排错

- **助手程序显示「没有找到触控板设备」/ `--debug` 下摸触控板没有输出**：给「终端」开「输入监控」权限（系统设置 → 隐私与安全性）。
- **助手程序有输出但游戏没反应**：打开「控制台」App，搜索 `SekaiPad`：
  - 没有任何日志 → 插件没加载，检查 PlayCover 插件设置；
  - 「绑定 … 失败」→ 端口被占用，两边都换端口（`--port`，并给游戏设置环境变量 `SEKAIPAD_PORT`）；
  - 「找不到 PTFakeMetaTouch」→ 你的 PlayTools 版本不同，把日志发给我。
- 助手程序退出或卡住 0.25 秒后，插件会自动松开所有手指，不会出现「手指卡住」。
