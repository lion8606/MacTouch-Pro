# MacTouch Pro 🖐️✨

**macOS 外接触摸屏全手势驱动 + 2x Retina HiDPI 高清渲染引擎（一体化开源方案）**  
*All-in-One External Touchscreen Driver, Full Magic Trackpad Gesture Engine & 2x Retina HiDPI Scaler for macOS (Apple Silicon & Intel)*

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: macOS 13+](https://img.shields.io/badge/macOS-13.0%2B%20(Ventura%20%E2%86%92%20Sequoia)-success.svg)](https://github.com/lion8606/MacTouch-Pro/releases)
[![Arch: Universal](https://img.shields.io/badge/Arch-Universal%20(Apple%20Silicon%20%2B%20Intel)-orange.svg)](https://github.com/lion8606/MacTouch-Pro/releases)

---

## 为什么做 MacTouch Pro？

macOS 天生没有为外接 USB 多点触摸屏（便携屏、桌面副屏、Mac mini 无头工控屏）提供多指触控驱动，同时在 Apple Silicon 芯片上默认屏蔽了 1080p / 2K 外接显示器的 **2x Retina HiDPI** 高清渲染，导致字体发虚、点击小按钮极易误触、点输入框乱弹虚拟键盘。

**MacTouch Pro** 将纯用户态零内核扩展（Zero-Kext）的 HID 多点触控引擎、完整复刻的 **Magic Trackpad 原生触控板手势状态机**、以及基于 `CGVirtualDisplay` 硬件镜像的 **2x Retina HiDPI 无闪烁缩放引擎** 合二为一，插上即把任何触摸显示器变成一台大号“Retina 触控板 + iPad 级触控屏”。

---

## 核心特性 (Key Features)

### 1. 开箱即用的全套 Mac 原生触控板手势（默认全开）
无需繁琐调参，安装后默认内置完整的 macOS 触控板控制逻辑：
- **光标与点按**：
  - **单指轻点 + 小目标磁吸增强**：针对 macOS 窗口左上角红绿灯（关闭/最小化/全屏 `16×16 pt`）及小按钮内置无障碍坐标磁吸，解决手指遮挡与屏幕边缘畸变，一触即中。
  - **单指双击 / 三击并拖移**：按词、按行快速选词；窗口标题栏单指直接拖动；窗口四周边框触控缩放。
  - **双指轻点 / 单指长按圆环**：触发右键菜单（长按出现圆环后移动手指自动转为拖拽）。
  - **三指轻点**：触发系统级 **查询与数据检测器 (`⌃⌘D`)**。
  - **三指拖移（可选）**：经典三指拖移窗口与选区（开启后桌面切换自动顺延为四指）。
- **滚动与缩放**：
  - **单指 & 双指 120Hz 物理惯性滚屏**：同时兼顾 iPad 直觉（单指滚屏）与 Mac 触控板直觉（双指滚屏），轻触即停。
  - **双指捏合无级缩放**：发送原生 `kIOHIDEventTypeZoom` 连续缩放手势（对 Chrome / VS Code / Electron 应用自动智能适配缩放）。
  - **双指双击智能缩放 (Smart Zoom)**：发送原生 `NSEvent.smartMagnify` 区块聚焦放大。
  - **双指旋转 (Rotate)**：发送原生 `NSEvent.rotate` 连续旋转图片与画布。
- **更多桌面空间手势**：
  - **三指 / 四指上滑**：打开 **调度中心 (Mission Control)**
  - **三指 / 四指下滑**：打开 **App Exposé**
  - **三指 / 四指左右滑**：丝滑切换左右全屏空间 (Spaces)
  - **四指 / 五指张开**：**显示桌面 (Show Desktop)**
  - **四指 / 五指捏合**：**打开启动台 (Launchpad)**
  - **双指从屏幕右边缘向左轻扫**：呼出 / 收起 **macOS 通知中心**

### 2. 一键解锁 2x Retina HiDPI 超清渲染（零闪烁双向同步）
- 突破 Apple Silicon 对 1080p / 2K 外接屏的 HiDPI 限制，内置 `2560×1440 (2K)`、`2048×1152`、`1920×1080`、`1600×900 (推荐黄金比例)`、`1440×810`、`1280×720` 全套 **2x Retina HiDPI** 档位。
- **双向实时同步**：既可在顶部菜单栏秒级无黑屏切换，也可直接在 **macOS「系统设置 ▸ 显示器」** 中点选，触控坐标始终 1:1 精准对齐，拔线自动无感还原。

### 3. 主机副屏 & Mac mini 无头电脑双场景智能键盘
- 自动激活 Chrome / Electron 等应用的无障碍焦点树，触摸输入框精准落焦。
- **智能免打扰**：当检测到外接/内置物理键盘或近期敲击行为时，自动抑制屏幕虚拟键盘弹出，直接用实体键盘打字；在纯触控无头 Mac mini 上自动唤起/收起系统辅助键盘（完美兼容简中/英文系统）。

### 4. 全套简体中文界面 + 创意触控套件
- 菜单栏、18 点边缘非线性校准向导、多屏靶心配对、全屏白板、透明屏幕批注画笔、多指触控乐器（钢琴/打击垫/和弦拨弦/特雷门琴）全界面原生中文化。

---

## 快速安装 (Installation)

### 方式一：下载 `.dmg` 安装包（推荐，支持所有 M1~M4 与 Intel Mac）

1. 前往 [**Releases 页面**](https://github.com/lion8606/MacTouch-Pro/releases) 下载最新的 `MacTouch-Pro-v3.4.0-Universal.dmg`。
2. 打开镜像，将 **`MacTouch.app`** 拖入 **`Applications`（应用程序）** 文件夹。
3. 由于开源项目未购买 Apple 商业公证签名，首次打开前请在「终端 (Terminal)」运行一行命令移除隔离标记：
   ```bash
   xattr -cr /Applications/MacTouch.app
   open /Applications/MacTouch.app
   ```
4. 点击屏幕右上角菜单栏的 🖐️ 图标，按提示在 **「系统设置 ▸ 隐私与安全性」** 中开启两项权限：
   - **输入监控 (Input Monitoring)** — 允许读取触摸屏多指坐标
   - **辅助功能 (Accessibility)** — 允许合成原生触控板手势与按钮磁吸
5. 在菜单中勾选 **「开机自动启动」** 即可长期无感运行。

### 方式二：从源码一键编译并配置后台守护

要求已安装 Xcode Command Line Tools（`xcode-select --install`）：

```bash
git clone https://github.com/lion8606/MacTouch-Pro.git
cd MacTouch-Pro
./install.sh
```

如需自行打包通用架构 `.dmg` 镜像：

```bash
./package_dmg.sh
```

---

## 开源协议与致谢 (License & Acknowledgements)

本项目基于 [MIT License](LICENSE) 开源：
- 底层用户态 HID 多点触控与校准框架基于 [kashmeister/mactouch](https://github.com/kashmeister/mactouch)（MIT License）演进，谨向原作者致以诚挚感谢。
- 2x Retina HiDPI 虚拟显示器硬件镜像机制参考了 macOS `CGVirtualDisplay` 社区最佳实践（[BetterDisplay](https://github.com/waydabber/BetterDisplay) / [hidpi-mirror](https://github.com/pasky/hidpi-mirror)）。
