#!/usr/bin/env bash
#
# Migrates a Home Assistant configuration from an old HAOS / Supervised install
# into the config directory used by this menu-bar app
# (~/Library/HomeAssistant/config).
#
# It accepts either:
#   * a HAOS full-backup .tar  (Settings → System → Backups → download),
#     created WITHOUT encryption, or
#   * an already-extracted /config directory (e.g. copied via Samba/SSH).
#
# What it does:
#   1. Refuses to run while Home Assistant is listening on the port (quit the app
#      first) so the swap is consistent.
#   2. Extracts the config out of the backup tar if needed.
#   3. Sanity-checks that it looks like a real HA config (.storage present).
#   4. Snapshots the current config to a pre-migrate-*.zip (same format the app's
#      restore uses) so you can roll back.
#   5. Replaces ~/Library/HomeAssistant/config with the migrated config.
#   6. Optionally drops the recorder history DB (--no-history) for a clean start.
#
# Usage:
#   ./Scripts/migrate-from-haos.sh <backup.tar | /path/to/config> [--no-history]
#
# Env overrides:
#   HASS_CONFIG_DIR   target config dir (default: ~/Library/HomeAssistant/config)
#   HASS_PORT         port to check for a running server (default: 8123)
#
set -euo pipefail

CONFIG_DIR="${HASS_CONFIG_DIR:-$HOME/Library/HomeAssistant/config}"
SUPPORT_DIR="$(dirname "$CONFIG_DIR")"
BACKUP_DIR="$SUPPORT_DIR/backups"
PORT="${HASS_PORT:-8123}"

NO_HISTORY=0
SRC=""
for arg in "$@"; do
  case "$arg" in
    --no-history) NO_HISTORY=1 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) SRC="$arg" ;;
  esac
done

die() { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

[[ -n "$SRC" ]] || die "give a HAOS backup .tar or a /config directory as the first argument (see --help)."
[[ -e "$SRC" ]] || die "source not found: $SRC"

# --- 1. Make sure the server is not running ----------------------------------
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  die "something is listening on port $PORT — quit the HomeAssistant app first, then re-run."
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- 2. Resolve the source into a plain config directory ---------------------
resolve_config_dir() {
  local src="$1"

  # An already-extracted config directory.
  if [[ -d "$src" ]]; then
    if [[ -d "$src/.storage" || -f "$src/configuration.yaml" ]]; then
      echo "$src"; return
    fi
    # Maybe they pointed at a folder that contains `data/` (extracted backup).
    if [[ -d "$src/data/.storage" || -f "$src/data/configuration.yaml" ]]; then
      echo "$src/data"; return
    fi
    die "directory does not look like a HA config (no .storage / configuration.yaml): $src"
  fi

  # A HAOS full-backup tar: contains homeassistant.tar.gz (+ backup.json, add-ons).
  info "Extracting backup archive" >&2
  tar -xf "$src" -C "$WORK" || die "could not read tar: $src"

  local inner
  inner="$(find "$WORK" -maxdepth 2 -name 'homeassistant.tar.gz' | head -n1)"
  if [[ -n "$inner" ]]; then
    if ! gzip -t "$inner" >/dev/null 2>&1; then
      die "the backup's homeassistant.tar.gz is encrypted. Create a NEW backup on HAOS with encryption turned OFF, or copy /config directly via Samba/SSH."
    fi
    mkdir -p "$WORK/extracted"
    tar -xzf "$inner" -C "$WORK/extracted"
    # securetar lays the config out under data/
    if [[ -d "$WORK/extracted/data/.storage" || -f "$WORK/extracted/data/configuration.yaml" ]]; then
      echo "$WORK/extracted/data"; return
    fi
    if [[ -d "$WORK/extracted/.storage" || -f "$WORK/extracted/configuration.yaml" ]]; then
      echo "$WORK/extracted"; return
    fi
    die "could not find .storage inside homeassistant.tar.gz."
  fi

  # Maybe the tar IS the config (or data/) directly.
  if [[ -d "$WORK/data/.storage" || -f "$WORK/data/configuration.yaml" ]]; then
    echo "$WORK/data"; return
  fi
  if [[ -d "$WORK/.storage" || -f "$WORK/configuration.yaml" ]]; then
    echo "$WORK"; return
  fi
  die "no Home Assistant config found in $src (expected homeassistant.tar.gz or a .storage folder)."
}

NEW_CONFIG="$(resolve_config_dir "$SRC")"
info "Using config from: $NEW_CONFIG"

# --- 3. Sanity check ---------------------------------------------------------
[[ -d "$NEW_CONFIG/.storage" ]] || echo "warning: no .storage/ in the source — UI config (devices, automations, logins) may be missing." >&2
if [[ -f "$NEW_CONFIG/.HA_VERSION" ]]; then
  info "Source HA version: $(cat "$NEW_CONFIG/.HA_VERSION")"
  echo "    (the installed HA must be >= this; HA only migrates config forward.)"
fi

# --- 4. Snapshot the current config so we can roll back ----------------------
mkdir -p "$BACKUP_DIR"
if [[ -d "$CONFIG_DIR" ]] && [[ -n "$(ls -A "$CONFIG_DIR" 2>/dev/null)" ]]; then
  TS="$(date +%Y%m%d-%H%M%S)"
  SAFETY="$BACKUP_DIR/pre-migrate-$TS.zip"
  info "Snapshotting current config → $SAFETY"
  ditto -c -k --sequesterRsrc --keepParent "$CONFIG_DIR" "$SAFETY"
fi

# --- 5. Replace the config ---------------------------------------------------
info "Installing migrated config into $CONFIG_DIR"
rm -rf "$CONFIG_DIR"
mkdir -p "$CONFIG_DIR"
# Copy contents (including dotfiles like .storage) of NEW_CONFIG into CONFIG_DIR.
( cd "$NEW_CONFIG" && ditto . "$CONFIG_DIR" )

# --- 6. Optionally drop recorder history -------------------------------------
if [[ "$NO_HISTORY" == "1" ]]; then
  info "Dropping recorder history (--no-history)"
  rm -f "$CONFIG_DIR"/home-assistant_v2.db \
        "$CONFIG_DIR"/home-assistant_v2.db-wal \
        "$CONFIG_DIR"/home-assistant_v2.db-shm
fi

cat <<EOF

==> Migration complete.

Next steps:
  1. Start the app:  open dist/HomeAssistant.app   (or relaunch it)
     Open the log window — first start re-resolves integration dependencies
     with uv and can take a few minutes.
  2. Log in at http://localhost:$PORT with your EXISTING Home Assistant account
     (users came across in .storage — no re-onboarding).
  3. Settings → System → Logs / Repairs: check for integrations that fail to
     connect. In your setup the one to verify is Matter — point it at your
     separate Matter server's address (not the old add-on host).
  4. Repoint clients to the Mac's new IP: Companion apps, ESPHome devices,
     webhooks, anything that addressed the old VM at 192.168.2.10.
  5. Move any USB Zigbee/Z-Wave stick to the Mac and update its /dev/cu.* path.
     Only run ONE instance against shared hardware/cloud — shut the old VM down.

Rollback: your previous config was saved to
  $BACKUP_DIR/pre-migrate-*.zip
EOF
