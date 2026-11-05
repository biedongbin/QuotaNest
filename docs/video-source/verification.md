# QuotaNest video verification

Verified locally on 2026-11-05. Both final exports passed the builder's strict media checks and a complete decoded-frame count.

| Export | Actual duration | File size | Video stream | Decoded frames | Faststart |
| --- | ---: | ---: | --- | ---: | --- |
| [English](../videos/quotanest-demo-en.mp4) | 27.000 s | 5,062,436 bytes | H.264, yuv420p, 1440 × 900, 30 fps | 810 | `moov` before `mdat` |
| [简体中文](../videos/quotanest-demo-zh-CN.mp4) | 27.000 s | 4,440,424 bytes | H.264, yuv420p, 1440 × 900, 30 fps | 810 | `moov` before `mdat` |

Both MP4s are below the 15 MB target and GitHub's 100 MB repository-file limit. They contain no audio stream. The [English poster](../videos/quotanest-demo-en-poster.png) and [Chinese poster](../videos/quotanest-demo-zh-CN-poster.png) are actual encoded frames at 2 seconds, each 1440 × 900.

## Checks executed

```sh
python3 -m py_compile docs/video-source/build.py
ruff check docs/video-source/build.py
python3 docs/video-source/build.py --render --snapshot
ffprobe -v error -count_frames -select_streams v:0 \
  -show_entries stream=nb_read_frames,r_frame_rate -of json \
  docs/videos/quotanest-demo-en.mp4
ffprobe -v error -count_frames -select_streams v:0 \
  -show_entries stream=nb_read_frames,r_frame_rate -of json \
  docs/videos/quotanest-demo-zh-CN.mp4
```

All commands completed with exit code 0. Ruff reported `All checks passed!`. The builder checked actual ffprobe output for duration, file size, codec, pixel format, resolution, frame rate, and absence of audio, and inspected MP4 atom order for faststart. The independent frame-count probes decoded 810 frames for each MP4 without a reported decoding error. All recorded input SHA-256 values were compared with the frozen screenshot files after export and matched, including the refreshed import screenshots.

The machine-readable [verification record](../videos/verification.json) contains each output hash and its exact input paths/hashes, including top-left crop dimensions. The [builder](build.py), [storyboard](storyboard.json), [input list](screenshots.json), and [local template](template.html) reproduce the result.

## Visual review

The builder captured nine composition snapshots and extracted nine actual encoded frames per language at **2, 6.5, 11.2, 15.5, 18.7, 20.2, 21.7, 23.2, and 25.5 seconds**. The two composition contact sheets were inspected. For the final encoded videos, one frame for every scene in each language was inspected with the image tool: 2, 6.5, 11.2, 15.5, 23.2, and 25.5 seconds for English; 2, 6.5, 11.2, 15.5, 21.7, and 25.5 seconds for Chinese.

Observed results:

- Native UI occupies the main picture throughout. English and Chinese account names and interface copy use their corresponding frozen native screenshots.
- The overview, authentication, and schedule pictures retain their original top navigation; only unused bottom space is cropped.
- The refreshed import scene shows Cline as API Key with an adapted quota adapter and a compatible import status.
- The schedule scene and editorial note say that calls **attempt** to start a dynamic 5h window and that opening one is not guaranteed.
- All four real floating styles remain visible for the complete 18–24 second montage. Card, glass, compact, and list each receive 1.5 seconds of emphasis.
- The final frame contains the accepted QuotaNest branding and `github.com/biedongbin/QuotaNest`.
- Only demonstration accounts, illustrative quotas, `example.invalid`, and public `/tmp/quotanest-demo...` fixture paths appear. No user account, API key, private home directory, browser state, or raw conversation log is included.
- No caption claims an App theme switch. The dark presentation background is video styling; native screenshots retain their actual system appearance.

## Limits

This is a silent animated screenshot walkthrough, not a continuous interaction recording. It demonstrates the current UI with isolated sample data. It does not verify real provider connectivity, real quota balances, actual API calls, window opening, source synchronization over time, or legacy data migration. UI text within small panes is most legible when the video is opened at its native size. GitHub publication and attachment-CDN upload are handled by the parent lane and were not performed here.
