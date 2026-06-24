#!/usr/bin/env bash
#
# Fetches the go2rtc binary (a small Go program by AlexxIT) into ./Runtime so it
# can be embedded in the app. Home Assistant's built-in `go2rtc` integration
# discovers the binary via `shutil.which("go2rtc")` and then *manages* it
# itself (spawns it on port 11984, writes its config, lets it exec ffmpeg).
# Bundling it — together with ffmpeg — gives fast, reliable camera snapshots and
# WebRTC live view for RTSP cameras (e.g. the Aqara doorbell), with no system
# install. `BundledRuntime`/`EnvironmentManager` symlink it onto the venv's bin
# dir (which is on the launched HA process's PATH).
#
# Output:
#   Runtime/go2rtc/go2rtc     # native go2rtc binary
#
# Env overrides:
#   GO2RTC_VERSION   release tag (default: v1.9.14 — keep in sync with Home
#                    Assistant's go2rtc RECOMMENDED_VERSION to avoid the
#                    "outdated go2rtc" repair warning).
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Runtime/go2rtc"

GO2RTC_VERSION="${GO2RTC_VERSION:-v1.9.14}"

case "$(uname -m)" in
  arm64) ARCH=arm64 ;;
  x86_64) ARCH=amd64 ;;
  *) echo "error: unsupported arch $(uname -m)." >&2; exit 1 ;;
esac

ASSET="go2rtc_mac_${ARCH}.zip"
URL="https://github.com/AlexxIT/go2rtc/releases/download/${GO2RTC_VERSION}/${ASSET}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Downloading go2rtc ${GO2RTC_VERSION} ($ASSET)"
curl -fSL "$URL" -o "$WORK/$ASSET"

echo "==> Extracting"
# The zip contains a single binary named "go2rtc".
unzip -oq "$WORK/$ASSET" -d "$WORK"
BIN="$(find "$WORK" -maxdepth 1 -type f -name 'go2rtc*' ! -name '*.zip' | head -n1)"
[[ -n "$BIN" ]] || { echo "error: go2rtc binary not found in archive." >&2; exit 1; }

rm -rf "$DEST"
mkdir -p "$DEST"
cp "$BIN" "$DEST/go2rtc"
chmod +x "$DEST/go2rtc"

echo "    $("$DEST/go2rtc" --version 2>&1 | head -1)"
echo "==> Done. go2rtc is at $DEST ($(du -sh "$DEST" | cut -f1))"
