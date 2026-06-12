#!/usr/bin/env bash
#
# Builds HomeAssistant.app: compiles the Swift executable in release mode and
# assembles a proper .app bundle including the embedded CPython runtime.
#
# Prerequisite: run Scripts/bundle-runtime.sh first so ./Runtime exists.
#
# Env overrides:
#   CODESIGN_IDENTITY   Developer ID identity for distribution signing.
#                       Defaults to ad-hoc ("-") for local use.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME="$ROOT/Runtime"
APP="$ROOT/dist/HomeAssistant.app"
IDENTITY="${CODESIGN_IDENTITY:--}"
ENTITLEMENTS="$ROOT/Resources/HomeAssistant.entitlements"

if [[ ! -x "$RUNTIME/python/bin/python3" ]]; then
  echo "error: $RUNTIME/python not found — run Scripts/bundle-runtime.sh first." >&2
  exit 1
fi

echo "==> Building release executable"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/HomeAssistant"

echo "==> Assembling app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/HomeAssistant"
cp -R "$RUNTIME" "$APP/Contents/Resources/Runtime"
[[ -f "$ROOT/Resources/AppIcon.icns" ]] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"

echo "==> Code signing (identity: $IDENTITY)"
# Sign inside-out: every Mach-O file inside the embedded CPython runtime first,
# then the Swift binary, then the bundle. The interpreter and its C-extension
# .so/.dylib files must each carry the JIT / library-validation entitlements,
# otherwise the hardened runtime refuses to load them.
RUNTIME_IN_APP="$APP/Contents/Resources/Runtime/python"

sign() {
  codesign --force --options runtime --timestamp=none \
    --entitlements "$ENTITLEMENTS" -s "$IDENTITY" "$1"
}

echo "    signing Mach-O files in embedded runtime…"
# Find Mach-O binaries (executables + shared libraries) and sign each.
while IFS= read -r -d '' f; do
  if file -b "$f" | grep -q 'Mach-O'; then
    sign "$f"
  fi
done < <(find "$RUNTIME_IN_APP" -type f \( -name '*.so' -o -name '*.dylib' -o -perm -u+x \) -print0)

# Ensure the interpreter symlink target itself is signed.
sign "$RUNTIME_IN_APP/bin/python3"

echo "    signing app executable…"
sign "$APP/Contents/MacOS/HomeAssistant"

echo "    signing bundle…"
sign "$APP"

echo "==> Verifying signature"
codesign --verify --strict --verbose=2 "$APP" || true

echo "==> Done: $APP"
echo "    Run with: open \"$APP\"   (look for the house icon in the menu bar)"
