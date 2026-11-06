# Changelog

English | [简体中文](CHANGELOG.zh-CN.md)

All notable changes are grouped by release version. Versions follow [Semantic Versioning](https://semver.org/). Changes not yet assigned to a release belong in `Unreleased`; released sections are retained under their version and date.

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

### Distribution

- Versioned macOS app packaging and an annotated `v1.0.0` tag.
- A universal ZIP for Apple Silicon and Intel, requiring macOS 14 or later, with published SHA-256 checksums.
- Homebrew cask installation through `biedongbin/tap/quotanest`, including the Node.js runtime used by quota adapters. Homebrew 7 users can approve only this cask with `brew trust --cask biedongbin/tap/quotanest` before the first install.
- Ad-hoc application signing; no Apple Developer ID signing or notarization is claimed. The cask removes quarantine only from the installed QuotaNest app.

[1.0.0]: https://github.com/biedongbin/QuotaNest/releases/tag/v1.0.0
