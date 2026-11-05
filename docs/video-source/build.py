#!/usr/bin/env python3
"""Build and render QuotaNest's 27-second bilingual screenshot compositions."""

from __future__ import annotations

import argparse
import hashlib
import html
import json
import os
from pathlib import Path
import shutil
from string import Template
import subprocess

SOURCE = Path(__file__).resolve().parent
ROOT = SOURCE.parent.parent
OUTPUT = ROOT / "docs" / "videos"
ENV = {**os.environ, "HYPERFRAMES_SKIP_SKILLS": "1",
       "HYPERFRAMES_NO_TELEMETRY": "1", "DO_NOT_TRACK": "1"}
REVIEW_TIMES = "2,6.5,11.2,15.5,18.7,20.2,21.7,23.2,25.5"
HUD_NAMES = {"en": ["CARD", "GLASS", "COMPACT", "LIST"],
             "zh-CN": ["卡片", "玻璃", "紧凑", "列表"]}


def read_json(path: Path) -> dict:
    """Read a checked-in UTF-8 JSON object; fail on malformed input."""
    with path.open(encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError(f"Expected an object in {path.name}")
    return data


def repo_file(relative: str) -> Path:
    """Require source screenshots to exist inside the repository."""
    path = (ROOT / relative).resolve()
    if not path.is_relative_to(ROOT) or not path.is_file():
        raise ValueError(f"Missing or out-of-repository input: {relative}")
    return path


def hyperframes_cli(explicit: str | None) -> list[str]:
    """Prefer an explicit CLI, PATH, or a preexisting npm cache; never install."""
    if explicit:
        path = Path(explicit).expanduser().resolve(strict=True)
        return ["node", str(path)]
    installed = shutil.which("hyperframes")
    if installed:
        return [installed]
    cached = Path.home() / ".npm" / "_npx"
    for path in sorted(cached.glob("*/node_modules/hyperframes/bin/hyperframes.mjs")):
        metadata = read_json(path.parent.parent / "package.json")
        if metadata.get("version") == "0.8.207":
            return ["node", str(path)]
    raise FileNotFoundError("HyperFrames 0.8.207 unavailable. Set HYPERFRAMES_CLI.")


def run(command: list[str], cwd: Path) -> None:
    """Run a local media command with telemetry disabled and propagate failure."""
    subprocess.run(command, cwd=cwd, env=ENV, check=True)


def copy_asset(path: Path, assets: Path, name: str, records: list[dict],
               crop_height: int | None = None) -> str:
    """Copy public media, optionally crop unused bottom space, and record its hash."""
    destination = assets / (name + path.suffix.lower())
    record = {"source": path.relative_to(ROOT).as_posix(),
              "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
    if crop_height is None:
        shutil.copyfile(path, destination)
    else:
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(path),
                        "-vf", f"crop=1200:{crop_height}:0:0", "-frames:v", "1", "-update", "1",
                        str(destination)], check=True, capture_output=True, text=True)
        record["cropTopLeft"] = {"width": 1200, "height": crop_height}
    records.append(record)
    return "assets/" + destination.name


def scene_markup(index: int, scene: dict, picture: str) -> str:
    """Produce a scene with escaped editorial copy and a real screenshot."""
    escape = html.escape
    note = escape(scene.get("note", ""))
    return (f'<section id="s{index}" class="scene clip" '
            f'data-start="{scene["start"]}" data-duration="{scene["duration"]}" '
            f'data-track-index="0"><h1>{escape(scene["title"])}</h1>'
            f'<p class="subtitle">{escape(scene["subtitle"])}</p>'
            f'<div id="v{index}" class="visual">{picture}</div>'
            f'<p class="note">{note}</p><p class="label">{escape(scene["label"])}</p>'
            f'<p class="count">{index + 1:02d} / 06</p></section>')


