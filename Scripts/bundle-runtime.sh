#!/usr/bin/env bash
#
# Fetches a relocatable CPython runtime (python-build-standalone, maintained by
# Astral) into ./Runtime, ready to be embedded in the app. Home Assistant
# itself is NOT installed here — the app creates a virtualenv and pip-installs
# Home Assistant on first launch (see EnvironmentManager.swift). This keeps the
# .app small and lets Home Assistant be updated without rebuilding the app.
#
# Output layout:
#   Runtime/python/bin/python3      relocatable CPython 3.14 (arm64)
#   Runtime/python/lib/python3.14/  standard library
#
# Env overrides:
#   PBS_RELEASE   python-build-standalone release tag (default: 20260610)
#   PY_VERSION    CPython version           (default: 3.14.6)
#
# Home Assistant 2026.x requires Python >= 3.14.2, so do not downgrade below
# the 3.14 line. The CPython minor must match what HA requires at the time you
# build; the app re-creates its virtualenv automatically when the minor changes.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME="$ROOT/Runtime"

PBS_RELEASE="${PBS_RELEASE:-20260610}"
PY_VERSION="${PY_VERSION:-3.14.6}"

case "$(uname -m)" in
  arm64) ARCH=aarch64 ;;
  *)
    echo "error: this builds an Apple Silicon (arm64) runtime; host is $(uname -m)." >&2
    echo "       python-build-standalone also ships x86_64-apple-darwin if you need it." >&2
    exit 1
    ;;
esac

ASSET="cpython-${PY_VERSION}+${PBS_RELEASE}-${ARCH}-apple-darwin-install_only.tar.gz"
URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_RELEASE}/${ASSET}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Downloading $ASSET"
curl -fSL "$URL" -o "$WORK/$ASSET"

echo "==> Assembling CPython runtime"
# The install_only archive extracts to a top-level "python/" directory.
rm -rf "$RUNTIME/python"
mkdir -p "$RUNTIME"
tar -xzf "$WORK/$ASSET" -C "$RUNTIME"

PY="$RUNTIME/python/bin/python3"
if [[ ! -x "$PY" ]]; then
  echo "error: expected interpreter at $PY after extraction." >&2
  exit 1
fi

echo "    interpreter: $("$PY" -c 'import platform,sys; print(platform.python_version(), sys.platform, platform.machine())')"
"$PY" -m pip --version >/dev/null 2>&1 || {
  echo "error: bundled pip is not functional." >&2
  exit 1
}

echo "==> Slimming runtime (removing build-time-only / unused files)"
PYLIB="$RUNTIME/python/lib/python${PY_VERSION%.*}"
rm -rf "$PYLIB/test" "$PYLIB/idlelib" "$PYLIB/turtledemo" \
       "$PYLIB/tkinter" "$PYLIB/lib2to3" \
       "$RUNTIME/python/share" 2>/dev/null || true
find "$RUNTIME/python" -type d -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true

echo "==> Done. Runtime is at $RUNTIME ($(du -sh "$RUNTIME" | cut -f1))"
