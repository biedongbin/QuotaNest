# QuotaNest demo video source

Two silent, captioned product walkthroughs, each 27 seconds at 1440 × 900 and 30 fps. The pictures come from the current native QuotaNest app running with isolated demonstration accounts. Quota numbers are illustrative. The English and Simplified Chinese exports use screenshots and captions in their respective language.

## Rebuild

Prerequisites: Python 3.10+, Node.js 22+, FFmpeg/ffprobe, and HyperFrames 0.8.207 with its local Chrome runtime. No model API, login, voice service, music, or global plugin is used. GSAP 3.14.2 is included locally with its license header. The accepted app icon is converted from the repository's branding asset.

From the repository root:

```sh
python3 docs/video-source/build.py --render --snapshot
```

The builder finds an existing HyperFrames command on PATH or an existing npm cache containing version 0.8.207. It does not install dependencies. To use a specific local CLI:

```sh
HYPERFRAMES_CLI=/path/to/node_modules/hyperframes/bin/hyperframes.mjs \
  python3 docs/video-source/build.py --render --snapshot
```

Use `--lang en` or `--lang zh-CN` to rebuild one language. Omitting `--render` builds the editable composition only. `--snapshot` captures nine review moments. The generated HTML, copied inputs, SHA-256 input records, renderer metadata, intermediate MP4, and extracted encoded frames are kept in the ignored `build/<language>/` directory.

All HyperFrames subprocesses set `HYPERFRAMES_SKIP_SKILLS=1`, `HYPERFRAMES_NO_TELEMETRY=1`, and `DO_NOT_TRACK=1`. The composition loads only local images and the local animation library. No hosted fonts or remote assets are referenced.

## Editable inputs and exports

- `storyboard.json`: scene times and complete English/Chinese editorial copy.
- `screenshots.json`: repository-relative paths to the parent lane's real native UI screenshots; four HUD styles per language.
- `template.html`: local screenshot composition and paused GSAP timeline.
- `build.py`: HTML assembly, local HyperFrames render, FFmpeg encoding, poster/frame extraction, and actual-stream verification.
- `../videos/quotanest-demo-en.mp4` and `../videos/quotanest-demo-zh-CN.mp4`: final H.264, yuv420p, 30 fps, faststart MP4s, each under 15 MB.
- `../videos/quotanest-demo-en-poster.png` and `../videos/quotanest-demo-zh-CN-poster.png`: posters extracted from the actual encoded videos at 2 seconds.
- `../videos/verification.json`: actual ffprobe duration, bytes, codec, dimensions, frame rate, audio state, faststart check, output SHA-256, and input screenshot paths and SHA-256 hashes. The account overview, authentication, and schedule pictures are cropped only at the bottom to remove unused space; FFmpeg uses an explicit top-left crop and preserves the original navigation and content.

## Story and claim boundaries

| Time | Real UI subject | Caption focus |
| --- | --- | --- |
| 0–4.5s | Account manager | 55 provider types and account quotas |
| 4.5–9s | Account authentication | Auth / API Key; usage inherits the account's authentication |
| 9–13.5s | Source import | 9router, cc-switch, CPAMP, Magpie; read-only sources and hourly synchronization |
| 13.5–18s | Scheduled API calls | Attempts to start dynamic 5h windows; no guarantee a provider starts a window |
| 18–24s | Floating HUD | All four real styles remain visible in a montage; card, glass, compact, and list are each emphasized for 1.5 seconds |
| 24–27s | Account manager and brand | QuotaNest · 额度巢, macOS 14+, and the public repository `github.com/biedongbin/QuotaNest` |

These are animated screenshots with explanatory captions, not a continuous live interaction recording. The walkthrough does not claim real account connectivity, real balances, successful scheduled API calls, or verified window behavior. It contains no narration or third-party soundtrack.

## CCS provenance

This production follows the **final** locally verified CCS composition method. The historical CCS project was read only; it was not modified.

- The dated design `ccs/docs/superpowers/specs/2026-10-10-md-video-skill-design.md`, lines 13–31, documents the earlier `md-video` skill and its `am video` command, system `say` voices, headless Chrome capture, and FFmpeg export.
- The CCS-related Claude Code session confirms actual Bash executions of `node ~/.claude/skills/md-video/scripts/am.mjs video docs/video/ccs.zh.md --no-open --voice auto --mp4` on **2026-10-10**.
- The same scoped history confirms that the final method changed on **2026-10-20** to `python3 build.py`, `VIDEO_LANG=en python3 build.py`, and `HYPERFRAMES_SKIP_SKILLS=1 npx hyperframes render -o <output.mp4> --quiet`. No HyperFrames skill invocation was found; the final method used the CLI directly.
- `ccs/docs/video/hf-ccs/build.py`, lines 2–61 and 137–192, contains the real TUI screenshot composition, local GSAP library, paused timeline, and `window.__timelines` registration. Lines 267–311 implement the language variant.
- `ccs/docs/video/hf-ccs/package.json`, lines 12–15, records GSAP 3.14.2 and HyperFrames `^0.8.180`. `ccs/docs/video/hf-ccs/.hyperframes/video-state.json`, lines 995–1001, records a completed Chinese MP4 render. The current machine's preexisting cached CLI is HyperFrames 0.8.207.
- The actual CCS English and Chinese MP4s were probed locally: both are **30.000 seconds, 1920 × 1080, H.264 / yuv420p / 30 fps**, about 1.1 MB each. The final CCS method is silent; this production follows that choice.

The scoped CCS history also documents README embedding on **2026-10-27**: an already authenticated browser opened the repository's new-issue composer, Chrome DevTools `upload_file` attached each MP4 to the draft, and `evaluate_script` read the returned `github.com/user-attachments/assets/...` Markdown from the textarea. Later `evaluate_script` checked that a video element existed in the README. This lane did not upload files, publish an issue, access cookies, or perform a browser login. Repository MP4s and linked posters remain a complete delivery option.

The `md-video` skill and its video reference were read to establish this distinction. QuotaNest's final exports are built with HyperFrames and FFmpeg; they were not generated with `am video` or Remotion. Only CCS-related local sessions were searched. Raw conversation logs, private conversation text, credentials, and account records are not included in these source files.
