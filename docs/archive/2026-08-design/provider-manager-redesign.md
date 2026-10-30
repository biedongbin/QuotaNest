# 供应商管理重做 — 需求与设计大纲

> 2026-10-28 起。目标：现有 `SettingsView`（一个 Form + 一行行堆叠控件）视觉丑、信息层级缺失、操作路径混乱。
> 重做为「供应商管理」，并交付 **3 个可切换的布局版本** 供对比选择。

## 1. 领域模型（重做的地基）

用户判断：AI 供应商无非两个维度。

| 维度 | 取值 | 含义 |
|---|---|---|
| **授权模式 authMode** | `apikey` | 用户粘贴 API Key（GLM / Cline / Ollama / one-api 中转） |
| | `local` | 读取本机 CLI 已登录凭证，不复制、不写回（GPT ← `~/.codex/auth.json`） |
| | `oauth` | 预留：App 内走 OAuth 授权流程（本期只占位，不实现） |
| **协议 protocol** | `openai` | `/v1/chat/completions` |
| | `anthropic` | `/v1/messages` |

现有 manifest 已有 `queryAuth`（bearer/jwt/cookie/header，决定凭证**放在哪个字段**）与 `refreshProtocol`（anthropic/openai，决定**触发刷新用什么协议**）。
新增 `authMode`，仅影响 **UI 表达与表单字段**，不影响解析逻辑（解析仍在各 provider 脚本）。

## 2. 用量查询现状（5 家已探明）

| 供应商 | 端点 | 模型 | 桶 | 授权 |
|---|---|---|---|---|
| Claude-Max | 本地 rate_limits | 百分比 | 5h/周 | OAuth(本地) |
| GLM | `/api/monitor/usage/quota/limit` | 百分比 | 5h/周 | apikey |
| GPT | `chatgpt.com/backend-api/wham/usage` | 百分比 | 5h/周 | local(codex) |
| Ollama | `/api/balance` | 百分比/美元 | 5h/周/月 | apikey |
| Cline | `users/me/plan` + `usages` 翻页 | 百分比 | 5h/周 | apikey |
| OC-Go | provider 脚本 | 百分比 | 5h/周/月 | apikey |

结论：**查询无法统一成一个模板**（响应结构各异），但**展示可以统一**——都是「n 个窗口桶 × 百分比 + 重置时间」。
故 UI 只认 `buckets` 字典 + 标准 `UsageCache`，不认具体供应商。

## 3. 三个版本

切换方式：管理窗顶部 Segmented「布局 A / B / C」，选择持久化到 UserDefaults，默认 A。

### 版本 A — 侧栏 + 详情（macOS 原生，参考 系统设置 / cc-switch）
- 左栏：供应商列表，按 **授权模式分组**（API Key / 本机登录），每项 = 徽标 + 名称 + 最高百分比 + 状态点；支持拖拽排序、搜索框、「+ 添加」。
- 右栏：选中供应商的详情
  - 头部：大徽标 + 名称 + slug + 启停开关 + 「刷新额度」「写入 HUD」
  - 用量卡：每桶一张小卡（标签 / 大数字 / 进度条 / 重置倒计时），过期标 `*`
  - 凭证卡：模式徽章 + 字段（apikey: SecureField；local: 只读路径 + 「检查」）
  - 触发卡：协议 + url + 模型 + 提示词 + 测试按钮 + 定时时间点 chips
  - 底部：删除（destructive，需确认）
- 优点：信息最全、最像原生 App、长期可扩展。

### 版本 B — 卡片网格（参考 9router dashboard）
- 顶部工具条：搜索 + 分组筛选（全部 / API Key / 本机登录）+ 视图密度 + 「+ 添加」。
- 主体：自适应网格，每供应商一张卡
  - 卡头：徽标 + 名称 + 授权模式徽章 + ⋯ 菜单（编辑/复制/刷新/删除）
  - 卡体：每桶一行迷你进度（标签 + bar + 百分比 + 倒计时）
  - 卡脚：状态徽章（正常 / 过期 / 需登录 / 错误）+ 启停开关
  - 错误态：整卡降饱和 + 错误文案 + 「重试」
