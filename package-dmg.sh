#!/bin/bash
# 把 ObsidianDrop.app 打成可分发的 dmg
#   用法：./package-dmg.sh            先编译再打包
#         ./package-dmg.sh --no-build 用现有产物直接打包
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="ObsidianDrop"
APP="$SRC_DIR/$APP_NAME.app"
DIST="$SRC_DIR/dist"

if [ "${1:-}" != "--no-build" ]; then
  echo "==> 编译最新版本"
  "$SRC_DIR/build.sh" >/dev/null
fi

[ -d "$APP" ] || { echo "找不到 $APP，先跑 ./build.sh"; exit 1; }

VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
        "$APP/Contents/Info.plist" 2>/dev/null || echo "0.0.0")
VOL="$APP_NAME $VER"
DMG="$DIST/$APP_NAME-$VER.dmg"

echo "==> 准备暂存目录"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
# 标准做法：把应用拖到这个快捷方式上即完成安装
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/安装说明.txt" <<'TXT'
ObsidianDrop 安装说明
======================

1. 把左边的 ObsidianDrop 拖到右边的 Applications 文件夹里。
2. 打开「访达 → 应用程序」，双击 ObsidianDrop。
   第一次打开若提示「无法验证开发者」：
     右键点它 → 打开 → 再点「打开」；
   或执行：xattr -dr com.apple.quarantine /Applications/ObsidianDrop.app

3. 首次运行会在屏幕右下角出现小窗，菜单栏出现托盘图标（方框+下箭头）。

4. 权限（按需，用到才提示）：
   · 拖文件报「Operation not permitted」
     → 系统设置 → 隐私与安全性 → 完全磁盘访问权限 → 加入 ObsidianDrop
   · 点截屏报「截图失败」
     → 系统设置 → 隐私与安全性 → 屏幕与系统录音 → 勾选 ObsidianDrop → 退出重开
   · 点「灵感」录音报「没有麦克风权限」
     → 系统设置 → 隐私与安全性 → 麦克风 → 勾选 ObsidianDrop → 退出重开
   · 点「灵感」录音报「没有可用的音频输入设备」
     → 先看「系统设置 → 声音 → 输入」里有没有设备、电平条会不会跳
     → 再在终端跑一次诊断，把输出发回来即可定位：
        /Applications/ObsidianDrop.app/Contents/MacOS/ObsidianDrop --audio-check

   · 点「灵感」录完却提示「没识别出文字」
     → 弹窗里会有「在访达中显示录音」，说明录音已经存下来了，可先播放确认
     → 再跑一次按钮链路自检，三项都对就不是程序侧问题：
        /Applications/ObsidianDrop.app/Contents/MacOS/ObsidianDrop --record-test <音频文件>

   ⚠️ 一定要先把 ObsidianDrop 拖进「应用程序」再运行。
      直接从 dmg 窗口里双击，每次挂载的路径都不一样，系统会当成
      另一个新程序，麦克风/截屏授权会反复失效。

5. 开机自启：托盘菜单 →「开机自动启动」。

完整说明见源码目录里的 使用说明.md
TXT

echo "==> 生成 $DMG"
mkdir -p "$DIST"
rm -f "$DMG"
hdiutil create \
  -volname "$VOL" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  "$DMG" >/dev/null

echo "==> 挂载自检"
MNT="$(hdiutil attach "$DMG" -nobrowse -readonly -mountpoint /tmp/obsidiandrop-dmg-check | tail -1)"
if [ -x "/tmp/obsidiandrop-dmg-check/$APP_NAME.app/Contents/MacOS/$APP_NAME" ]; then
  echo "  ✅ 应用可执行文件就位"
else
  echo "  ❌ dmg 内应用异常"
fi
[ -L "/tmp/obsidiandrop-dmg-check/Applications" ] && echo "  ✅ Applications 快捷方式就位"
codesign -v "/tmp/obsidiandrop-dmg-check/$APP_NAME.app" 2>/dev/null \
  && echo "  ✅ 签名校验通过" || echo "  ⚠️ 未签名或签名不完整（ad-hoc，仍可运行）"
hdiutil detach /tmp/obsidiandrop-dmg-check >/dev/null 2>&1 || true

echo "==> 完成"
SIZE=$(du -h "$DMG" | awk '{print $1}')
echo "  $DMG  ($SIZE)"
shasum -a 256 "$DMG" | awk '{print "  SHA256: "$1}'
