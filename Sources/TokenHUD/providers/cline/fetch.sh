#!/bin/zsh
# TokenHUD 模板: cline account wrapper
set -eu
export TOKENHUD_HUD_DIR="${TOKENHUD_HUD_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hud}"
export USAGE_PROVIDER_NAME=cline
export USAGE_AUTH_FILE="${TOKENHUD_AUTH_FILE:-${USAGE_AUTH_FILE:-$TOKENHUD_HUD_DIR/.{SLUG}-usage-auth.json}}"
export USAGE_CACHE_FILE="${TOKENHUD_CACHE_FILE:-${USAGE_CACHE_FILE:-$TOKENHUD_HUD_DIR/.{SLUG}-usage-cache.json}}"
"${TOKENHUD_NODE:?TOKENHUD_NODE not set}" "$TOKENHUD_HUD_DIR/cline-usage-provider.mjs"
if [[ "${TOKENHUD_STDOUT_ONLY:-0}" != "1" ]]; then cat "$USAGE_CACHE_FILE"; fi
