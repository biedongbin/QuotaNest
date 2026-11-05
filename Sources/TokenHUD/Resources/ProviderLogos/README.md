# Provider logos

This directory contains offline brand assets and the provenance for the 55 built-in provider manifests. `mapping.json` is the complete machine-readable map, including each source path, pinned commit, original-asset SHA-256, generated PNG SHA-256, license notices and mapping evidence.

## Rendering

- `logo:<basename>` loads `<basename>.png` as a color image. Preserve the source colors, alpha and aspect ratio; add no gradient, letter avatar or inferred brand.
- `logo-mono:<basename>` loads the same PNG format with `NSImage.isTemplate = true`. Its alpha is a mask; use appearance-aware system tint so a black source mark remains visible in dark mode.
- `network` is a neutral SF Symbol for unconfirmed brands and the two custom Auth/API Key types.
- Resolve a saved account's `template` (or built-in slug) to the built-in manifest icon. Older saved SF values need no config or identity migration. The shared `ProviderLogo` view renders the same identity throughout account navigation, overview, menu, floating panel and HUD settings.
- Runtime files are the PNGs in this directory. SVGs in `source-svg/` preserve source artwork and are not required to load at runtime. `source-raster/*-upstream.png` preserves original PNG bytes using different basenames, avoiding collisions if SwiftPM `.process` flattens subdirectories. This change does not alter package resource rules.

36 SVGs were rendered offline by `rsvg-convert 2.62.1` with `--width 512 --height 512 --keep-aspect-ratio`. Five local-distribution raster marks retain their original bytes and native sizes: Agnes Code 32×32, JoyCode 40×40, Raccoon 64×64, OfficeAce 128×128 and ZCode 128×128. These small source rasters may be less sharp at large sizes; no invented detail or upscaling was added to them. The two official-site raster marks are normalized with Pillow 12.3.0 LANCZOS to transparent 512×512 canvases: CatPaw's 110×108 original is uniformly scaled to 512×503 with 4/5px vertical padding, and Loomy's 1024×1024 original is downsampled to 512×512. Their source bytes are archived unchanged. MiMo's original 108:72 viewBox keeps its wide artwork inside a transparent 512×512 canvas, preserving its source aspect ratio.

`anthropic.png` is supplied for an explicitly Anthropic-owned API template as `logo-mono:anthropic`; `openai.png` is also available for an explicitly OpenAI-owned API template. Those API picker types are outside the 55 provider manifests. Compatibility protocol alone does not establish brand ownership. Custom types remain `network`.

## Complete template mapping

Rows group only templates sharing the same asset; all 55 template slugs appear below. The JSON contains the evidence for every individual mapping.

