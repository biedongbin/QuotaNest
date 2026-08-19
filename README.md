# TokenHUD

多供应商 AI token 余额菜单栏 App。菜单栏图标 + 置顶悬浮窗 + 插件式供应商。

## 开发
    swift build && .build/debug/TokenHUD
    swift test

## 打包安装
    scripts/package.sh

## 供应商插件
- 内置: Sources/TokenHUD/providers/{glm,gpt,ollama,opencode-go}
- 自定义: App → 供应商管理 → 添加 (one-api 模板), 存于
  ~/Library/Application Support/TokenHUD/providers/
- 插件 = 目录 { manifest.json + fetch.sh (stdout 输出用量 json) }
- 手动调试: TOKENHUD_NODE=$(which node) ./fetch.sh

## 写入 Claude Code HUD
供应商管理 → 写入 Claude Code HUD。写 ~/.claude/hud/envs.json 并合并
settings.json 的 ACCOUNT_ENVS。statusline 需已改造支持 envs.json。
