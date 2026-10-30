# 供应商管理 v2 原型 — 独立浏览器验收报告

> 2026-10-29。验收人：QA（独立浏览器会话）。**本报告只覆盖三套 HTML 交互原型的演示行为；所有数据为页面内联演示数据，模拟 ≠ 真实 API。产品代码（macOS App）零改动、未验证。**

## 1. 验收对象与版本（SHA-256）

| 套 | 文件 | 冻结 hash | 验收轮次 |
|---|---|---|---|
| A 工作台 | `prototypes/workbench.html` | `6ae6a2f86dba3aaf45f21d8d18970cdef60b0dde0be0bf881156b9598bba9729` | 主体检查于 `22989b4a…` 完成；URL 组于 `6ae6a2f8…` 复跑（作者声明仅改 `okUrl` 一处，前后 diff 由作者提供） |
| B 运行台 | `prototypes/operations.html` | `fb7ac2782a8466b27e88a95aede15ce8ead860eca58bff40c21021e51c9b2ddc` | 全部检查于此 hash |
| C 设置中心 | `prototypes/settings.html` | `52a79ee33251056e7fab2d777b5f398d4177bac9321bb525fa2d80f2a79fac58` | 全部检查于此 hash |

每轮会话记录打开前/结束后双 hash，`changed=false`（A 的 URL 复跑轮亦然）。

## 2. 方法与边界

- 已装 `@playwright/cli` 内的 playwright-core（1.60.0-alpha）驱动独立 headless Chrome（`/Applications/Google Chrome.app`），`file://` 打开，全新 context，不动用户浏览器页面。
- **网络边界**：context 级路由拦截全部 `http(s)` 并计数——三套全部轮次合计 **0 次外网请求尝试**。
- 视口：主检查 1100×760，布局检查 900×640；截图 `animations:'disabled'`，等待 toast（3.2s）消失后拍摄。
- 断言不依赖文案猜测处均先以页面内函数 ground-truth 取证（如 `okUrl`/`validate`/`validUrl` 直接调用）。
- 主线程已视觉审阅 A 四张截图；B/C 截图待主线程 Read。本报告不含审美结论。

## 3. 结果汇总

### A — workbench.html（PASS，1 项经返工后 PASS）

| 检查 | 结果 | 要点 |
|---|---|---|
| 总览离线加载 + 截图 | PASS | 1100×760 无横向溢出 |
| GLM 编辑：坏 HH:MM（9:00）→ 行内错误 → 修 07:45 → 保存 → 重开一致 | PASS | |
| URL 真解析 ground truth（10 坏/5 好） | PASS（`6ae6a2f8`） | javascript:/file:/ftp:/裸域/空 host/空格/tab/%20 host/\x01 全拒；127.0.0.1/localhost/[::1]/常规域名/空值全收 |
| 双开关独立（GLM） | PASS | 关 autoQuery 不动 autoTrigger；保存后持久化正确；保存期间 0 请求 |
| GPT/Cline 仅自动查询 | PASS | 只有 f-autoquery，无 f-autotrigger、无时间点输入 |
| generic 仅调用 | PASS | 无 autoquery、有 autotrigger；额度文案「未接入额度查询」 |
| 7 模板 | PASS | GLM/Ollama/OC-Go/GPT/Cline/通用 OpenAI/通用 Anthropic |
| 脏态：继续编辑保留草稿 / 放弃恢复原值 | PASS | |
| 模型调用：确认弹层（含消耗提示）/ 取消不发 | PASS | |
| 删除取消保留账号 | PASS | |
| GPT 本机来源 + 只读区占比 | PASS | 占比 0.07（≤1/3） |
| Cline 查询出两桶、无调用按钮 | PASS | |
| 导入三源：dup/不支持默认禁选；9router 部分失败仅重试失败项 | PASS | 重试前后成功项不变、不重复写入 |
| 900×640 无横向溢出、保存按钮在视口内 | PASS | save y≈595 |
| 编辑页目录三锚点与分区标题一致、点击可达 | PASS | |

历史缺陷（已修复后复验）：`22989b4a` 及之前版本的 okUrl 在 Chrome 下接受含空格 host（编码 %20 后通过）与裸 TAB host —— 已由作者两次返工修复，最终 `6ae6a2f8` URL 组 PASS。

### B — operations.html（PASS）

| 检查 | 结果 | 要点 |
|---|---|---|
| 总览离线 + 截图 | PASS | 无横向溢出 |
| URL 白名单 ground truth | PASS | 10 坏（含 %20 host、tab host、\x01、空 host、bare host）全拒；域名/IPv4/IPv6/localhost/路径 %20 全收 |
| 能力矩阵 | PASS | 7 模板；gpt/cline=query-only；compat×2=call-only |
| GPT/Cline 编辑器无 call/无 sched + 原因文案 | PASS | |
| autoQuery vs scheduleOn 独立（ocgo） | PASS | 取消 autoQuery 后 scheduleOn 保持；保存持久化；0 请求 |
| HH:MM 坏值行内错误 → 修复 → 持久化 | PASS | add-time 即时校验 |
| 脏态放弃确认（ed-name） | PASS | 放弃后数据未泄漏 |
| generic 模板 ed-url 可编辑 + UI URL 错误 | PASS | javascript: 被拒，合法 URL 保存成功 |
| 调用反馈状态机（glm） | PASS | 确认 → 调用中 → 终态（演示成功/失败交替） |
| 导入：dup 禁选、部分失败重试 | PASS | 摘要「成功 2 / 失败 0 / 跳过 2」 |
| 900×640 工具栏 + 保存按钮可见 | PASS | save y≈594 |

