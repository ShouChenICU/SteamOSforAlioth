#!/usr/bin/env bash
# Copy bundled SM8550 Decky plugins into ~/homebrew/plugins/.
# Does not require PluginLoader to already exist (pre-seeds for first install).
set -euo pipefail

STEAM_USER="${STEAM_USER:-steamos}"
STEAM_HOME="${STEAM_HOME:-/home/${STEAM_USER}}"
BUNDLE_ROOT="${BUNDLE_ROOT:-/usr/share/steamos-odin/decky-plugins}"
HOMEBREW="${STEAM_HOME}/homebrew"
DEST="${HOMEBREW}/plugins"

log() { printf 'sync-decky-plugins: %s\n' "$*"; }

STEAM_UID="$(id -u "$STEAM_USER" 2>/dev/null || echo 1000)"
STEAM_GID="$(id -g "$STEAM_USER" 2>/dev/null || echo 1000)"

if [[ ! -d "$BUNDLE_ROOT" ]]; then
  for alt in /usr/share/steamos-odin/decky-plugins; do
    [[ -d "$alt" ]] && BUNDLE_ROOT="$alt" && break
  done
fi
if [[ ! -d "$BUNDLE_ROOT" ]]; then
  log "No bundled plugins at ${BUNDLE_ROOT} — skip"
  exit 0
fi

mkdir -p "$DEST"

# A plugin with a "models" file is only for those devices (one device-tree
# model per line); anywhere else it is left out, and taken out if it's there.
MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || true)"
ONLY="${1:-}"                    # sync just this one plugin (the boot service)

installed=0
shopt -s nullglob
for src in "${BUNDLE_ROOT}"/*; do
  [[ -d "$src" && -f "${src}/plugin.json" && -f "${src}/dist/index.js" ]] || continue
  name="$(basename "$src")"
  [[ -z "$ONLY" || "$name" == "$ONLY" ]] || continue
  if [[ -f "${src}/models" ]] && ! grep -qxF -- "$MODEL" "${src}/models"; then
    [[ -d "${DEST}/${name}" ]] && { log "Removing ${name}: not for ${MODEL:-this device}"; rm -rf "${DEST:?}/${name}"; }
    continue
  fi
  # A plugin that took over from an older one (Emulator Hub -> Loadout) lists
  # the old folder names in "replaces": those go, so Decky shows one panel.
  if [[ -f "${src}/replaces" ]]; then
    while read -r old; do
      [[ -n "$old" && "$old" != */* && -d "${DEST}/${old}" ]] || continue
      log "Removing ${old}: replaced by ${name}"; rm -rf "${DEST:?}/${old}"
    done < "${src}/replaces"
  fi
  log "Installing ${name} → ${DEST}/${name}"
  mkdir -p "${DEST}/${name}"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete \
      --exclude node_modules \
      --exclude src \
      --exclude .pnpm-store \
      --exclude __pycache__ \
      "${src}/" "${DEST}/${name}/"
  else
    rm -rf "${DEST}/${name}"
    mkdir -p "${DEST}/${name}"
    cp -a "${src}/." "${DEST}/${name}/"
    rm -rf "${DEST}/${name}/node_modules" "${DEST}/${name}/src" \
      "${DEST}/${name}/.pnpm-store" "${DEST}/${name}/__pycache__"
  fi
  installed=1
done

if [[ "${EUID}" -eq 0 ]]; then
  chown -R "${STEAM_UID}:${STEAM_GID}" "$HOMEBREW" 2>/dev/null || true
fi

if (( installed == 0 )); then
  log "No built plugins found under ${BUNDLE_ROOT}"
  exit 0
fi
log "Done"
