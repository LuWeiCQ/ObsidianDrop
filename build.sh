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
  <key>CFBundleShortVersionString</key><string>1.3.15</string>
  <key>CFBundleVersion</key><string>19</string>
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
  -o "$APP/Contents/MacOS/ObsidianDrop" \
  "$SRC_DIR/Sources/main.swift"

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
