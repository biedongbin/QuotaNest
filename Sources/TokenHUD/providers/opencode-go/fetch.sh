#!/bin/zsh
"${TOKENHUD_NODE:?TOKENHUD_NODE not set}" \
  "$HOME/.claude/hud/oc-go-usage-provider.mjs" >/dev/null 2>&1
cat "$HOME/.claude/hud/.oc-go-usage-cache.json"