def build_composition(language: str, storyboard: dict, inputs: dict) -> Path:
    """Build one independent HTML composition with local-only dependencies."""
    target = SOURCE / "build" / language
    assets = target / "assets"
    assets.mkdir(parents=True, exist_ok=True)
    (target / "vendor").mkdir(exist_ok=True)
    shutil.copyfile(SOURCE / "vendor" / "gsap.min.js", target / "vendor" / "gsap.min.js")
    records: list[dict] = []
    copy_asset(SOURCE / "app-icon.png", assets, "app-icon", records)
    copy = storyboard["languages"][language]
    scenes, tweens = [], []
    for index, scene in enumerate(copy["scenes"]):
        shot = scene["shot"]
        if shot == "hud":
            picture = hud_markup(language, inputs, assets, records, tweens, scene)
        else:
            source = repo_file(inputs[language][shot])
            crop_height = {"accounts": 700, "authentication": 620, "schedule": 550}.get(shot)
            image = copy_asset(source, assets, f"screen-{index}", records, crop_height)
            picture = f'<img class="screen" src="{image}" alt="{html.escape(shot)}">'
        scenes.append(scene_markup(index, scene, picture))
        start, duration = scene["start"], scene["duration"]
        tweens.append(f"tl.to('#s{index}', {{opacity:1,duration:0.24}}, {start});")
        tweens.append(f"tl.fromTo('#v{index}', {{y:10,scale:0.99}}, "
                      f"{{y:0,scale:1.015,duration:{duration - .25},ease:'power1.out',"
                      f"immediateRender:false}}, {start});")
        if index < len(copy["scenes"]) - 1:
            tweens.append(f"tl.to('#s{index}', {{opacity:0,duration:0.18}}, {start + duration - .18});")
    template = Template((SOURCE / "template.html").read_text(encoding="utf-8"))
    result = template.substitute(lang=language, brand=html.escape(copy["brand"]),
                                 fixture=html.escape(copy["fixtureLabel"]),
                                 scenes="\n".join(scenes), tweens="\n".join(tweens))
    (target / "index.html").write_text(result, encoding="utf-8")
    (target / "hyperframes.json").write_text('{}\n', encoding="utf-8")
    (target / "meta.json").write_text('{"name":"QuotaNest demo"}\n', encoding="utf-8")
    (target / "inputs.json").write_text(json.dumps(records, ensure_ascii=False, indent=2) + "\n",
                                        encoding="utf-8")
    return target


def hud_markup(language: str, inputs: dict, assets: Path, records: list[dict],
               tweens: list[str], scene: dict) -> str:
    """Keep all four real HUD styles visible; emphasize each for 1.5 seconds."""
    pictures = []
    for index, (relative, label) in enumerate(zip(inputs[language]["hud"], HUD_NAMES[language], strict=True)):
        image = copy_asset(repo_file(relative), assets, f"hud-{index}", records)
        pictures.append(f'<div class="hud-shot hud-{index}" id="hud{index}">'
                        f'<span class="hud-style">{label}</span><img src="{image}" alt="{label}"></div>')
        at = scene["start"] + index * 1.5
        tweens.append(f"tl.to('#hud{index}', {{opacity:1,duration:0.18}}, {at});")
        if index < 3:
            tweens.append(f"tl.to('#hud{index}', {{opacity:0.62,duration:0.16}}, {at + 1.34});")
    return '<div class="hud-grid">' + "".join(pictures) + '</div>'


