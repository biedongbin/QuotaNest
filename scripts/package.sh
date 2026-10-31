#!/bin/zsh
# TokenHUD 打包: swift build → 拼 .app → ad-hoc 签名 → 装到 ~/Applications
set -euo pipefail
# 必须 swiftly 工具链 (系统 CLT Swift 6.1.2 与 ManifestAPI ABI 不匹配, 裸 swift build 链接失败)
export PATH="$HOME/.swiftly/bin:$PATH"
cd "$(dirname "$0")/.."
# P2-7 版本注入: git describe --tags 优先 (tag+距离+SHA), 无 tag 用短 SHA
VERSION=$(git describe --tags --always --dirty 2>/dev/null || echo "0.0.0-dev")
BUILD_TIME=$(date '+%Y-%m-%d %H:%M:%S')
OUT=".build/TokenHUD.app"
rm -rf "$OUT"
swiftly run swift build -c release
BIN=$(swiftly run swift build -c release --show-bin-path)
APP="$OUT/Contents"
mkdir -p "$APP/MacOS" "$APP/Resources"
cp "$BIN/TokenHUD" "$APP/MacOS/"
cp -R "$BIN/TokenHUD_TokenHUD.bundle" "$APP/Resources/"
cat > "$APP/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>TokenHUD</string>
    <key>CFBundleIdentifier</key><string>local.tokenhud</string>
    <key>CFBundleName</key><string>TokenHUD</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
printf 'APPL????' > "$APP/PkgInfo"
codesign --force --deep -s - "$OUT"
DEST="$HOME/Applications"
if pgrep -x TokenHUD >/dev/null; then
  echo "TokenHUD 正在运行, 先退出再安装 (菜单栏 → 退出)"; exit 1
fi
mkdir -p "$DEST"
rm -rf "$DEST/TokenHUD.app"  # 旧 bundle 先删: BSD cp -R 会合并进旧目录, 残留旧文件并破坏签名
cp -R "$OUT" "$DEST/"
echo "✓ 版本 $VERSION 已安装"
echo "  路径: $DEST/TokenHUD.app"
echo "  构建: $BUILD_TIME"
INSTALLED=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/TokenHUD.app/Contents/Info.plist" 2>/dev/null || true)
if [ -n "$INSTALLED" ] && [ "$INSTALLED" != "$VERSION" ]; then
  echo "✗ 版本核对失败: 期望 $VERSION, 实际 $INSTALLED"; exit 1
fi
echo "✓ 版本核对通过: Info.plist = $VERSION"
