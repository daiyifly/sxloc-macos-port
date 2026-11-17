#!/usr/bin/env bash
# Builds the full macOS Flutter app (UI + cross-platform JSON-RPC core + IOBluetooth
# bridge) and wraps it into a codesigned, notarization-ready DMG.
#
# Requirements (CI image macos-15 or a local Mac):
#   - Xcode command line tools (xcrun clang, plutil, codesign, hdiutil)
#   - .NET 10 SDK
#   - Flutter 3.50 / Dart 3.14 (stable)
#
# Usage: bash scripts/build-macos.sh [arm64|x64] [output.dmg]
set -euo pipefail

ARCH="${1:-arm64}"
OUTPUT="${2:-dist/suixing-macos-${ARCH}.dmg}"

case "$ARCH" in
  arm64) RID="osx-arm64"; DART_ARCH="arm64" ;;
  x64)   RID="osx-x64";   DART_ARCH="x64" ;;
  *) echo "Unknown architecture: $ARCH (use arm64 or x64)" >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

for tool in dotnet flutter xcrun; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "错误：缺少 $tool，请先安装（.NET 10 SDK / Flutter 3.50 / Xcode CLI）。" >&2
    exit 1
  fi
done

FLUTTER_BIN="$(command -v flutter)"
FLUTTER_ROOT="$(cd "$(dirname "$FLUTTER_BIN")/.." && pwd)"

mkdir -p "$(dirname "$OUTPUT")"
OUTDIR="$(cd "$(dirname "$OUTPUT")" && pwd)"
OUTPUT="$OUTDIR/$(basename "$OUTPUT")"

WORK="$ROOT/build/macos-$ARCH"
STAGE="$WORK/dmg-root"
APPNAME="随行定位.app"
APP="$STAGE/$APPNAME"
CONTENTS="$APP/Contents"

rm -rf "$WORK"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$STAGE/Applications"

# ---------------------------------------------------------------------------
# 1. Compile the universal IOBluetooth bridge (Objective-C -> dylib).
#    MacBtRfcommTransport.cs P/Invokes "iap2macbt" -> libiap2macbt.dylib.
# ---------------------------------------------------------------------------
echo "[1/5] 编译 IOBluetooth 桥接库…"
xcrun clang -fobjc-arc -fPIC -O2 -dynamiclib \
  -arch arm64 -arch x86_64 \
  -framework Foundation -framework IOBluetooth \
  -o "$WORK/libiap2macbt.dylib" Native/MacBluetoothBridge.m

# ---------------------------------------------------------------------------
# 2. Publish the cross-platform JSON-RPC core for this architecture.
# ---------------------------------------------------------------------------
echo "[2/5] 发布定位核心 ($RID)…"
dotnet publish BridgeMac/SuixingLoc.Core.csproj -c Release -r "$RID" \
  --self-contained true \
  -p:PublishSingleFile=true \
  -p:EnableCompressionInSingleFile=true \
  -p:IncludeNativeLibrariesForSelfExtract=true \
  -p:DebugType=None -p:DebugSymbols=false \
  -o "$WORK/core-publish"

# ---------------------------------------------------------------------------
# 3. Build the Flutter macOS desktop app.
# ---------------------------------------------------------------------------
echo "[3/5] 生成 runner 并构建 Flutter macOS 应用…"
(
  cd FlutterApp
  "$FLUTTER_BIN" config --enable-macos-desktop >/dev/null
  # The upstream project ships windows/ and android/ runners only. Generate the
  # macOS runner if it is not committed yet (idempotent when present).
  if [[ ! -d macos ]]; then
    "$FLUTTER_BIN" create --platforms=macos --project-name suixing_loc . >/dev/null
  fi
  # The app launches a sibling core process and uses IOBluetooth. The default
  # App Sandbox blocks both, so disable it for this direct-distribution DMG.
  for entitlements in macos/Runner/DebugProfile.entitlements macos/Runner/Release.entitlements; do
    if [[ -f "$entitlements" ]]; then
      /usr/libexec/PlistBuddy -c "Set :com.apple.security.app-sandbox false" "$entitlements" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :com.apple.security.app-sandbox bool false" "$entitlements"
    fi
  done
  "$FLUTTER_BIN" pub get
  "$FLUTTER_BIN" build macos --release \
    --dart-define=APP_VERSION="${APP_VERSION:-1.2.0}" \
    --dart-define=APP_BUILD="${APP_BUILD:-1}" \
    --dart-define=PROJECT_GITHUB_URL="${PROJECT_GITHUB_URL:-https://github.com/yfl520/sxloc}"
)
FLUTTER_APP="$ROOT/FlutterApp/build/macos/Build/Products/Release/随行定位.app"
if [[ ! -d "$FLUTTER_APP" ]]; then
  echo "错误：Flutter 构建未产出 $FLUTTER_APP" >&2
  exit 1
fi
cp -R "$FLUTTER_APP/." "$APP/"

# ---------------------------------------------------------------------------
# 4. Lay out resources the core process needs next to the Flutter executable.
#    core_client.dart resolves core/SuixingLoc.Core relative to the executable.
# ---------------------------------------------------------------------------
echo "[4/5] 组装应用包…"
mkdir -p "$CONTENTS/MacOS/core"
cp "$WORK/core-publish/SuixingLoc.Core" "$CONTENTS/MacOS/core/SuixingLoc.Core"
cp "$WORK/libiap2macbt.dylib" "$CONTENTS/MacOS/core/libiap2macbt.dylib"
chmod 755 "$CONTENTS/MacOS/core/SuixingLoc.Core"

# Info.plist: add the Bluetooth usage description required by IOBluetooth.
/usr/libexec/PlistBuddy -c "Add :NSBluetoothAlwaysUsageDescription string 用于查找已配对的 iPhone，查询 iAP2 服务并建立蓝牙 RFCOMM 连接。" "$CONTENTS/Info.plist" 2>/dev/null || true

cp LICENSE "$CONTENTS/Resources/LICENSE"
cp README.md "$CONTENTS/Resources/README.md"
printf 'upstream=%s\narchitecture=%s\n' "$(git rev-parse HEAD)" "$ARCH" > "$STAGE/build-revision.txt"
git archive --format=tar HEAD | gzip -9 > "$STAGE/source.tar.gz"

# ---------------------------------------------------------------------------
# 5. Ad-hoc codesign every Mach-O, then the bundle, then produce the DMG.
#    For distribution outside the App Store, replace "-" with a Developer ID
#    Application cert and add `xcrun notarytool submit` + `xcrun stapler staple`.
# ---------------------------------------------------------------------------
echo "[5/5] 签名并打包 DMG…"
codesign --force --sign - "$CONTENTS/MacOS/core/libiap2macbt.dylib"
codesign --force --sign - "$CONTENTS/MacOS/core/SuixingLoc.Core"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

hdiutil create -ov -format UDZO -fs HFS+ \
  -volname "随行定位 ($ARCH)" -srcfolder "$STAGE" "$OUTPUT"
hdiutil verify "$OUTPUT"

(
  cd "$OUTDIR"
  shasum -a 256 "$(basename "$OUTPUT")" > "$(basename "$OUTPUT").sha256"
)

echo "完成：DMG=$OUTPUT"
ls -lh "$OUTPUT"
