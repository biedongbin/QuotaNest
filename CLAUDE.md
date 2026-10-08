# TokenHUD

macOS 菜单栏 App（LSUIElement），SwiftUI + NSPanel/NSStatusItem 自绘，SwiftPM 构建。

## 构建与打包

- **必须用 swiftly 工具链**（系统 CLT 的 Swift 6.1.2 与 ManifestAPI ABI 不匹配，直接 `swift build` 会链接失败）：
  ```zsh
  export PATH="$HOME/.swiftly/bin:$PATH"
  swiftly run swift build && swiftly run swift test   # 32 个测试
  zsh scripts/package.sh                               # 打包 .app → ~/Applications（App 运行中会拒绝，先 pkill -x TokenHUD）
  open ~/Applications/TokenHUD.app
  ```

## 架构（不可违反）

**插件式供应商**：每家供应商 = `providers/<name>/`（manifest.json + fetch.sh），主框架自动扫描加载，**加供应商不改主框架**。

- 协议差异（queryUrl/queryAuth/refreshUrl/refreshProtocol/refreshAuth/refreshHeader/testModel/testPrompt）全部声明在 **manifest.json**，主框架（ProviderConfigStore/RefreshTrigger）纯通用，无 slug switch
- `builtin: true` = 内置供应商：url/协议锁定，只允许改秘钥/测试模型/提示词/定时任务
- 特殊解析（glm JWT、oc-go cookie HTML、ollama 页面 data-time）在各自 provider 脚本（~/.claude/hud/*.mjs），不进主框架
- auth 文件（~/.claude/hud/.*-usage-auth.json）存凭证 + scheduleTimes；缓存 .{slug}-usage-cache.json

## UI 交互基线（每次交付强制检查，先于用户发现）

每个窗口/弹层/面板交付前逐项确认：

1. **窗口基线**：可关闭（X 或 Esc）、可拖动、全局单例（重复打开只前置不叠开）、位置记忆
2. **交互基线**：可交互区域支持右键（菜单含：主操作/打开关闭切换/供应商管理/退出）；双击与单击语义完整对称（能开就能用同样手势关）
3. **状态感知**：菜单/按钮文案随状态切换（如"打开悬浮窗"↔"关闭悬浮窗"）
4. **操作反馈**：任何按钮点击后必须有可见结果（成功文案/错误文案/状态变化），不允许静默
5. **自检方法**：以"用户从打开到完成任务的每一步自然操作"走一遍，缺的当场补

## 已知约束

- 菜单栏图标用自绘 NSStatusItem（MenuBarExtra 右键被系统拦截）
- 悬浮窗 NSPanel 用 nonactivatingPanel（不抢焦点），contextMenu 可用
- fetch.sh 读 ~/.claude/hud/ 下脚本（依赖用户环境 node，TOKENHUD_NODE 注入）
