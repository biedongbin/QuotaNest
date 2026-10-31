# TokenHUD 当前规范与交付验收索引

日期：2026-10-30。本文是当前规范、实施范围与分层验收的索引。供应商双文档、现程序审计及多轮修复已产出；文档存在不等于全部能力已验证。
用户明确要求整体整改并授权实施，由主线程制定本轮 A—F 交互方案；具体布局与控件安排是实施决策，不能声称用户逐条确认。本轮状态以 [11 UI 整改验收](11-ux-remediation-acceptance.md) 为准。
此前 HUD／导航以及 GPT 周期／悬浮窗修复已有范围内证据；它们不能代替本轮总览、详情、草稿测试和窗口行为验收。

> 归档说明：2026-10-30 之前的历史过程文档（旧设计稿、原型、截图）已移至
> [`docs/archive/`](../../archive/)。除非明确要求，阅读与检索**排除归档目录**；
> 归档内容仅作历史追溯，不构成当前规范或已验证事实。当前有效文档以本目录为准。

## 文档定位与职责

主线程负责范围、顺序和阶段决策；大纲与详细规范编写者负责本索引、01／02 与 04—06 的忠实整理和自洽检查，03 参考材料已补齐永久图片链接并经主线程审阅通过。

- 01／02 保留需求与技术大纲，04—06 维护当前行为契约；审计和实现的结论须引用对应版本与证据。
- 当前进入用户授权的整体 UI 整改。实现与验收分项记录；测试必须显式隔离 settings／HUD／日志／defaults，不改真实凭证、供应商启停或计划。
- 既有方案 C 仅是候选方案；AIUsage 是学习材料，均不直接决定最终视觉、交互或架构。
- 不把旧截图、旧能力描述或原型当作新行为已验证的证据，也不宣称“无 BUG”。

## 文档索引

已有文档按实际职责列出；未产出文件不提供可误解为完成的链接。阶段出口和实际行为均需证据。

| 文档 | 阶段与状态 | 职责 |
| --- | --- | --- |
| [README.md](README.md) | S1 已完成；随阶段维护 | 唯一索引、范围边界、阶段状态与出口 |
| [01-requirements-outline.md](01-requirements-outline.md) | S1 已产出，主线程审阅通过 | 产品定位、领域、稳定 FR/NFR、行为与验收路径大纲 |
| [02-technical-outline.md](02-technical-outline.md) | S1 已产出，主线程审阅通过 | 目标职责、数据契约、隔离、调度、验证与交付大纲 |
| [03-aiusage-reference.md](03-aiusage-reference.md) | S1 已产出，永久图片链接已补齐，主线程审阅通过 | 参考材料、可借鉴点及证据边界；不代替目标需求 |
| [04-global-requirements.md](04-global-requirements.md) | 当前需求；本轮 A—F 分项验收结果与受限范围见 11 | FR 子项、可观察行为、优先级、错误恢复与接受条件 |
| [05-global-technical.md](05-global-technical.md) | 当前技术约束；实现证据分项核对 | 契约、事件顺序、执行／调度、存储兼容与验证方法 |
| [06-ui-flows-and-acceptance.md](06-ui-flows-and-acceptance.md) | 当前自然操作链；本轮状态见 11 | 信息架构、原生点击链、草稿／窗口与分层证据矩阵 |
| 下表各独立双文档包 | S3 文档已产出；服务事实按包内证据边界 | 供应商或数据来源的证据、需求、技术及验收样本 |
| 前置一致性 | 独立 07 记录未在本索引确认产出；不得视为完成 | 需求→行为→契约→验证追溯及关键待核实阻断项 |
| [08-existing-app-audit.md](08-existing-app-audit.md) | S5 已产出差距审计；不是当前 UI 通过结论 | 前置完备后对照现有 App，决定复用、修复或重写 |
| [10-hud-navigation-verification.md](10-hud-navigation-verification.md) | 已验：此前 HUD／导航有限范围 | 问题、实际安装与证据限制 |
| [11-ux-remediation-acceptance.md](11-ux-remediation-acceptance.md) | 本轮 A—F UI 整改，逐项未验／通过／受限 | 宽度矩阵、自然操作、隔离、版本与安装证据 |

以下七包双文档已产出。代码现状、官方来源与受控样本须分开，不能由文档存在推断所有能力获证。

