#!/bin/bash
# Build a universal (Apple Silicon + Intel) MacTouch.app and package it into a drag-to-install .dmg.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" build/MacTouch.app/Contents/Info.plist 2>/dev/null || echo "3.4.0")
./build.sh --arch=universal
./build/MacTouch.app/Contents/MacOS/MacTouch --self-test

STAGE="build/dmg-stage"
DMG="build/MacTouch-Pro-v${VERSION}-Universal.dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "build/MacTouch.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/首次安装说明 (First-Time Setup).txt" << 'TXT'
MacTouch Pro — macOS 外接触摸屏驱动 & Retina HiDPI 高清引擎
==========================================================

【一、安装步骤】
1. 将「MacTouch.app」拖拽到旁边的「Applications（应用程序）」文件夹中。
2. 若 macOS 提示“无法验证开发者”（开源免费未付费公证），请在「终端 (Terminal)」执行一次：
   xattr -cr /Applications/MacTouch.app
   然后直接双击打开 MacTouch.app（或按住 Control 键点击图标选择“打开”）。

【二、开启两项系统权限（仅首次需要）】
打开后屏幕右上角菜单栏会出现手掌图标，请在「系统设置 ▸ 隐私与安全性」中开启：
  1. 输入监控 (Input Monitoring)  —— 勾选 MacTouch（约 20 秒内自动生效）
  2. 辅助功能 (Accessibility)     —— 勾选 MacTouch（2 秒内立即生效）
（也可直接点击菜单栏第一行的权限提示一键跳转！）

【三、核心功能（默认全开）】
- 全套 Mac 原生触控板手势：单指/双指 120Hz 惯性滚屏、双指轻点右键、双指无级缩放、
  双指旋转、双指双击智能缩放、三指轻点查询、三指/四指调度中心与空间切换、
  四指/五指张开显示桌面与捏合打开启动台、右边缘双指轻扫打开通知中心。
- 一键开启 1080p/2K 副屏 2x Retina HiDPI 超清渲染（支持菜单栏与系统设置双向无闪烁秒切）。
- 窗口红绿灯与小按钮智能磁吸防抖，单击一触即中。
- 物理键盘接入时智能免弹屏幕虚拟键盘；无头主机模式自动唤起中文辅助键盘。
TXT

hdiutil create -volname "MacTouch Pro" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "packaged $DMG ($(du -h "$DMG" | awk '{print $1}'))"
