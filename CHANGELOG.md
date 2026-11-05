# Changelog

Project changes are recorded here. No versioned GitHub Release has been published yet.
项目更新记录于此；当前尚未发布带版本号的 GitHub Release。

## Unreleased · 2026-11-05

### Added / 新增

- English and Simplified Chinese READMEs with the current app's core interfaces, including all four floating-panel styles.
  中英文 README 覆盖当前核心界面，包含全部四种悬浮窗样式。
- Two 27-second product demos with native GitHub video playback and downloadable MP4s.
  中英两段 27 秒演示视频，提供 GitHub 原生播放和 MP4 下载。
- A project-level MIT license and a shared changelog.
  项目级 MIT 许可证和统一更新日志。

### Changed / 调整

- Unified the application identity, preferences, and account directory under QuotaNest, with verified historical TokenHUD configuration migration and backups.
  应用身份、偏好与账号目录统一为 QuotaNest，历史 TokenHUD 配置迁移包含校验及备份。
- Refined floating-panel spacing, aligned list columns, added clear account separators, and removed separators from compact mode.
  优化悬浮窗留白和列表列对齐，清晰区分账号，紧凑模式不使用分隔线。
- Applied provider brand marks to account surfaces and provider-type cards, and compacted settings dropdowns.
  账号界面和供应商类型卡片采用品牌图标，设置下拉框改为紧凑宽度。

### Documentation / 文档

- Clarified the two core uses: floating-panel/Claude Code HUD quota display and scheduled attempts to start eligible dynamic 5h windows. QuotaNest complements existing gateways and reuses their configured credentials; it is not an API gateway.
  明确两项核心用途：悬浮窗／Claude Code HUD 额度展示，以及定时尝试启动适用供应商的动态 5h 窗口。QuotaNest 配合既有网关使用并复用其凭证，不承担 API 网关职责。
- Replaced development/media-reproduction and brand-reference README sections with Release notes, Acknowledgments, and License.
  README 删除开发／素材复现及品牌参考章节，改为更新日志、致谢和许可。
