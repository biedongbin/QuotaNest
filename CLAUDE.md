# TokenHUD

macOS 菜单栏 App（LSUIElement），SwiftUI + NSPanel/NSStatusItem 自绘，SwiftPM 构建。

## 构建与打包

- **必须用 swiftly 工具链**（系统 CLT 的 Swift 6.1.2 与 ManifestAPI ABI 不匹配，直接 `swift build` 会链接失败）：
  ```zsh
  export PATH="$HOME/.swiftly/bin:$PATH"
  swiftly run swift build && swiftly run swift test   # 计数与结果以本次 suite 最终汇总为准；跳过项不算已验
  zsh scripts/package.sh                               # 打包 .app → ~/Applications（App 运行中会拒绝，先 pkill -x TokenHUD）
  open ~/Applications/TokenHUD.app
  ```

## 当前业务契约（2026-11-04）

当前权威入口为 [供应商账号三层需求与技术契约](docs/account-management-rebuild.md)，旧重构文档仅供历史追溯。

1. 基础模型接入分 **Auth 认证调用／API Key 调用**；Auth 当前只读既有本机 CLI／JSON 授权来源，不写回外部 auth，不把尚未实现的 App 浏览器 OAuth 登录写成已实现。
2. 用量查询通常继承基础接入的同一认证，地址／解析可以不同；不常规要求第二套 Key。网页 accessToken／Cookie 是旧特殊兼容，不是默认接入前提。
3. 定时 API 调用用于尝试主动开启按首次使用计时的动态 5h 窗口，提高工作时段的额度利用机会，不是强制 reset／余额刷新，也不保证供应商必然开窗。模型须适用于目标套餐／用量池，不能只按便宜名称推荐。

本轮实现与验收结果须据实际版本和 suite 输出记录，构建成功不等于所有供应商 Auth 真实联通或窗口机制已验证。

## 架构（不可违反）

**插件式供应商**：每家供应商 = `providers/<name>/`（manifest.json + fetch.sh），主框架自动扫描加载，**加供应商不改主框架**。

- 协议差异（queryUrl/queryAuth/refreshUrl/refreshProtocol/refreshAuth/refreshHeader/testModel/testPrompt）全部声明在 **manifest.json**，主框架（ProviderConfigStore/RefreshTrigger）纯通用，无 slug switch
- 账号通过 `template` 引用供应商类型；固定地址／协议及支持的认证、查询能力由类型声明。旧 `builtin` 字段仅保留兼容读取，不再单凭该布尔值定义当前类型能力或编辑锁定规则。
- 特殊兼容解析（旧 glm JWT、oc-go cookie HTML、ollama 页面 data-time）在各自 provider 脚本（~/.claude/hud/*.mjs），不进主框架，也不替代默认认证继承路径。
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
