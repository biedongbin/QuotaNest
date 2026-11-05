#!/bin/zsh
# QuotaNest: build, package the icon, sign, and install the macOS application.
set -euo pipefail
export PATH="$HOME/.swiftly/bin:$PATH"
PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"
VERSION=$(git describe --tags --always --dirty 2>/dev/null || echo "0.0.0-dev")
BUILD_TIME=$(date '+%Y-%m-%d %H:%M:%S')
OUT="$PROJECT_DIR/.build/QuotaNest.app"
[[ "${OUT:A}" == "$PROJECT_DIR/.build/QuotaNest.app" ]] || exit 1
if pgrep -x TokenHUD >/dev/null; then
  echo "QuotaNest 正在运行，请先退出再安装（菜单栏 → 退出）"; exit 1
fi
swiftly run swift build -c release
BIN=$(swiftly run swift build -c release --show-bin-path)
[[ -f "$PROJECT_DIR/assets/branding/QuotaNest.icns" ]]
[[ -d "$BIN/QuotaNest_TokenHUD.bundle" ]]
rm -rf "$OUT"
APP="$OUT/Contents"
mkdir -p "$APP/MacOS" "$APP/Resources"
cp "$BIN/TokenHUD" "$APP/MacOS/"
cp -R "$BIN/QuotaNest_TokenHUD.bundle" "$APP/Resources/"
cp "$PROJECT_DIR/assets/branding/QuotaNest.icns" "$APP/Resources/QuotaNest.icns"
cat > "$APP/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>TokenHUD</string>
    <key>CFBundleIdentifier</key><string>local.tokenhud</string>
    <key>CFBundleName</key><string>QuotaNest</string>
    <key>CFBundleDisplayName</key><string>QuotaNest</string>
    <key>CFBundleIconFile</key><string>QuotaNest.icns</string>
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
INSTALL="$DEST/QuotaNest.app"
LEGACY="$DEST/TokenHUD.app"
mkdir -p "$DEST"
[[ "${INSTALL:A}" == "${DEST:A}/QuotaNest.app" ]] || exit 1
rm -rf "$INSTALL"
cp -R "$OUT" "$DEST/"
codesign --verify --deep --strict "$INSTALL"
INSTALLED=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INSTALL/Contents/Info.plist")
[[ "$INSTALLED" == "$VERSION" ]] || { echo "✗ 安装版本不匹配"; exit 1; }
# Remove only the verified legacy bundle after the renamed application is installed.
if [[ -d "$LEGACY" && "${LEGACY:A}" == "${DEST:A}/TokenHUD.app" ]]; then
  LEGACY_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$LEGACY/Contents/Info.plist" 2>/dev/null || true)
  if [[ "$LEGACY_ID" == "local.tokenhud" ]]; then rm -rf "$LEGACY"; fi
fi
echo "✓ QuotaNest $VERSION 已安装"
echo "  路径: $INSTALL"
echo "  构建: $BUILD_TIME"
echo "✓ 图标、签名及版本核对通过"
