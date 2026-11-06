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
# 1.7.0：图标是交付内容的一部分，打包前先验一遍，别把「没图标」打进 dmg。
for f in AppIcon.icns MenuBarTemplate.png "MenuBarTemplate@2x.png"; do
  [ -f "$APP/Contents/Resources/$f" ] || {
    echo "❌ app 里缺少 Resources/$f，先跑 ./build.sh"; exit 1; }
done
ICON_NAME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' \
             "$APP/Contents/Info.plist" 2>/dev/null || true)
if [ "$ICON_NAME" != "AppIcon.icns" ]; then
  echo "❌ Info.plist 未声明 AppIcon.icns（实际：$ICON_NAME）"; exit 1
fi

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

3. 首次运行会在屏幕右下角出现小窗，菜单栏出现托盘图标（深色底 + 白纸 + 向下箭头，
   深浅模式自动反相）。左键点图标打开 400×520 下拉面板，右键打开菜单。

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

   ⚠️ 只保留一份 ObsidianDrop。若「应用程序」里已有旧版，拖入时会直接覆盖；
      若之前用开发脚本装过，可能还留在 ~/Applications/ObsidianDrop.app。
      两份是同一个 Bundle ID，同时存在会出现两个菜单栏图标，而且 macOS 的
      麦克风 / 截屏 / 完全磁盘访问授权是按路径记的，会反复失效。
      处理方法：退出正在运行的 ObsidianDrop，删掉不用的那一份，再从
      /Applications 打开新版；Finder 与启动台里的图标也会随之更新。

5. 开机自启：托盘菜单 →「开机自动启动」。

6. 本版新增：AI 分场景处理（文件做摘要 / 转录润色分段 / 截图识别画面，
   其他类型按旧模式）、重设计的下拉面板、应用与菜单栏图标。
   AI 默认关闭；要用请在「打开 → AI 模型配置…」里填接口与 Key，
   用视觉模型时可在「视觉模型」栏单独指定，留空则跟随文字模型。
   AI 失败或未配置时笔记照常入库，只是没有摘要，不会丢内容。

完整说明见源码目录里的 使用说明.md 与 发布说明-1.7.0.html
TXT

# 发布说明一起放进 dmg，用户挂载后能直接看
if [ -f "$SRC_DIR/docs/发布说明-1.7.0.html" ]; then
  cp "$SRC_DIR/docs/发布说明-1.7.0.html" "$STAGE/1.7.0 发布说明.html"
fi

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
[ -f "/tmp/obsidiandrop-dmg-check/$APP_NAME.app/Contents/Resources/AppIcon.icns" ] \
  && echo "  ✅ 应用图标就位" || echo "  ❌ dmg 内缺应用图标"
[ -f "/tmp/obsidiandrop-dmg-check/$APP_NAME.app/Contents/Resources/MenuBarTemplate.png" ] \
  && echo "  ✅ 菜单栏图标就位" || echo "  ❌ dmg 内缺菜单栏图标"
codesign -v "/tmp/obsidiandrop-dmg-check/$APP_NAME.app" 2>/dev/null \
  && echo "  ✅ 签名校验通过" || echo "  ⚠️ 未签名或签名不完整（ad-hoc，仍可运行）"
hdiutil detach /tmp/obsidiandrop-dmg-check >/dev/null 2>&1 || true

echo "==> 完成"
SIZE=$(du -h "$DMG" | awk '{print $1}')
echo "  $DMG  ($SIZE)"
shasum -a 256 "$DMG" | awk '{print "  SHA256: "$1}'