| 包 | 需求文档 | 技术文档 | 边界 |
| --- | --- | --- | --- |
| cline-pass | [requirements.md](providers/cline-pass/requirements.md) | [technical.md](providers/cline-pass/technical.md) | Cline 官方 usage-limits 的会话证据仍待转录与脱敏 fixture |
| glm | [requirements.md](providers/glm/requirements.md) | [technical.md](providers/glm/technical.md) | 授权、额度机制及调用路径逐项核实 |
| gpt-codex | [requirements.md](providers/gpt-codex/requirements.md) | [technical.md](providers/gpt-codex/technical.md) | 订阅权益、凭证来源与可调用路径分开证明 |
| ollama | [requirements.md](providers/ollama/requirements.md) | [technical.md](providers/ollama/technical.md) | 账号与额度来源的真实语义待核实 |
| opencode-go | [requirements.md](providers/opencode-go/requirements.md) | [technical.md](providers/opencode-go/technical.md) | 服务能力与字段来源待核实 |
| claude-code | [requirements.md](providers/claude-code/requirements.md) | [technical.md](providers/claude-code/technical.md) | 本机／HUD 数据来源独立成包，不冒充官方余额接口 |
| generic-openai-anthropic | [requirements.md](providers/generic-openai-anthropic/requirements.md) | [technical.md](providers/generic-openai-anthropic/technical.md) | 调用协议兼容包，不是第三种授权方式，不承诺额度接口兼容 |

## 阶段顺序与出口

| 阶段 | 当前状态 | 出口 |
| --- | --- | --- |
| S1 大纲＋参考调研 | 已完成，主线程审阅通过；参考永久图片链接已补齐 | 两份大纲与参考材料已审；不据此提前审计程序 |
| S2 全局详细规范 | 已产出并继续维护 | 当前 A—F 要求、草稿与消费边界可追溯 |
| S3 独立文档包 | 七包双文档已产出；事实仍按证据分项 | 七包双文档完备，能力与机制具证据，字段及脱敏验收样例可追溯 |
| S4 前置一致性审查 | 独立完整记录未确认，不能补写通过 | 需求到行为到验证可追溯，无关键未核实阻断；方可进入现有程序审计 |
| S5 现有 App 审计 | 08 已产出，后续修复逐项复核 | 对照目标规范形成差距与证据，主线程决定复用／修复／重写及实施范围 |
| S6 实施与交付 | 已有范围内安装；当前 UI 整改进行中 | 范围内已发现缺陷均已修复，尚未完成能力明确不发布；关键正常／异常／恢复路径、真实数据对照与最终安装包一致性验收通过 |

前置顺序保留为工作约束，不倒填缺失审查结论。当前按用户持续授权实施 A—F 整改；每项只有匹配的新证据才更新状态，不使用虚构百分比。

## 共同判定规则

- FR-01—FR-10、NFR-01—NFR-05 是稳定编号，后续需求、技术和验收继续引用，不随章节重排更换。
- 自动额度查询与定时模型调用是两个独立任务；编辑、保存、打开页面、切 tab、导入不能隐式触发模型消费。
- 新调用计划默认关闭，迁移或导入不得自动开启；一次调用不能保证启动或重置某个额度窗口。
- 官方机制、原始字段、调用路径分别取证；有 API Key 不等于能查余额，有额度 API 不等于能用指定模型路径调用。
- 导入查重基于来源稳定标识和账号身份；名称可重复，保留用户命名，脱敏名称或自动序号不能当主键。
- 真实 UI 验收能力与权限在 S2 技术方案中前置检查；测试、截图、原型、原生 UI、接口样本和安装部署证据分层，离屏渲染不能代替点击与保存流程；受阻步骤记“未验证”。
- 团队负责自然操作路径、失败恢复与全面验收，不要求用户逐项报 Bug 或充当 QA。
- 交付范围内已发现缺陷均已修复；尚未完成能力明确不发布；关键正常／异常／恢复路径实测通过，真实供应商数据有对照，最终安装包与验收版本一致。不按严重等级忽略已知功能错误，也不保证所有未知 Bug 已被消除。

## 本轮收口状态

当前 A—F 方案已转为 [11](11-ux-remediation-acceptance.md) 的可观察验收项，初始状态为未验。既有修复证据独立保留；本轮截图、状态测试、原生事件、系统窗口行为与最终安装分别验收，不宣称整个 App 无 Bug。
