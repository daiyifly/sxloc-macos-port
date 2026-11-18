#!/usr/bin/env bash
# Prepares a self-contained CPython + pymobiledevice3 runtime for the macOS USB
# developer channel. macOS has no official embeddable Python package, so we use
# python-build-standalone (the same source that powers `uv python`).
#
# Usage: bash scripts/prepare-usb-runtime-macos.sh [arm64|x64] [build-root]
# Outputs the absolute runtime directory on stdout on success.
set -euo pipefail

ARCH="${1:-arm64}"
BUILD_ROOT="${2:-${PWD}/build/usb}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

case "$ARCH" in
  arm64)
    TARGET="aarch64-apple-darwin"
    SHA="42031ed5f0d38777335252c8c77d64708c8010dd67c128246bdec25000672666"
    ;;
  x64)
    TARGET="x86_64-apple-darwin"
    SHA="f6c82fcf867b4aaadd373ac97699ad95fbb9c96f9ecf9b25775943aa5458b87f"
    ;;
  *) echo "Unknown architecture: $ARCH (use arm64 or x64)" >&2; exit 2 ;;
esac

TAG="20261110"
PYVER="3.14.10"
ASSET="cpython-${PYVER}+${TAG}-${TARGET}-install_only.tar.gz"
URL="https://github.com/astral-sh/python-build-standalone/releases/download/${TAG}/cpython-${PYVER}%2B${TAG}-${TARGET}-install_only.tar.gz"
PMD3_VERSION="11.55.0"

CACHE="$BUILD_ROOT/cache"
RUNTIME="$BUILD_ROOT/runtime-$ARCH"
mkdir -p "$CACHE"

ARCHIVE="$CACHE/$ASSET"
if [[ ! -f "$ARCHIVE" ]]; then
  echo "[usb-runtime] 下载自包含 Python $PYVER ($TARGET)…" >&2
  curl -fL --retry 3 "$URL" -o "$ARCHIVE"
fi
ACTUAL="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
if [[ "$ACTUAL" != "$SHA" ]]; then
  echo "错误：Python 运行时 SHA256 校验失败（期望 $SHA，实际 $ACTUAL）" >&2
  exit 1
fi

# Fingerprint = pump version + requirements content. Rebuild only when changed.
FINGERPRINT="$(printf '%s' "$PMD3_VERSION" | shasum -a 256 | awk '{print $1}')"
DERIVED="$RUNTIME/pymobiledevice3-$PMD3_VERSION"
MARKER="$DERIVED/.runtime-lock"
PY="$DERIVED/bin/python3"

if [[ -f "$MARKER" && "$(cat "$MARKER")" == "$FINGERPRINT" ]] && [[ -x "$PY" ]]; then
  echo "$DERIVED"
  exit 0
fi

rm -rf "$RUNTIME"
mkdir -p "$RUNTIME"
echo "[usb-runtime] 解压 Python 运行时…" >&2
tar -xzf "$ARCHIVE" -C "$RUNTIME"
# install_only archives extract to a single top-level `python/` directory.
PYROOT="$RUNTIME/python"
if [[ ! -x "$PYROOT/bin/python3" ]]; then
  # Some releases place binaries at the archive root.
  PYROOT="$RUNTIME"
fi
mkdir -p "$DERIVED"
cp -R "$PYROOT/bin" "$PYROOT/lib" "$PYROOT/include" "$DERIVED/" 2>/dev/null || cp -R "$PYROOT/." "$DERIVED/"
PY="$DERIVED/bin/python3"
# Ensure a stable `python3` entry point exists (C# launches bin/python3).
if [[ ! -x "$PY" ]]; then
  ln -sf python3.14 "$PY"
fi

echo "[usb-runtime] 安装 pymobiledevice3==$PMD3_VERSION 及依赖…" >&2
"$PY" -m ensurepip --upgrade >/dev/null 2>&1 || true
"$PY" -m pip install --no-compile --disable-pip-version-check \
  "pymobiledevice3==$PMD3_VERSION" >&2

echo "[usb-runtime] 验证关键模块导入…" >&2
"$PY" -c 'import pymobiledevice3; from pymobiledevice3.remote.userspace_tunnel import UserspaceRsdTunnel; from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation; from pymobiledevice3.services.simulate_location import DtSimulateLocation; from pymobiledevice3.usbmux import list_devices; print("pymobiledevice3", pymobiledevice3.__version__)' >&2

printf '%s' "$FINGERPRINT" > "$MARKER"
echo "$DERIVED"
