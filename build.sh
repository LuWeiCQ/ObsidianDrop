#!/bin/bash
# 构建 ObsidianDrop.app（无需 Xcode，只用 Command Line Tools）
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$SRC_DIR/ObsidianDrop.app"
OUT="${1:-$HOME/Applications}"

echo "==> 清理旧产物"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 写 Info.plist"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleExecutable</key><string>ObsidianDrop</string>
  <key>CFBundleIdentifier</key><string>com.lw.obsidiandrop</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>ObsidianDrop</string>
  <key>CFBundleDisplayName</key><string>ObsidianDrop</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.7.0</string>
  <key>CFBundleVersion</key><string>24</string>
  <key>CFBundleIconFile</key><string>AppIcon.icns</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>录下你的灵感语音，然后在本机转成文字存进知识库。录音不会离开这台电脑。</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>把刚录的语音转成文字。转写在 Mac 本机完成，不上传云端。</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
</dict>
</plist>
PLIST

echo "==> 编译（arm64，仅 Apple Silicon）"
# 不做 Intel 适配：目标机器（Mac mini / MacBook Air）都是 Apple Silicon，
# 单架构产物更小，也省掉一份 x86_64 的链接与兼容性检查。
xcrun swiftc \
  -O \
  -parse-as-library \
  -swift-version 5 \
  -target arm64-apple-macos13.0 \
  -framework AppKit \
  -framework AVFoundation \
  -framework CoreAudio \
  -framework Speech \
  -framework Security \
  -framework PDFKit \
  -o "$APP/Contents/MacOS/ObsidianDrop" \
  "$SRC_DIR"/Sources/*.swift

echo "==> 拷入图标资源"
# 1.7.0：AppIcon.icns（Finder / Dock / 切换器）+ 菜单栏模板图标。
# 图标由 tools/make-icon.swift 生成并提交在 Resources/，构建时只复制、不重新生成。
# 缺资源必须**直接失败**：静默打出没有图标的 app 等于交付了一个看不见的回归。
for f in AppIcon.icns MenuBarTemplate.png "MenuBarTemplate@2x.png"; do
  if [ ! -f "$SRC_DIR/Resources/$f" ]; then
    echo "  ❌ 缺少 Resources/$f —— 先跑：xcrun swiftc -O tools/make-icon.swift -o /tmp/od-make-icon && /tmp/od-make-icon Resources" >&2
    exit 1
  fi
  cp "$SRC_DIR/Resources/$f" "$APP/Contents/Resources/"
  chmod 0644 "$APP/Contents/Resources/$f"
done
/usr/bin/plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> 签名（ad-hoc）"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "  签名跳过（不影响运行）"

echo "==> 安装到 $OUT"
mkdir -p "$OUT"
rm -rf "$OUT/ObsidianDrop.app"
cp -R "$APP" "$OUT/"
xattr -dr com.apple.quarantine "$OUT/ObsidianDrop.app" 2>/dev/null || true

echo "==> 完成"
ls -la "$OUT/ObsidianDrop.app/Contents/MacOS/"
echo "安装路径：$OUT/ObsidianDrop.app"
