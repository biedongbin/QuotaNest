# 账号能力历史验收证据索引

从账号需求文档移出的历史测试数字。原记录未提供这些批次对应的提交 SHA 或完整执行日期，因此不能用它们证明 2026-11-10 工作区或 C v2 已通过。旧日志可能只存在于原开发环境；本文件不补造版本信息。

| 历史批次 | 原记录结果 | 日志 |
|---|---|---|
| Auth 路径清理 | 238 项 Swift、8 项 Node、独立启用的 4 项原生测试及 Release 构建通过 | [Swift](../.build/auth-path-cleanup-tests.log)、[Node](../.build/auth-path-cleanup-node.log)、[原生编辑](../.build/auth-path-native-editor.log)、[原生窗口](../.build/auth-path-native-window.log)、[Release](../.build/auth-path-cleanup-release.log) |
| 五家供应商认证增量 | 239 项 Swift、11 项 Node 及 Release 构建通过 | [Swift](../.build/all-supplier-auth-tests.log)、[Node](../.build/all-supplier-adapters.log)、[Release](../.build/all-supplier-release.log) |

Auth 路径批次的原生编辑测试曾找到可编辑输入控件、将新路径写入草稿并确认未保存到磁盘。系统 NSOpenPanel 已接线，但人工选择流程不据此视为通过。默认跳过项不算已验。

五家供应商批次使用离线适配器请求测试，验证指定快照、URL/Header 和不读取另一账号；没有真实凭证或模型请求。该批次的原生编辑测试没有完整汇总，不按退出码 0 算成功，也不沿用前一批 GUI 数字。

当前需求见[账号三层契约](account-management-rebuild.md)，最新问题及修复证据见[2026-11-10 审查报告](review-2026-11-10.md)。
