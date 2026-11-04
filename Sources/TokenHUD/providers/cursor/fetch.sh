#!/bin/zsh
# TokenHUD selected-account quota adapter: cursor
set -eu
export TOKENHUD_HUD_DIR="${TOKENHUD_HUD_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hud}"
export TOKENHUD_DESKTOP_PROVIDER=cursor
export USAGE_CACHE_FILE="${TOKENHUD_CACHE_FILE:-${USAGE_CACHE_FILE:-$TOKENHUD_HUD_DIR/.cursor-usage-cache.json}}"
"${TOKENHUD_NODE:?TOKENHUD_NODE not set}" "$TOKENHUD_HUD_DIR/catalog-desktop-provider.mjs"
if [[ "${TOKENHUD_STDOUT_ONLY:-0}" != "1" ]]; then cat "$USAGE_CACHE_FILE"; fi