| Template slug(s) | Manifest icon | Basis |
| --- | --- | --- |
| agnes-code | `logo:agnes-code` | Product mark embedded in the matching upstream package metadata |
| aihubmix | `logo:aihubmix-color` | Matching vendor mark |
| antigravity | `logo:antigravity-color` | Product mark |
| autoclaw, autoclaw-cn | `logo:zhipu-color` | Confirmed Zhipu manufacturer mark; exact AutoClaw product mark unavailable locally |
| catpaw | `logo:catpaw` | Product icon referenced by the current official Meituan CatPaw homepage |
| claude-code | `logo:claudecode-color` | Claude Code product mark, distinct from Anthropic API |
| cline | `logo-mono:cline` | Product mark |
| cloudflare-workers-ai | `logo:workersai-color` | Workers AI product mark |
| codearts | `logo:huawei-color` | Confirmed Huawei manufacturer mark; exact CodeArts mark unavailable locally |
| codebuddy, codebuddy-cn | `logo:codebuddy-color` | Product mark shared across the vendor's regional editions |
| commandcode | `logo-mono:commandcode` | Product mark |
| cursor | `logo-mono:cursor` | Product mark |
| deepseek | `logo:deepseek-color` | Matching vendor mark |
| devin | `logo-mono:devin` | Product mark |
| factory | `logo-mono:factory` | Factory mark for Factory / Droid |
| gemini-cli | `logo:geminicli-color` | Gemini CLI product mark |
| github-copilot | `logo-mono:githubcopilot` | GitHub Copilot product mark |
| glm | `logo:chatglm-color` | ChatGLM family mark for GLM; distinct from Z.ai international |
| gpt | `logo-mono:openai` | OpenAI / ChatGPT vendor mark; Magpie's Codex subscription uses this same map |
| grok-cli | `logo-mono:grok` | Grok product mark |
| joycode | `logo:joycode` | Matching upstream package's product icon |
| kimi-code, kimi-code-cn | `logo-mono:kimi` | Kimi product mark |
| kiro | `logo:kiro-color` | Product mark |
| loomy | `logo:loomy` | Product icon referenced by the current official iFlytek Loomy homepage |
| minimax-code, minimax-code-cn, minimax-coding, minimax-coding-cn | `logo:minimax-color` | MiniMax brand family |
| moonshot, moonshot-cn | `logo-mono:moonshot` | Moonshot AI vendor mark; Kimi Code keeps the distinct Kimi mark |
| officeace | `logo:officeace` | Exact product icon; upstream explicitly describes its own .ico converted to PNG |
| ollama | `logo-mono:ollama` | Matching vendor mark |
| opencode-go, opencode-zen | `logo-mono:opencode` | OpenCode product family |
| openrouter | `logo-mono:openrouter` | Matching vendor mark |
| orcaterm | `logo:tencentcloud-color` | Confirmed Tencent Cloud vendor mark; exact OrcaTerm mark unavailable locally |
| qoder, qoder-cn | `logo-mono:qoder` | Qoder product mark |
| qwenwork, qwenwork-enterprise | `logo:qwen-color` | Qwen family mark; source explicitly identifies QwenWork as Alibaba's own service |
| raccoon | `logo:raccoon` | Product mark embedded in the matching upstream package metadata |
| stepfun, stepfun-cn | `logo:stepfun-color` | Matching vendor mark |
| trae, trae-cn | `logo-mono:trae` | Trae product mark |
| vercel-ai-gateway | `logo-mono:vercel` | Vercel vendor mark |
| workbuddy, workbuddy-cn | `logo:workbuddy-color` | WorkBuddy product mark |
| xiaomi-mimo-desktop | `logo-mono:mimocode` | Magpie's Xiaomi MiMo app subscription explicitly selects this mark |
| zai-coding | `logo-mono:zai` | Z.ai vendor mark |
| zcode-start | `logo:zcode` | ZCode product mark |
| zed | `logo-mono:zed` | Product mark |

## Coverage and product distinctions

All 55 built-in templates have an evidenced brand mapping: 31 color and 24 mono template references. There are no remaining neutral built-in templates; unknown/custom providers continue to use `network`. This is not a claim of 55 exact product marks.

- **CatPaw:** parent research supplied the current official homepage <https://catpaw.meituan.com/> and its referenced [PNG icon](https://s3plus.meituan.net/catpaw-external-resources/login/logo.png). The legacy homepage in the local plugin metadata is not the current asset source. Exact HTML icon-link evidence, page hash, original image hash and scaling details are archived in `source-records/catpaw-source.json`.
- **Loomy:** parent research supplied the current official homepage <https://loomy.xunfei.cn/> and its referenced [PNG icon](https://loomy.xunfei.cn/icon.png?5f7e7b8be5d4c76b). Exact HTML icon-link evidence, page hash, original image hash and scaling details are archived in `source-records/loomy-source.json`.
- **Manufacturer/family substitutions:** AutoClaw → Zhipu, CodeArts → Huawei, OrcaTerm → Tencent Cloud, QwenWork → Qwen, MiniMax Code → MiniMax, GLM → ChatGLM. These are explicitly classified in the mapping rather than described as exact product logos. AutoClaw's upstream circle plus the character “蟹” is a synthetic icon and was rejected.

