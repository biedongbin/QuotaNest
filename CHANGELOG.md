# Changelog

English | [简体中文](CHANGELOG.zh-CN.md)

All notable changes are grouped by release version. Versions use three numeric components with an optional fourth hotfix component. Changes not yet assigned to a release belong in `Unreleased`; released sections are retained under their version and date.

## Unreleased

## [1.0.0.1] — 2026-11-10

### Added

- Export an independent Claude Code HUD runtime explicitly; it reads source credentials and queries providers without the app running.
- Configure local call-plan models and times, with consistent model selection across editing, account health and execution.

### Fixed

- Isolate HUD quota snapshots by request workspace, read cc-switch composite identities correctly, and recover worker locks without deleting a successor's claim.
- Resume HUD queries after clock rollback and retain third-party HUD configuration fields during export.
- Persist pending-export indicators across app restarts, renaming and imports.
- Keep verification-model preferences separate from scheduled-call models, including accounts without a saved base model.
- Correct Z.ai Auth regression expectations and clarify Magpie inline Auth import support.


- Read imported source databases with bounded native SQLite queries instead of waiting for a subprocess on the main thread, preventing SwiftUI transaction reentrancy when opening the menu-bar popover.
- Detect the same GPT/Codex account and workspace across imported sources using declared identity evidence; skip duplicates without merging or deleting existing account settings.
- Select the correct ZCode Coding quota pool from its source login, and distinguish a missing Start subscription from an authentication or parser failure.
- Match native Antigravity query headers and source formats; read Cline prepaid credit separately when no ClinePass subscription exists.
- Cap effective background quota intervals at five minutes and retry failed quota queries twice, preserving correctly bound stale values and original success timestamps. Model calls are not automatically retried.
- Keep successful quota snapshots visually current for two effective query cycles (two minutes at a one-minute interval, ten minutes at five minutes); query failures mark values old immediately. Show per-account refresh progress while preserving the previous snapshot and visible errors.
- Publish each account's quota result as soon as it completes, so fast accounts no longer wait for slower queries.
- Clarify that imported-account removal only affects QuotaNest-owned links, settings, cache, and HUD entries; external source accounts and credentials are preserved.
- Filter the sidebar and overview by local creation or import source, combined with search and account status.

## [1.0.0] — 2026-11-06

Refreshed 1.0.0 release; replaces the original 2026-11-05 assets and tag.

### Core features

- Show AI account quotas, balances, usage windows, and reset times in four floating-panel styles and Claude Code HUD.
- Schedule small API requests to attempt to start eligible providers' first-use-based dynamic 5h windows. Provider behavior is not guaranteed, and requests can consume quota.
- Reuse supported credentials and API Keys already configured in Magpie, CPAMP, 9router, and cc-switch through read-only source references. QuotaNest is a companion app, not an API gateway or request router.

### Added

- Native launch-at-login control backed by the actual macOS Login Items state.
- Safe self-service feedback in provider selection and import windows: local allowlisted diagnostics, reviewed gh submission, and copy/browser fallbacks. Claude is not required or invoked.
- A user-triggered GitHub Star button above Settings & Appearance, using local gh with a project-page fallback.
- 55 provider types, with separate quota-query and model-call capabilities, Auth/API Key modes, and declared credential inheritance.
- Per-account schedules, quota visibility, independent cached states, and hourly source-reference synchronization while the app runs.
- English and Simplified Chinese UI, official provider brand mapping, compact settings controls, and linked HUD visibility preferences.
- Verified migration of previous TokenHUD account files and preferences, with an original-data backup and failure rollback.
- Bilingual README guides, core-interface screenshots, and two 27-second demonstration videos.

### Fixed

- Imported accounts can change their local display name without changing source identity, credentials, or other manifest fields.
- Callable imported accounts can choose a temporary model and confirm one API test without saving model or schedule changes. Model-list reuse revalidates the current source connection; quota-only types remain clearly identified.
- Recognize Magpie native Codex Auth snapshots by their stable record ID instead of rejecting all native logins. Keep routing switches separate from quota-monitor enabled state.
- Import ZCode Start from the exact plugin slot using its nested JWT and device context; never send the Coding plan Key to the Start endpoint. Imported account identity remains pinned and credentials are not copied.

### Distribution

- Versioned macOS app packaging and an annotated `v1.0.0` tag.
- A universal ZIP for Apple Silicon and Intel, requiring macOS 14 or later, with published SHA-256 checksums.
- Homebrew cask installation through `biedongbin/tap/quotanest`, including the Node.js runtime used by quota adapters. Homebrew 7 users can approve only this cask with `brew trust --cask biedongbin/tap/quotanest` before the first install.
- Ad-hoc application signing; no Apple Developer ID signing or notarization is claimed. The cask removes quarantine only from the installed QuotaNest app.

[1.0.0.1]: https://github.com/biedongbin/QuotaNest/releases/tag/v1.0.0.1
[1.0.0]: https://github.com/biedongbin/QuotaNest/releases/tag/v1.0.0
