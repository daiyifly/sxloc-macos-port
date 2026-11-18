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
echo "[1/6] 编译 IOBluetooth 桥接库…"
xcrun clang -fobjc-arc -fPIC -O2 -dynamiclib \
  -arch arm64 -arch x86_64 \
  -framework Foundation -framework IOBluetooth \
  -o "$WORK/libiap2macbt.dylib" Native/MacBluetoothBridge.m

# ---------------------------------------------------------------------------
# 2. Publish the cross-platform JSON-RPC core for this architecture.
# ---------------------------------------------------------------------------
echo "[2/6] 发布定位核心 ($RID)…"
dotnet publish BridgeMac/SuixingLoc.Core.csproj -c Release -r "$RID" \
  --self-contained true \
  -p:PublishSingleFile=true \
  -p:EnableCompressionInSingleFile=true \
  -p:IncludeNativeLibrariesForSelfExtract=true \
  -p:DebugType=None -p:DebugSymbols=false \
  -o "$WORK/core-publish"

# ---------------------------------------------------------------------------
# 2b. Prepare the self-contained Python + pymobiledevice3 runtime for the USB
#     developer channel (downloaded once and cached under build/usb).
# ---------------------------------------------------------------------------
echo "[3/6] 准备 USB 开发者运行时 (Python + pymobiledevice3)…"
USB_RUNTIME="$(bash scripts/prepare-usb-runtime-macos.sh "$ARCH" "$ROOT/build/usb")"
echo "  USB 运行时：$USB_RUNTIME"

# ---------------------------------------------------------------------------
# 3. Build the Flutter macOS desktop app.
# ---------------------------------------------------------------------------
echo "[4/6] 生成 runner 并构建 Flutter macOS 应用…"
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
    --dart-define=APP_VERSION="${APP_VERSION:-1.3.0}" \
    --dart-define=APP_BUILD="${APP_BUILD:-1}" \
    --dart-define=PROJECT_GITHUB_URL="${PROJECT_GITHUB_URL:-https://github.com/yfl520/sxloc}"
)
# The macOS runner is generated with --project-name suixing_loc, so the built
# bundle is named suixing_loc.app (not the Chinese display name). Detect the
# actual product instead of hard-coding a name: product names vary with the
# project name / Info.plist CFBundleName across Flutter versions.
FLUTTER_PRODUCTS="$ROOT/FlutterApp/build/macos/Build/Products/Release"
FLUTTER_APP="$(find "$FLUTTER_PRODUCTS" -maxdepth 1 -type d -name '*.app' -print -quit 2>/dev/null)"
if [[ -z "$FLUTTER_APP" || ! -d "$FLUTTER_APP" ]]; then
  echo "错误：Flutter 构建未在 $FLUTTER_PRODUCTS 产出 .app" >&2
  exit 1
fi
echo "  检测到 Flutter 产物：$(basename "$FLUTTER_APP")"
cp -R "$FLUTTER_APP/." "$APP/"

# ---------------------------------------------------------------------------
# 4. Lay out resources the core process needs next to the Flutter executable.
#    core_client.dart resolves core/SuixingLoc.Core relative to the executable.
# ---------------------------------------------------------------------------
echo "[5/6] 组装应用包…"
mkdir -p "$CONTENTS/MacOS/core"
cp "$WORK/core-publish/SuixingLoc.Core" "$CONTENTS/MacOS/core/SuixingLoc.Core"
cp "$WORK/libiap2macbt.dylib" "$CONTENTS/MacOS/core/libiap2macbt.dylib"
chmod 755 "$CONTENTS/MacOS/core/SuixingLoc.Core"

# Bundle the USB runtime next to the core: core/usb/{bin/python3,worker.py,lib/...}.
# UsbDeveloperService.cs resolves it via AppContext.BaseDirectory/usb.
USB_BUNDLE="$CONTENTS/MacOS/core/usb"
mkdir -p "$USB_BUNDLE"
cp -R "$USB_RUNTIME/bin" "$USB_RUNTIME/lib" "$USB_RUNTIME/include" "$USB_BUNDLE/" 2>/dev/null || true
cp BridgeMac/UsbWorker/worker.py "$USB_BUNDLE/worker.py"
cp BridgeMac/UsbWorker/prepare_image.py "$USB_BUNDLE/prepare_image.py"
chmod 755 "$USB_BUNDLE/bin/python3" "$USB_BUNDLE/bin/python3.14" 2>/dev/null || true

# Info.plist: add the Bluetooth usage description required by IOBluetooth.
/usr/libexec/PlistBuddy -c "Add :NSBluetoothAlwaysUsageDescription string 用于查找已配对的 iPhone，查询 iAP2 服务并建立蓝牙 RFCOMM 连接。" "$CONTENTS/Info.plist" 2>/dev/null || true

cp LICENSE "$CONTENTS/Resources/LICENSE"
cp README.md "$CONTENTS/Resources/README.md"
printf 'upstream=%s\narchitecture=%s\n' "$(git rev-parse HEAD)" "$ARCH" > "$STAGE/build-revision.txt"
git archive --format=tar HEAD | gzip -9 > "$STAGE/source.tar.gz"

# ---------------------------------------------------------------------------
# 6. Ad-hoc codesign every Mach-O, then the bundle, then produce the DMG.
#    The bundled Python runtime ships native .so modules (cryptography, cffi,
#    pillow, ...). On Apple Silicon every Mach-O must be signed, and codesign
#    --deep does not reliably reach into site-packages, so sign those first.
#    Hardened runtime is intentionally NOT enabled (no --options runtime), so
#    library validation does not reject the ad-hoc signed third-party modules.
#    For App Store distribution use a Developer ID cert + notarytool instead.
# ---------------------------------------------------------------------------
echo "[6/6] 签名并打包 DMG…"
codesign --force --sign - "$CONTENTS/MacOS/core/libiap2macbt.dylib"
codesign --force --sign - "$CONTENTS/MacOS/core/SuixingLoc.Core"
# Sign every native module and executable inside the USB runtime (regular files
# only, so symlinks such as python3 -> python3.14 are left intact).
if [[ -d "$USB_BUNDLE" ]]; then
  while IFS= read -r -d '' macho; do
    codesign --force --sign - "$macho" 2>/dev/null || true
  done < <(find "$USB_BUNDLE" -type f \( -name '*.so' -o -perm -u+x \) -print0)
fi
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
