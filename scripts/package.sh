#!/bin/zsh
# TokenHUD 打包: swift build → 拼 .app → ad-hoc 签名 → 装到 ~/Applications
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=".build/TokenHUD.app"
rm -rf "$OUT"
swift build -c release
BIN=$(swift build -c release --show-bin-path)
APP="$OUT/Contents"
mkdir -p "$APP/MacOS" "$APP/Resources"
cp "$BIN/TokenHUD" "$APP/MacOS/"
cp -R "$BIN/TokenHUD_TokenHUD.bundle" "$APP/Resources/"
cat > "$APP/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>TokenHUD</string>
    <key>CFBundleIdentifier</key><string>local.tokenhud</string>
    <key>CFBundleName</key><string>TokenHUD</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
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
cp -R "$OUT" "$DEST/"
echo "✓ 安装完成: $DEST/TokenHUD.app"
