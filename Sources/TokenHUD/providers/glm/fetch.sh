#!/bin/zsh
# TokenHUD 插件: CC-GLM (wrap 现有 node provider, cat 共享缓存)
USAGE_PROVIDER_NAME=glm "${TOKENHUD_NODE:?TOKENHUD_NODE not set}" \
  "$HOME/.claude/hud/glm-usage-provider.mjs" >/dev/null 2>&1
cat "$HOME/.claude/hud/.glm-usage-cache.json"
