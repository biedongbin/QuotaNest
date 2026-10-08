#!/bin/zsh
# TokenHUD 模板: glm 账号实例 (实例化时 {SLUG} 替换为实际 slug)
export USAGE_PROVIDER_NAME=glm
export USAGE_AUTH_FILE="$HOME/.claude/hud/.{SLUG}-usage-auth.json"
export USAGE_CACHE_FILE="$HOME/.claude/hud/.{SLUG}-usage-cache.json"
"${TOKENHUD_NODE:?TOKENHUD_NODE not set}" "$HOME/.claude/hud/glm-usage-provider.mjs" >/dev/null 2>&1
cat "$HOME/.claude/hud/.{SLUG}-usage-cache.json"
