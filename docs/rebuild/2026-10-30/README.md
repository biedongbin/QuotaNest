# TokenHUD 重建文档索引｜全局规范初稿v0.1，未审计现有程序

日期：2026-10-30。S1 已完成并经主线程审阅通过；S2 全局规范初稿已完成主线程审阅及本轮限定一致性复核。本文是本轮重建文档的唯一索引、状态与职责入口。
全局规范仍为目标建议，非用户已批准的实现方案；S3—S6 未开始，实现、原生 UI 与安装包仍未验证。
“从零”指重建需求与技术定义；复用、修复还是重写现有代码，必须留到 S5 对照审计后决定。

> 归档说明：2026-10-30 之前的历史过程文档（旧设计稿、原型、截图）已移至
> [`docs/archive/`](../../archive/)。除非明确要求，阅读与检索**排除归档目录**；
> 归档内容仅作历史追溯，不构成当前规范或已验证事实。当前有效文档以本目录为准。

## 文档定位与职责

主线程负责范围、顺序和阶段决策；大纲与详细规范编写者负责本索引、01／02 与 04—06 的忠实整理和自洽检查，03 参考材料已补齐永久图片链接并经主线程审阅通过。

- S1 大纲已完成；S2 全局规范初稿已完成主线程审阅及本轮限定一致性复核并冻结，仍为目标建议；未读取 Sources、Tests 或旧设计，未审计现有 App。
- 当前不修改 App 或配置，不访问真实接口／凭证，不运行构建；文档记录目标要求与未决项，后续遵守 S1—S6 顺序。
- 既有方案 C 仅是候选方案；AIUsage 是学习材料，均不直接决定最终视觉、交互或架构。
- 不把旧截图、旧能力描述或原型当作新行为已验证的证据，也不宣称“无 BUG”。

## 文档索引

以下文件名用于组织后续交付；标“待产出”的文件尚未由本轮创建，不能按链接存在与否推定阶段完成。
后续文件名称和必要拆分由主线程在对应阶段确认，阶段顺序不变。

| 文档 | 阶段与状态 | 职责 |
| --- | --- | --- |
| [README.md](README.md) | S1 已完成；随阶段维护 | 唯一索引、范围边界、阶段状态与出口 |
| [01-requirements-outline.md](01-requirements-outline.md) | S1 已产出，主线程审阅通过 | 产品定位、领域、稳定 FR/NFR、行为与验收路径大纲 |
| [02-technical-outline.md](02-technical-outline.md) | S1 已产出，主线程审阅通过 | 目标职责、数据契约、隔离、调度、验证与交付大纲 |
| [03-aiusage-reference.md](03-aiusage-reference.md) | S1 已产出，永久图片链接已补齐，主线程审阅通过 | 参考材料、可借鉴点及证据边界；不代替目标需求 |
| [04-global-requirements.md](04-global-requirements.md) | S2 初稿 v0.1 已完成主线程审阅及本轮限定一致性复核；目标建议 | FR 子项、可观察行为、优先级、错误恢复与接受条件 |
| [05-global-technical.md](05-global-technical.md) | S2 初稿 v0.1 已完成主线程审阅及本轮限定一致性复核；目标建议 | 契约、事件顺序、执行／调度、存储兼容与验证方法 |
| [06-ui-flows-and-acceptance.md](06-ui-flows-and-acceptance.md) | S2 初稿 v0.1 已完成主线程审阅及本轮限定一致性复核；目标建议 | 信息架构、原生点击链、草稿／窗口与分层证据矩阵 |
| 下表各独立双文档包 | S3，未开始，待产出 | 供应商或数据来源的证据、需求、技术及验收样本 |
| [07-preflight-consistency.md](07-preflight-consistency.md) | S4，未开始，待产出 | 需求→行为→契约→验证追溯及关键待核实阻断项 |
| [08-existing-app-audit.md](08-existing-app-audit.md) | S5，未开始，待产出 | 前置完备后对照现有 App，决定复用、修复或重写 |
| [09-delivery-verification.md](09-delivery-verification.md) | S6，未开始，待产出 | 实施、独立 review、原生交互、样本与安装包证据 |

独立双文档包均使用相同模板；以下是计划路径，全部“未开始，待产出”，不创建占位空文件。

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
| S2 全局详细规范 | 全局规范初稿已完成主线程审阅及本轮限定一致性复核；仍为目标建议，非用户已批准的实现方案 | 仅完成本轮全局文档收口；供应商证据、前置总审与程序验收均未完成 |
| S3 独立文档包 | 未开始 | 七包双文档完备，能力与机制具证据，字段及脱敏验收样例可追溯 |
| S4 前置一致性审查 | 未开始 | 需求到行为到验证可追溯，无关键未核实阻断；方可进入现有程序审计 |
| S5 现有 App 审计 | 未开始 | 对照目标规范形成差距与证据，主线程决定复用／修复／重写及实施范围 |
| S6 实施与交付 | 未开始 | 范围内已发现缺陷均已修复，尚未完成能力明确不发布；关键正常／异常／恢复路径、真实数据对照与最终安装包一致性验收通过 |

顺序约束：S2 全局详细定义先于 S3 逐家展开；S1—S4 前置工作完备后，才允许读取和审计现有产品源码。
未开始阶段不使用虚构百分比。阶段文档存在不等于出口已通过，必须核对内容与证据。

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

S2 三份全局规范初稿已完成主线程审阅及本轮限定一致性复核，冻结为目标建议，非用户已批准的实现方案。
S3—S6 仍未开始，本轮不自动推进供应商阶段；供应商证据与前置总审尚未完成，不代表所有前置工作完成。
尚未审计现有程序；实现、原生 UI 与安装包均未验证，本文不构成 App 通过结论。
