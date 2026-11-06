<p align="center">
  <img src="assets/branding/QuotaNest.png" width="112" alt="QuotaNest app icon" />
</p>
<h1 align="center">QuotaNest</h1>
<p align="center">Floating quotas, Claude Code HUD, and dynamic 5h-window schedules — alongside your existing AI tools.</p>
<p align="center">
  <a href="README.zh-CN.md"><img src="https://img.shields.io/badge/简体中文-阅读中文版-red?style=for-the-badge" alt="简体中文" /></a>
</p>
<p align="center">
  <a href="https://github.com/biedongbin/QuotaNest/releases/tag/v1.0.0"><img src="https://img.shields.io/badge/version-1.0.0-blue?style=flat-square" alt="Version 1.0.0" /></a>
  <img src="https://img.shields.io/badge/platform-macOS_14+-lightgrey?style=flat-square" alt="macOS 14 or later" />
  <img src="https://img.shields.io/badge/built_with-SwiftUI-orange?style=flat-square" alt="Built with SwiftUI" />
  <img src="https://img.shields.io/badge/provider_types-55-blue?style=flat-square" alt="55 built-in provider types" />
  <img src="https://img.shields.io/badge/languages-English_/_简体中文-green?style=flat-square" alt="English and Simplified Chinese" />
</p>

> A native macOS companion focused on two jobs: displaying quotas in floating panels and Claude Code HUD, and scheduling small requests to attempt to start eligible providers' dynamic 5h windows.

## The 10-second pitch

1. **Keep quotas visible.** See existing accounts' allowances, usage, and reset times in a floating panel or Claude Code HUD without reopening provider dashboards.
2. **Schedule the start of dynamic 5h windows.** For providers whose windows start with the first qualifying request, schedule small calls at chosen times to try to start the next window and align its timing with your working day. Results depend on provider rules: calls do not force a reset, do not guarantee opening a window, and may consume quota.

**QuotaNest is not an API gateway. It does not proxy, route, or load-balance your application requests.** It works alongside existing AI gateways and account-management tools such as Magpie, CPAMP, 9router, and cc-switch, adding quota visibility and scheduled calls.

**Reuse credentials and API Keys you have already configured.** For supported source tools and credential formats, imports store read-only source references, so you do not have to re-enter credentials or keep another persistent copy in QuotaNest. Subsequent requests resolve the current authentication from the source configuration. Your existing tools continue to own the connection and credentials; QuotaNest adds floating panels, Claude Code HUD output, and scheduled requests.

![QuotaNest account overview](docs/screenshots/en/overview.png)

## Demo video · 27 seconds

https://github.com/user-attachments/assets/fc02bbbb-19f0-4373-a21b-ed4076c4e8b5

[Watch / download the English MP4](docs/videos/quotanest-demo-en.mp4) · [中文版视频](docs/videos/quotanest-demo-zh-CN.mp4)