- 编辑走 sheet（复用统一表单）。
- 优点：一眼扫全部，视觉最有产品感。

### 版本 C — 高密度清单（类似运维表）
- 单列表格，列：☰ 拖拽 / 徽标+名称 / 模式 / 5h / 周 / 月 / 状态 / 开关 / ⋯
- 每行进度用小号 bar + 数字，多供应商时最省空间
- 行点击展开，展开区含凭证要点 + 快捷操作
- 优点：供应商多时效率最高。

## 4. 统一的「添加供应商」流程（三版共用）
1. **选类型**：卡片墙，按授权模式分组；含「通用自定义（OpenAI 兼容）」。
   每张卡展示：徽标、名称、模式徽章、一句话说明、支持桶。
2. **填配置**：动态表单
   - 名称（必填，实时 slug 预览与冲突提示）
   - 凭证区按 `authMode`/`queryAuth` 渲染
   - 「测试连接」就地反馈（成功绿 / 失败橙，带 HTTP 状态）
   - 定时触发时间点（HH:MM 校验）
3. 保存 → 关闭 → 自动刷新。

## 5. 视觉规范（统一）
- 徽标用 `ProviderBadge`（已存在），accent 由 manifest 给。
- 用量语义色沿用 `HUDFmt.pctColor`：<70 绿 / 70–89 黄 / ≥90 红 / 无值 dim。
- 卡片圆角 10，卡底 `Color.primary.opacity(0.05)`，描边 `primary.opacity(0.08)`。
- 状态徽章：正常=绿点 / 过期=灰点+`*` / 需登录=黄点 / 错误=红点。
- 所有可点区域给 `.help()`；所有异步操作有进行中态与结果反馈。

## 6. 落地顺序
1. manifest 增 `authMode`；`ProviderManifest` 解码兼容。
2. 抽出共用组件：`ProviderStatusBadge`、`UsageMiniRow`、`MetricTile`、`CredentialSection`、`TriggerSection`。
3. 写 `ProviderManagerView`（含 A/B/C 三布局 + 切换器）。
4. 接入 `SettingsWindowManager`，保留「写入 Claude Code HUD」「node 定位」到全局工具区。
5. 构建 + 打包 + 实机截图验收三版。

## 7. 一键导入（新增需求）

三家本机管理器的存储各异，统一抽象为 `ImportCandidate`（source/name/template/apiKey/baseURL/proto/note），
预览勾选后由 `ProviderImporter.apply` 落成标准供应商实例。

| 源 | 位置 | 读取内容 | 映射 |
|---|---|---|---|
| 9router | `~/.9router/db/data.sqlite` → `providerConnections` | `data.apiKey` + `providerSpecificData.baseUrl` | glm/ollama/opencode-go/clinepass 命中内置模板; `*-compatible-*` 生成通用型 |
| cc-switch | `~/.cc-switch/cc-switch.db` → `providers` | `settings_config.env.ANTHROPIC_BASE_URL / ANTHROPIC_AUTH_TOKEN` | 一律通用型 anthropic; codex/占位凭证跳过 |
| cpamp | `~/.cli-proxy-api/*.json` | `api_key`（type=cline-pass） | 命中 cline 模板; codex/antigravity 为 OAuth 型, 由模板直读不导入 |

- 只读源端，不写回、不改动其数据库。
- 9router 仅导 `isActive=1`；cpamp 跳过 `disabled`。
- slug 冲突自动加 `-2`/`-3` 后缀。
- 非内置模板的通用型统一生成 one-api 兼容 fetch.sh + bearer auth，触发端点按协议拼 `/v1/messages` 或 `/v1/chat/completions`（已含 `/v1` 不重复）。

## 8. 边界
- 不动 provider 解析脚本语义；不改 UsageCache 协议。
- 插件式架构不可违反：新增字段可选，缺失即有默认值。
- 不实现真正的 OAuth 流程（本期仅 `authMode: oauth` 占位展示）。
- 导入不校验源端凭证是否仍有效（只判断非空/长度），有效性由导入后「刷新额度」判定。
