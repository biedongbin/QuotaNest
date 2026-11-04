#!/bin/zsh
# TokenHUD selected account snapshot: qwenwork-enterprise
set -eu
export TOKENHUD_HUD_DIR="${TOKENHUD_HUD_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hud}"
export USAGE_PROVIDER_NAME=qwenwork-enterprise
export USAGE_CACHE_FILE="${TOKENHUD_CACHE_FILE:-${USAGE_CACHE_FILE:-$TOKENHUD_HUD_DIR/.qwenwork-enterprise-usage-cache.json}}"
"${TOKENHUD_NODE:?TOKENHUD_NODE not set}" "$TOKENHUD_HUD_DIR/catalog-enterprise-provider.mjs"
if [[ "${TOKENHUD_STDOUT_ONLY:-0}" != "1" ]]; then cat "$USAGE_CACHE_FILE"; fi