The demos use the current native app with isolated sample accounts and illustrative quota values. They do not send paid model requests. Video production follows the screenshot → GSAP → HyperFrames approach used by [CCS](https://github.com/biedongbin/claude-code-session-manager); reproducible sources and the verified toolchain are in [docs/video-source](docs/video-source/README.md).

## What you get

| Capability | What it does |
| --- | --- |
| Four floating layouts | Card, glass, compact, and list; drag from anywhere. The title appears on click and hides five seconds after the pointer leaves. |
| Claude Code HUD | Choose displayed accounts in settings or the account display page; both controls share the same preference. |
| Small scheduled calls | Configure local-time requests for eligible plans with dynamic usage windows. Calls consume quota and cannot guarantee opening or resetting a window. |
| Read-only imports | Reference existing records from 9router, cc-switch, CPAMP, or Magpie, preserving original record and provider IDs. |
| Multi-account overview | View quota windows, balances, reset times, old data, and configuration health without opening each provider site. |
| 55 built-in types | 22 types declare quota queries and model calls; 33 currently support quota queries only. See the [provider catalog](docs/provider-catalog.md). |
| Auth or API Key | Use the authentication modes declared by each provider. Quota queries inherit the same base authentication. |
| Source synchronization | Check imported references hourly while the app runs, or sync now. Correct changed record IDs only when the identity is uniquely established. |
| English / 中文 | Change the interface language immediately in Settings & Appearance. The app follows the macOS light/dark appearance. |
| History migration | Automatically migrate the former TokenHUD account directory and preferences to QuotaNest with verification, backup, and rollback. |

## Install

**Homebrew (recommended):**

```zsh
brew install --cask biedongbin/tap/quotanest
```

Homebrew 7+ requires approval for a new third-party cask. If it reports an untrusted tap, trust only this cask and retry:

```zsh
brew trust --cask biedongbin/tap/quotanest
brew install --cask biedongbin/tap/quotanest
```

The cask supports **Apple Silicon and Intel on macOS 14+** and installs Node.js for the quota adapters. It removes the quarantine attribute only from the installed QuotaNest app, matching the [CpampBar](https://github.com/biedongbin/cpamp-start-bar) installation approach. The app is ad-hoc signed, without Apple Developer ID signing or notarization.

For later releases, use `brew upgrade --cask quotanest`. You can pass `--appdir="$HOME/Applications"` to keep applications in your home directory; quit and remove an older manually installed app bundle before taking it over with Homebrew. Account data is stored separately.

**Manual download:** get [QuotaNest-1.0.0-universal.zip](https://github.com/biedongbin/QuotaNest/releases/download/v1.0.0/QuotaNest-1.0.0-universal.zip) from [Release v1.0.0](https://github.com/biedongbin/QuotaNest/releases/tag/v1.0.0), verify it against `SHA256SUMS`, unzip it, and move `QuotaNest.app` to Applications. macOS may require approval in **System Settings → Privacy & Security** on first launch.

### Build from source

Requirements: **macOS 14+**, the **Swiftly-managed Swift toolchain**, and **Node.js** for the bundled JavaScript quota adapters. Node.js 18+ is recommended.

```zsh
git clone https://github.com/biedongbin/QuotaNest.git
cd QuotaNest
export PATH="$HOME/.swiftly/bin:$PATH"
zsh scripts/package.sh
open ~/Applications/QuotaNest.app
```

Quit a running copy before packaging. The script builds a local app, includes its icon and resources, applies an ad-hoc signature, and installs it in `~/Applications`. This is a local build workflow; a notarized download is not assumed.

The system Command Line Tools Swift version can be incompatible with this package's manifest ABI. Use `swiftly run swift …` rather than switching toolchains mid-build.

## Interface tour

Screenshots show isolated demo data, not personal credentials or live service validation. Provider-returned text and user-defined account names remain unchanged when switching languages.

### 1. Choose a provider type

Search built-in types and inspect their authentication and quota/call capabilities before creating an account. Choosing a type opens a draft; it does not immediately create an account.

![Provider catalog with official brand marks](docs/screenshots/en/provider-catalog.png)

### 2. Connect with an API Key or an existing Auth file

Each provider determines which modes are supported. Auth references declared JSON credential layouts; API Key accounts use their configured base connection. Quota queries reuse that authentication instead of asking for a separate query key.

| API Key connection | Existing Auth file |
| --- | --- |
| ![API Key connection](docs/screenshots/en/connection-api-key.png) | ![Read-only Auth connection](docs/screenshots/en/authentication.png) |

<details>
<summary>Account editor and API-only account</summary>

![Account editor](docs/screenshots/en/account-editor.png)

![API-only account](docs/screenshots/en/api-only.png)

</details>

### 3. Inspect quota and schedule requests

Quota details keep the billing windows and account identity separate. Missing values stay unknown; a failed request is not presented as a successful refresh.

![Quota detail](docs/screenshots/en/quota.png)

For supported types, select a model that belongs to the intended plan or quota pool, then configure local-time calls. A small request can **attempt** to start a first-use window when the provider supports that behavior. It is not a reset command, and every request may consume quota.

![Account API schedule](docs/screenshots/en/schedule.png)

<details>
<summary>All schedules</summary>

![Schedule overview](docs/screenshots/en/schedules.png)

</details>

### 4. Import existing accounts

Import previews show the source tool, provider identity, source record ID, authentication mode, quota adaptation, and import status. Unsupported or unadapted rows are disabled; the column header stays visible while scrolling.

![Read-only import preview and source sync](docs/screenshots/en/import.png)

| Source | Current boundary |
| --- | --- |
| 9router | References `providerConnections` records by original primary key and provider identity; the authentication layout must be adapted. |
| cc-switch | Currently supports the Claude namespace, identified by `id + app_type`. Other namespaces are shown as unsupported. |
| CPAMP | References supported CPA JSON authorization files by filename and type. |
| Magpie | Supports adapted provider keys and plugin credential slots; preserves original provider IDs and supports an explicit portable configuration directory. Native CLI/Keychain-owned logins are not imported. |

Imported connection fields are read-only. Maintain credentials in the source tool; local monitoring, visibility, quota queries, and removing the association remain available. Deleting the association does not delete the source.

Automatic synchronization runs hourly **while QuotaNest is running**. A source record ID is corrected only with a unique, compatible identity match. Ambiguous records, missing evidence, or simultaneous ID/token changes without a trustworthy relationship need manual review. Source checks do not make model calls.

### 5. Keep quotas visible — all four floating styles

All layouts share the same account data and official provider brand mapping. Color marks retain their colors; monochrome marks adapt to appearance.

| Card | Glass |
| --- | --- |
| ![Card floating panel](docs/screenshots/en/floating-card.png) | ![Glass floating panel in macOS dark appearance](docs/screenshots/en/floating-glass.png) |

| Compact | List |
| --- | --- |
| ![Compact floating panel](docs/screenshots/en/floating-compact.png) | ![List floating panel](docs/screenshots/en/floating-list.png) |

- **Card:** side-by-side quota windows in an account card.
- **Glass:** the highest-used window takes priority, with the remaining periods below.
- **Compact:** narrow rows with a small gap and no separator lines.
- **List:** aligned account, period, progress, and value columns with account separators.

Click the menu-bar item for the overview, double-click it to toggle the floating panel, or right-click for actions. Drag anywhere on the floating panel. Its title starts hidden, appears when clicked, and hides five seconds after the pointer leaves; returning cancels that timer. Appearance follows macOS — there is no separate in-app theme switch.

<details>
<summary>Menu-bar overview</summary>

![Menu-bar overview](docs/screenshots/en/menu.png)

</details>

### 6. Select Claude Code HUD accounts and adjust preferences

Use **Settings & Appearance → Claude Code HUD** to select accounts horizontally with automatic wrapping. The account's **Display** page uses the same state. Changes sync immediately; a failed HUD write restores the previous selection. Disabled accounts retain their preference for when they are enabled again.

![Language, compact pickers, and HUD selection](docs/screenshots/en/settings.png)

![Per-account display controls](docs/screenshots/en/account-display.png)

The following is a user-supplied Claude Code HUD example. Its project-directory line was removed before publication; the Chinese usage labels are retained as provided.

![Claude Code HUD output example](docs/screenshots/claude-code-hud.png)

## Feedback

Use **Report a Problem / Request Support** in the provider catalog, or **Report Import Problem** in the import window. Enter a description, preview the complete safe diagnostic draft, and explicitly confirm public submission.

**Claude is optional.** Without it, the app still generates the draft locally. With an authenticated `gh`, submit directly; without `gh` or a usable login, copy the draft or complete submission in your browser. Nothing is installed automatically.

This version generates diagnostics entirely in the app and does not invoke Claude, even if it is installed. An isolated CLI prototype is kept in test-only code: its privacy checks pass, but the restricted runtime's DNS/TLS path is not verified, so it is not exposed as an app action. See the [feedback and privacy guide](docs/issue-feedback-proposal.md) for exact limits. The feedback feature is included in the refreshed **v1.0.0** download. If you installed the original 1.0.0, update the tap and run `brew reinstall --cask quotanest` to receive the replacement package.

The **Star on GitHub** button sits above Settings & Appearance in the sidebar. Clicking it uses the local authenticated `gh` to star QuotaNest; if the tool or login is unavailable, a project-page link is offered. No star is added automatically.

## Data, credentials, and migration

| Item | Location / behavior |
| --- | --- |
| Application | `~/Applications/QuotaNest.app` |
| Account manifests | `~/Library/Application Support/QuotaNest/providers/` |
| Preference domain | `local.quotanest` |
| Claude HUD integration | `~/.claude/hud/` and Claude's `settings.json`; `CLAUDE_CONFIG_DIR` is supported. |
| Previous TokenHUD data | Migrated before initializing language, account state, or background work. The original data is archived under `QuotaNest/MigrationBackups/`, with a migration report. |

Imported credentials are resolved from their source for the current request; persistent account settings store references. Manually configured API Keys are app-owned credentials and are stored with restrictive file permissions. External Auth files are not refreshed or overwritten.

Do not manually move source files to the app directory. Unsupported Keychain, encrypted, or unadapted credential formats do not become supported merely because they can be exported. The app does not provide a browser OAuth login flow.

## Custom quota endpoints

Custom accounts support **API Key authentication** with OpenAI-compatible or Anthropic-compatible model calls. Supply the complete quota URL; the default query is HTTP GET and inherits the base key. There is no independent quota key/cookie field and no guessed billing URL.

Standard quota JSON can include these fields, optionally wrapped in `data`:

```json
{
  "five_hour": { "used_percentage": 25, "resets_at": 1793462400 },
  "seven_day": { "used_percentage": 40 },
  "windows": [
    { "label": "Monthly", "amount": 12, "limit": 50, "unit": "USD" }
  ]
}
```

See the [provider catalog](docs/provider-catalog.md), [account/authentication contract](docs/account-management-rebuild.md), and [verification notes](docs/account-management-verification.md) for detailed boundaries. Built-in adaptation is not proof of live connectivity for every vendor or plan.

## Release notes

- **[Changelog](CHANGELOG.md)** — user-facing changes grouped by version.
- **[v1.0.0](https://github.com/biedongbin/QuotaNest/releases/tag/v1.0.0)** — current release and app downloads.

## Acknowledgments

- [Linux.do](https://linux.do) — community discussions and project sharing.
- [Magpie](https://github.com/yetone/magpie) — provider ecosystem and interface references.
- [CCS](https://github.com/biedongbin/claude-code-session-manager) — README structure and demo-video approach.
- [Claude Code](https://claude.com/claude-code) — Claude Code HUD integration.

## License

[MIT](LICENSE). Third-party assets retain their accompanying licenses and notices.
