# HUD 与导航修复记录

日期：2026-10-30。修复提交及已安装 App 源版本为 `2d047ca`，分支 `feature/provider-manager-v2`；此前基线为 `3c214f3`。本文只记录本轮问题，不表示整个 App 无缺陷。

## 问题和修复

- **Claude HUD 空白**：旧测试的临时账号 `acc1` 可通过默认路径写入真实 Claude 设置，覆盖 `ACCOUNT_ENVS`。这条代码路径已确认，但没有现场日志证明具体哪次测试造成了用户那次故障。空 `envs.json` 本身不是内置供应商消失的原因。
- **避免再次误写**：引擎固定注入设置路径，测试使用临时目录及独立偏好；同步保留外部条目和旧备份，写入失败明确返回错误并尝试恢复。显式空账号列表不再回退显示旧单账号。诊断／截图不再先启动真实查询与定时调用。
- **调用计划、设置总进 Cline**：两项已改为独立全局页，不选择首账号。添加后可返回来源页，拒绝丢弃草稿时不改变页面／账号／tab；计划登记记录不会被写成调用成功。
- **状态与文件保护**：停用暂停后台查询和定时调用但保留偏好，恢复消费计划前确认；删除只清理本应用自有文件，外部凭证保留。

## 验证证据

完整日志与摘要：`/tmp/tokenhud-verification.IB6Jxw/`（临时审阅资料）。

| 检查 | 结果 |
| --- | --- |
| 生产构建 | 退出码 0（`build.log`） |
| 定向／全量回归 | 63 项／4 套件及 147 项／16 套件，退出码均为 0；全量默认跳过 opt-in 交互测试 |
| 隔离 HUD 输出 | 空 envs 下三个内置供应商正常显示；显式空列表不回退旧单账号（`node-results.json`） |
| 原生导航事件 | 实际视图内观察到 `overview→plan→settings→overview`，选中账号始终 `zeta`；末尾断言、窗口关闭、激活恢复、清理、函数返回与 defer 共 7 个标记齐全，退出码 0；仍缺 Swift Testing 正式完成尾标，**不称整项 UI 测试通过** |
| 截图 | 隔离演示数据产出 14 张；主线程已审总览、计划、设置及空账号页 |
| 配置保护 | 测试前后真实 settings／envs／凭证／备份内容哈希不变；缓存正常后台更新 |

最终冻结的 61 个源码／测试／脚本文件与验证哈希一致。生命周期修正后的交互测试文件已复编；部署准备阶段再次运行默认完整测试，正式得到 147 项／16 套件通过、退出码 0，真实 settings／envs／凭证／备份及 statusline 内容哈希无变化。日志：`/var/folders/_x/1lcyw8ss32sgds54r98dqmbw0000gn/T/tokenhud-deployment-zds7f_qu/full-suite-final.log`。构建仍有既有的冗余 `await`、未使用变量／返回值和恒真测试提示，不声称零警告。

## 安装与真实 HUD 核对

- 安装：`/Users/biedongbin/Applications/TokenHUD.app`，App 源版本 `2d047ca`，约 3.2 MB；打包退出码 0，安装版本与源提交一致，ad-hoc 签名校验通过。
- 运行：唯一进程 PID `92369`，二进制路径为上述安装包的 `Contents/MacOS/TokenHUD`；核查期间无新错误日志或崩溃报告。仓库、bundle 与部署 HUD 的 statusline／Cline 脚本哈希一致。
- 原选择保持：`ACCOUNT_ENVS` 仍为 Cline、CC-GLM、GPT；Ollama、OpenCode Go 仍停用。真实 settings／envs／凭证／旧备份内容哈希未变；没有执行同步修复 hook、开启账号或新增模型调用计划。
- 使用真实配置的 `statusLine.command` 一次，执行前各账号最近尝试均在 26 秒内，不需要后台补查；退出码 0、stderr 空，第二行有额度输出：Cline 5h **0%**／周 **68%**／月 **87%**，GLM 5h **1%**／周 **99%**，GPT 5h **17%**。这是命令输出链核实，不是 Claude 界面的截图；数值为核查时读数。
- 回滚副本：`/var/folders/_x/1lcyw8ss32sgds54r98dqmbw0000gn/T/tokenhud-deployment-zds7f_qu/rollback/`，含旧 App、settings、envs、statusline；目录 0700，配置副本 0600，未覆盖既有 `.bak`。部署日志和 JSON 同在其父目录。

## 限制

- 交互验证已收束为上述有限结果：实际按钮命中、绑定及末尾断言／清理均已观察，正式 Swift Testing 完成标记缺失，不将其写作完整 UI PASS。系统菜单栏和跨进程真实点击受 TCC 条件限制，未验。
- 固定 HUD 名称与缓存路径冲突时明确拒绝同步并保留原文件，**未交付完整多实例 HUD 支持**。
- 本文后续仅文档提交不会改变已安装 App 的源版本；不为文档更新重复打包。不推送、不合并到 `main`。
