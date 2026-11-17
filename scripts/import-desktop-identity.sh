#!/usr/bin/env bash
# Restores the build-time experimental identity from the official DiPlay v0.2.22 APK.
# Mirrors scripts/import-desktop-identity.ps1 for the macOS build.
# The material is public and embedded only for local builds; it is never committed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXPECTED='7d04db263834f22010a86847766928113d3503a273e4d2d3440d21552e173139'
APK_URL='https://github.com/shihabal3amri/DiPlay/releases/download/v0.2.22/DiPlay-0.2.22.apk'

if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [path/to/DiPlay-0.2.22.apk]" >&2
  exit 2
fi

if [[ $# -eq 1 ]]; then
  APK="$1"
else
  APK="${TMPDIR:-/tmp}/SuixingLoc-DiPlay-0.2.22.apk"
  if [[ ! -f "$APK" ]]; then
    echo "下载 DiPlay v0.2.22 官方 APK…"
    curl -fL --retry 3 -o "$APK" "$APK_URL"
  fi
fi

if [[ ! -f "$APK" ]]; then
  echo "错误：找不到 APK：$APK" >&2
  exit 1
fi

actual="$(shasum -a 256 "$APK" | awk '{print $1}')"
if [[ "$actual" != "$EXPECTED" ]]; then
  echo "错误：APK 的 SHA-256 与固定的官方版本不符，已停止导入。" >&2
  echo "  期望：$EXPECTED" >&2
  echo "  实际：$actual" >&2
  echo "其他 APK 可在应用设置中直接导入。" >&2
  exit 1
fi

DEST="$ROOT/Desktop/Private"
mkdir -p "$DEST"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/sxloc-identity.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

for name in identity.pk8 certificate.p7b; do
  unzip -p "$APK" "assets/offline-mfi/$name" > "$TMP/$name"
  size=$(wc -c < "$TMP/$name" | tr -d ' ')
  if [[ "$size" -le 0 || "$size" -gt 65536 ]]; then
    echo "错误：APK 中的 $name 缺失或大小异常（$size 字节）。" >&2
    exit 1
  fi
done

mv "$TMP/identity.pk8" "$DEST/identity.pk8"
mv "$TMP/certificate.p7b" "$DEST/certificate.p7b"
echo "已从校验通过的官方 APK 导入构建身份（写入 Desktop/Private，不会提交）。"
