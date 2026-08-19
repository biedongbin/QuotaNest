#!/bin/zsh
USAGE_PROVIDER_NAME=gpt "${TOKENHUD_NODE:?TOKENHUD_NODE not set}" \
  "$HOME/.claude/hud/glm-usage-provider.mjs" >/dev/null 2>&1
cat "$HOME/.claude/hud/.gpt-usage-cache.json"