## Monochrome evidence

All 20 `logo-mono:` assets have `fill="currentColor"` on the original SVG root and no fixed color paints or gradients: `anthropic`, `cline`, `commandcode`, `cursor`, `devin`, `factory`, `githubcopilot`, `grok`, `kimi`, `mimocode`, `moonshot`, `ollama`, `openai`, `opencode`, `openrouter`, `qoder`, `trae`, `vercel`, `zai`, `zed`. Each entry records this evidence in `mapping.json`. There are 19 mono assets used by the 55 manifests, plus the Anthropic API handoff asset.

Logos containing both black and color (for example Gemini CLI and Kiro), single fixed brand colors (Claude Code, Huawei, Workers AI), and color raster marks remain color images. They must not become template masks.

## Sources and rights

41 assets were taken from pinned local source checkouts. CatPaw and Loomy were supplied by the parent after official-site research and download; this asset task incorporated those local files without further network requests. No model calls or account/config access were used:

1. **Magpie**: <https://github.com/yetone/magpie/tree/0414bbeddbfc2028508b610fd1e7c194143454a0>, commit `0414bbeddbfc2028508b610fd1e7c194143454a0`. Original assets are under `internal/gui/assets/icons/`. The original MIT notice, **Copyright (c) 2026 yetone**, is reproduced unchanged in `LICENSE-Magpie.txt`.
2. **Upstream attribution**: [`internal/gui/assets/app.js:8440–8441`](https://github.com/yetone/magpie/blob/0414bbeddbfc2028508b610fd1e7c194143454a0/internal/gui/assets/app.js#L8440) attributes vendor/platform marks to **LobeHub Icons (`lobehub/icons`)**. This is the inspected distribution's statement. The exact LobeHub commit, its complete upstream attribution chain and individual official-site downloads were not established by the local metadata; no per-asset direct-official-site claim is made.
3. **Magpie community plugins**: <https://github.com/magpie-community/plugins/tree/3e24e228377ed17a9e5991c4e715dfde0244a1ea>, commit `3e24e228377ed17a9e5991c4e715dfde0244a1ea`. Agnes Code and Raccoon come from `magpie.icon` base64 PNGs in their matching package metadata; JoyCode comes from `packages/joycode/icon.png`; OfficeAce comes from `OFFICEACE_ICON` in `packages/codearts/index.mjs:3077`, whose preceding comment identifies OfficeAce's own .ico converted to PNG. Root MIT notice **Copyright (c) 2026 magpie-community contributors** is preserved in `LICENSE-Magpie-Plugins.txt`; package notices **Pursuit806**, **yuweihao17 / Sakura-Natsu**, and **kasisama** are preserved in `LICENSE-Agnes-Code.txt`, `LICENSE-CodeArts.txt`, and `LICENSE-JoyCode.txt` respectively.

4. **Official websites**: CatPaw and Loomy use the exact current official-homepage icon URLs listed above, fetched by the parent on 2026-11-05. Their original image bytes and source records are retained. No MIT license is asserted for these vendor website assets.

The repository MIT notices are distribution notices, not a representation that every vendor's trademark or logo artwork is licensed under MIT. Brand names, trademarks and logo artwork remain the rights of their respective vendors. Inclusion identifies a provider and does not imply endorsement. Source URLs in the mapping are provenance references, not runtime fetch instructions.

## Verification boundary

The asset checks cover all 55 icon mappings, exact preservation of every other manifest byte, all 43 PNG decodes and hashes, preservation of all 36 SVG / 7 PNG originals, mono paint evidence and active-content/external-reference rejection for SVG. The source SVGs use local fragment references for their original gradients/masks/filters only. Native verification covers bundle image decoding, old-account template resolution, theme-aware template flags, malformed asset names, Release compilation and isolated light/dark SwiftUI logo-grid captures. Verification does not query user accounts or call model APIs.
