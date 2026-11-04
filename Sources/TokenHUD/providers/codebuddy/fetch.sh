#!/bin/zsh
# TokenHUD codebuddy: explicit account snapshot only.
set -eu
export TOKENHUD_HUD_DIR="${TOKENHUD_HUD_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hud}"
export TOKENHUD_CODING_PROVIDER=codebuddy
export TOKENHUD_CACHE_FILE="${TOKENHUD_CACHE_FILE:-$TOKENHUD_HUD_DIR/.codebuddy-usage-cache.json}"
"${TOKENHUD_NODE:?TOKENHUD_NODE not set}" "$TOKENHUD_HUD_DIR/catalog-coding-provider.mjs"
if [[ "${TOKENHUD_STDOUT_ONLY:-0}" != "1" ]]; then cat "$TOKENHUD_CACHE_FILE"; fi