注：B 编辑器入口为行双击 / `openEditor`；单行「编辑…」按钮位于检查器展开态。检查器覆盖表格时按钮不可点属布局预期（900×640 下收起检查器后全部可达）。

### C — settings.html（PASS）

| 检查 | 结果 | 要点 |
|---|---|---|
| 总览离线 + 截图 | PASS | |
| GPT 本机来源、触发页「不支持模型定时调用」、无 testCall | PASS | |
| Cline 三处能力 gate（视图 / 草稿表单 / 草稿 testCall） | PASS | 草稿只有 autoQuery，无 autoTrigger/testCallDraft |
| HH:MM 9:00 行内错误 → 10:15 保存 → 重开仍在 | PASS | |
| aq/at 独立（GLM 草稿） | PASS | 关 aq 不动 at；保存 0 请求；触发页状态正确反映 |
| generic 模板：7 模板选择 + UI URL 拒 javascript: 收合法 | PASS | |
| 导入：dup 默认跳过禁选、未适配行可导入、完成后按钮禁用防重复 | PASS | 「已全部导入」disabled |
| 900×640 无横向溢出、保存按钮可见 | PASS | save y≈565 |

## 4. 截图（均 1100×760，toast 已消失）

`docs/provider-manager-v2/screenshots/`：
- A：`a-overview.png` `a-editor.png` `a-import.png` `a-gpt.png`
- B：`b-overview.png` `b-editor.png` `b-import.png` `b-gpt.png`
- C：`c-overview.png` `c-editor.png` `c-import.png` `c-gpt.png`

A 主体四张摄于 `22989b4a…`；其后仅 `okUrl` 变更（`6ae6a2f8…`），不影响截图内容。B/C 全部摄于各自冻结 hash。

## 5. 复验命令（本目录 /tmp/thqa/）

前置：无（playwright-core 与 Chrome 已装；无新增依赖）。

```zsh
cd /tmp/thqa
node qa-session.mjs            # 公共库（每轮记录前后 hash/拦截/错误）
node probe-a2.mjs              # A 主体（开关/URL/GPT/Cline/generic/导入）
node probe-a3.mjs              # A 截图/锚点/只读占比
node a-url-only.mjs            # A URL 组（当前 hash 6ae6a2f8）
node probe-b10.mjs             # B HH:MM/URL UI/900×640/导入
node probe-b9.mjs              # B 开关独立/GPT/Cline/脏态
node check-c2.mjs              # C 主体（gate/HH:MM/独立/模板/URL）
node fix2.mjs                  # C 导入 + 900×640
node c-editor-shot.mjs         # C 编辑页截图
node contrast.mjs              # 基础色 WCAG 计算（validator 导出的 contrast）
node status.mjs                # 参考状态色对比（供 token 决策，非通过判定）
```

结果 JSON：`a-final*.json` / `b-final*.json` / `c-final*.json` / `a-url-final.json`，均含当轮双 hash、blocked 数、console/page error。

## 6. 颜色计算（供参考，非通过门槛）

给定基础色（A/B/C 三套 canvas/surface/ink/muted/accent）计算：正文 ink 对 surface 12.28–14.50、muted 6.18–8.19，均 ≥4.5；accent 对 surface/canvas 5.62–8.02，均 ≥3；三套单系列进度条（accent 单色）满足非文本 3:1。categorical 色带门槛不适用（全部为单系列进度），未添加类别 palette。状态色若沿用参考 status 色，A/C 亮面 warning/serious 与 B 暗面 critical 低于 3:1 —— 各套页面内实际状态 token 以 icon+label 呈现，未单独作为通过/失败判定。

## 7. 未验证项（明确列出）

- 真机 macOS App（任何 L2 项）——产品代码 0 改动。
- Safari/Firefox 渲染、真实缩放、Tab 顺序、读屏软件。
- 深色模式视觉（本轮三套均为浅色检查；B 默认深色仅截 overview）。
- 三源导入的真实数据形状（页面为内联演示行）。
- 原型保存语义仅页面内存，刷新即重置——与「演示数据」声明一致。

## 8. 边界确认

- 三套全部轮次外网请求尝试：**0**（context 路由拦截计数）。
- 未修改任何生产代码/真实配置/`~/.claude` 文件；仅写入 `docs/provider-manager-v2/screenshots/`（独占）与本报告（独占）。
- 临时浏览器会话均已关闭；未启动/停止用户 App。
