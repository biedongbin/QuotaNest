#!/bin/zsh
# Build a local app, or a universal ZIP for a versioned GitHub Release.
set -euo pipefail
export PATH="$HOME/.swiftly/bin:$PATH"
PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"

RELEASE=0
BUILD_ONLY=0
if [[ "${1:-}" == "--release" && $# == 1 ]]; then
  RELEASE=1
elif [[ "${1:-}" == "--build-only" && $# == 1 ]]; then
  BUILD_ONLY=1
elif [[ $# != 0 ]]; then
  echo "Usage: zsh scripts/package.sh [--release|--build-only]" >&2
  exit 2
fi
VERSION=$(tr -d '\r\n' < "$PROJECT_DIR/VERSION")
# Accept the project's optional fourth hotfix component (for example 1.0.0.1).
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$' ]] || { echo "Invalid VERSION" >&2; exit 1; }
REVISION=$(git rev-parse HEAD)
BUILD_TIME=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
OUT="$PROJECT_DIR/.build/QuotaNest.app"
[[ "${OUT:A}" == "$PROJECT_DIR/.build/QuotaNest.app" ]] || exit 1
if [[ "$RELEASE" == 0 && "$BUILD_ONLY" == 0 ]] && { pgrep -x QuotaNest >/dev/null || pgrep -x TokenHUD >/dev/null; }; then
  echo "QuotaNest 正在运行，请先退出再安装（菜单栏 → 退出）" >&2
  exit 1
fi

if [[ "$RELEASE" == 1 ]]; then
  swiftly run swift build -c release --arch arm64
  ARM_BIN=$(swiftly run swift build -c release --arch arm64 --show-bin-path)
  swiftly run swift build -c release --arch x86_64
  INTEL_BIN=$(swiftly run swift build -c release --arch x86_64 --show-bin-path)
  BIN="$ARM_BIN"
else
  swiftly run swift build -c release
  BIN=$(swiftly run swift build -c release --show-bin-path)
fi
[[ -f "$PROJECT_DIR/assets/branding/QuotaNest.icns" ]]
[[ -d "$BIN/QuotaNest_QuotaNest.bundle" ]]
rm -rf "$OUT"
APP="$OUT/Contents"
mkdir -p "$APP/MacOS" "$APP/Resources"
if [[ "$RELEASE" == 1 ]]; then
  lipo -create "$ARM_BIN/QuotaNest" "$INTEL_BIN/QuotaNest" -output "$APP/MacOS/QuotaNest"
  lipo "$APP/MacOS/QuotaNest" -verify_arch arm64 x86_64
else
  cp "$BIN/QuotaNest" "$APP/MacOS/QuotaNest"
fi
cp -R "$BIN/QuotaNest_QuotaNest.bundle" "$APP/Resources/"
for language in zh-hans en; do
  [[ -d "$BIN/QuotaNest_QuotaNest.bundle/$language.lproj" ]]
  cp -R "$BIN/QuotaNest_QuotaNest.bundle/$language.lproj" "$APP/Resources/"
done
cp "$PROJECT_DIR/assets/branding/QuotaNest.icns" "$APP/Resources/QuotaNest.icns"
cat > "$APP/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>QuotaNest</string>
    <key>CFBundleIdentifier</key><string>local.quotanest</string>
    <key>CFBundleName</key><string>QuotaNest</string>
    <key>CFBundleDisplayName</key><string>QuotaNest</string>
    <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
    <key>CFBundleLocalizations</key><array><string>zh-Hans</string><string>en</string></array>
    <key>CFBundleIconFile</key><string>QuotaNest.icns</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>QuotaNestSourceRevision</key><string>$REVISION</string>
    <key>QuotaNestBuildTime</key><string>$BUILD_TIME</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
printf 'APPL????' > "$APP/PkgInfo"
codesign --force --deep -s - "$OUT"
codesign --verify --deep --strict "$OUT"
PACKAGED=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist")
[[ "$PACKAGED" == "$VERSION" ]] || { echo "✗ 打包版本不匹配" >&2; exit 1; }

if [[ "$RELEASE" == 1 ]]; then
  ARTIFACTS="$PROJECT_DIR/.build/release-artifacts"
  ZIP="$ARTIFACTS/QuotaNest-$VERSION-universal.zip"
  mkdir -p "$ARTIFACTS"
  [[ "${ZIP:A}" == "$PROJECT_DIR/.build/release-artifacts/QuotaNest-$VERSION-universal.zip" ]] || exit 1
  if [[ -e "$ZIP" ]]; then rm -f "$ZIP"; fi
  ditto -c -k --sequesterRsrc --keepParent "$OUT" "$ZIP"
  (cd "$ARTIFACTS" && shasum -a 256 "QuotaNest-$VERSION-universal.zip" > SHA256SUMS)
  echo "✓ QuotaNest $VERSION universal release package"
  echo "  ZIP: $ZIP"
  echo "  Revision: $REVISION"
  echo "  Architectures: $(lipo -archs "$APP/MacOS/QuotaNest")"
  exit 0
fi

if [[ "$BUILD_ONLY" == 1 ]]; then
  echo "✓ QuotaNest $VERSION 已打包，未安装: $OUT"
  exit 0
fi

DEST="$HOME/Applications"
INSTALL="$DEST/QuotaNest.app"
LEGACY="$DEST/TokenHUD.app"
mkdir -p "$DEST"
[[ "${INSTALL:A}" == "${DEST:A}/QuotaNest.app" ]] || exit 1
rm -rf "$INSTALL"
cp -R "$OUT" "$DEST/"
codesign --verify --deep --strict "$INSTALL"
INSTALLED=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INSTALL/Contents/Info.plist")
[[ "$INSTALLED" == "$VERSION" ]] || { echo "✗ 安装版本不匹配" >&2; exit 1; }
if [[ -d "$LEGACY" && "${LEGACY:A}" == "${DEST:A}/TokenHUD.app" ]]; then
  LEGACY_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$LEGACY/Contents/Info.plist" 2>/dev/null || true)
  if [[ "$LEGACY_ID" == "local.tokenhud" ]]; then rm -rf "$LEGACY"; fi
fi
echo "✓ QuotaNest $VERSION 已安装"
echo "  路径: $INSTALL"
echo "  构建: $BUILD_TIME"
echo "✓ 图标、签名及版本核对通过"