def verify(video: Path) -> dict:
    """Check the actual exported stream, duration, frame rate, and upload size."""
    result = subprocess.run(["ffprobe", "-v", "error", "-show_format", "-show_streams",
                             "-of", "json", str(video)], check=True, capture_output=True, text=True)
    metadata = json.loads(result.stdout)
    stream = next(item for item in metadata["streams"] if item["codec_type"] == "video")
    duration = float(metadata["format"]["duration"])
    size = int(metadata["format"]["size"])
    numerator, denominator = map(int, stream["avg_frame_rate"].split("/"))
    assert 24 <= duration <= 29, f"Duration outside delivery range: {duration}"
    assert size < 15_000_000, f"Video exceeds 15 MB target: {size}"
    assert stream["codec_name"] == "h264", "Expected H.264"
    assert stream["pix_fmt"] == "yuv420p", "Expected yuv420p"
    assert (stream["width"], stream["height"]) == (1440, 900), "Unexpected resolution"
    assert numerator / denominator == 30, "Expected 30 fps"
    assert not any(item["codec_type"] == "audio" for item in metadata["streams"]), "Expected silent export"
    with video.open("rb") as handle:
        header = handle.read(1_000_000)
    assert 0 <= header.find(b"moov") < header.find(b"mdat"), "Expected faststart moov before mdat"
    return {"file": video.relative_to(ROOT).as_posix(), "duration": duration,
            "bytes": size, "codec": stream["codec_name"], "pixelFormat": stream["pix_fmt"],
            "width": stream["width"], "height": stream["height"], "fps": 30,
            "audio": "none", "faststart": True,
            "sha256": hashlib.sha256(video.read_bytes()).hexdigest()}


def render(language: str, target: Path, cli: list[str], snapshot: bool) -> dict:
    """Render with HyperFrames, then enforce a compatible faststart MP4."""
    OUTPUT.mkdir(exist_ok=True)
    if snapshot:
        run([*cli, "snapshot", "--at", REVIEW_TIMES, "--no-end", "-o", "review"], target)
    intermediate = target / "render.mp4"
    run([*cli, "render", "-o", str(intermediate), "--fps", "30", "--crf", "20",
         "--workers", "2", "--no-best-effort", "--strict", "--quiet"], target)
    video = OUTPUT / f"quotanest-demo-{language}.mp4"
    run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(intermediate),
         "-an", "-c:v", "libx264", "-preset", "medium", "-crf", "21", "-pix_fmt", "yuv420p",
         "-r", "30", "-movflags", "+faststart", str(video)], target)
    poster = OUTPUT / f"quotanest-demo-{language}-poster.png"
    run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-ss", "2", "-i", str(video),
         "-frames:v", "1", "-update", "1", str(poster)], target)
    review = target / "encoded-review"
    review.mkdir(exist_ok=True)
    for timestamp in REVIEW_TIMES.split(","):
        run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-ss", timestamp,
             "-i", str(video), "-frames:v", "1", "-update", "1", str(review / f"{timestamp}s.png")], target)
    report = verify(video)
    report["inputs"] = read_json(SOURCE / "screenshots.json")[language]
    report["inputHashes"] = json.loads((target / "inputs.json").read_text(encoding="utf-8"))
    return report


def main() -> None:
    """Build both language variants or render selected compositions."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lang", choices=["en", "zh-CN", "both"], default="both")
    parser.add_argument("--render", action="store_true")
    parser.add_argument("--snapshot", action="store_true")
    parser.add_argument("--hyperframes-cli", default=os.environ.get("HYPERFRAMES_CLI"))
    args = parser.parse_args()
    storyboard = read_json(SOURCE / "storyboard.json")
    inputs = read_json(SOURCE / "screenshots.json")
    languages = ["en", "zh-CN"] if args.lang == "both" else [args.lang]
    reports = []
    cli = hyperframes_cli(args.hyperframes_cli) if args.render or args.snapshot else []
    for language in languages:
        target = build_composition(language, storyboard, inputs)
        print(f"Built {language}: 27 seconds, 1440×900, 30 fps", flush=True)
        if args.render:
            reports.append(render(language, target, cli, args.snapshot))
        elif args.snapshot:
            run([*cli, "snapshot", "--at", REVIEW_TIMES, "--no-end", "-o", "review"], target)
    if reports:
        report = OUTPUT / "verification.json"
        report.write_text(json.dumps(reports, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(reports, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
