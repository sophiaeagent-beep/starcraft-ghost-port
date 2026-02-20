#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable


TEXT_EXTS = {
    ".txt",
    ".map",
    ".nui",
    ".nsc",
    ".nls",
    ".nlt",
    ".nlu",
    ".nlx",
    ".nfx",
    ".reslog",
    ".bat",
    ".scc",
}


def now_iso() -> str:
    return datetime.now(tz=timezone.utc).isoformat()


def sha256_file(path: Path, chunk_size: int = 1024 * 1024) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while True:
            chunk = f.read(chunk_size)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def run_cmd(cmd: list[str]) -> tuple[int, str]:
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    msg = proc.stderr.strip() or proc.stdout.strip()
    return proc.returncode, msg


def rel_sort(paths: Iterable[Path], root: Path) -> list[Path]:
    return sorted(paths, key=lambda p: p.relative_to(root).as_posix().lower())


def classify(ext: str) -> str:
    if ext in TEXT_EXTS:
        return "text"
    if ext in {".dds", ".tga", ".xpr", ".nsa"}:
        return "texture_or_material"
    if ext in {".nod", ".nad", ".nnb", ".nmb", ".noc", ".nms", ".xvu", ".npd"}:
        return "model_or_animation"
    if ext in {".xwb", ".xsb", ".wav", ".bin"}:
        return "audio"
    if ext in {".bik", ".vid"}:
        return "video"
    if ext in {".xpu", ".ps"}:
        return "shader"
    if ext in {".xbe", ".exe", ".pdb"}:
        return "executable_or_debug"
    if ext in {".nil", ".nsd", ".nco", ".nrt"}:
        return "level_or_sequence"
    return "other"


def decode_text(data: bytes) -> tuple[str, str]:
    encodings = ("utf-8", "utf-16le", "cp1252", "latin-1")
    for enc in encodings:
        try:
            text = data.decode(enc)
            return text, enc
        except UnicodeDecodeError:
            continue
    return data.decode("latin-1", errors="replace"), "latin-1-replace"


def ensure_parent(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Export StarCraft Ghost assets into a Godot/Unity-friendly staging layout."
    )
    parser.add_argument(
        "--source",
        type=Path,
        default=Path("/home/scott/Games/xemu/starcraft_ghost"),
        help="Source Ghost asset directory.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("/home/scott/Games/xemu/ghost_port/out/assets_export"),
        help="Output directory for manifests and converted assets.",
    )
    parser.add_argument("--hash", action="store_true", help="Compute sha256 for each source file.")
    parser.add_argument("--copy-raw", action="store_true", help="Copy source files into output/raw.")
    parser.add_argument("--convert-text", action="store_true", help="Export text-like files as UTF-8.")
    parser.add_argument("--convert-dds", action="store_true", help="Convert .dds to .png using ImageMagick.")
    parser.add_argument("--convert-bik", action="store_true", help="Convert .bik to .mp4 using ffmpeg.")
    parser.add_argument("--max-files", type=int, default=0, help="Process at most N files (0 = all).")
    parser.add_argument("--max-dds", type=int, default=64, help="Max .dds files to transcode.")
    parser.add_argument("--max-bik", type=int, default=24, help="Max .bik files to transcode.")
    parser.add_argument("--dry-run", action="store_true", help="Do not write converted/copy outputs.")
    args = parser.parse_args()

    source = args.source.resolve()
    output = args.output.resolve()

    if not source.exists():
        raise SystemExit(f"Source directory does not exist: {source}")
    if not source.is_dir():
        raise SystemExit(f"Source path is not a directory: {source}")

    magick = shutil.which("magick")
    ffmpeg = shutil.which("ffmpeg")

    files = rel_sort((p for p in source.rglob("*") if p.is_file()), source)
    if args.max_files > 0:
        files = files[: args.max_files]

    if not args.dry_run:
        (output / "manifests").mkdir(parents=True, exist_ok=True)
        (output / "converted").mkdir(parents=True, exist_ok=True)
        if args.copy_raw:
            (output / "raw").mkdir(parents=True, exist_ok=True)

    ext_counts: Counter[str] = Counter()
    category_counts: Counter[str] = Counter()
    dds_converted = 0
    bik_converted = 0

    assets: list[dict] = []
    conversions: list[dict] = []

    for src in files:
        rel = src.relative_to(source)
        rel_posix = rel.as_posix()
        ext = src.suffix.lower()
        cat = classify(ext)

        ext_counts[ext or "<noext>"] += 1
        category_counts[cat] += 1

        item = {
            "relative_path": rel_posix,
            "size_bytes": src.stat().st_size,
            "extension": ext,
            "category": cat,
        }
        if args.hash:
            item["sha256"] = sha256_file(src)

        if args.copy_raw:
            raw_dst = output / "raw" / rel
            item["raw_copy"] = raw_dst.as_posix()
            if not args.dry_run:
                ensure_parent(raw_dst)
                shutil.copy2(src, raw_dst)

        if args.convert_text and ext in TEXT_EXTS:
            text_dst = output / "converted" / "text" / rel
            if text_dst.suffix:
                text_dst = text_dst.with_suffix(text_dst.suffix + ".txt")
            else:
                text_dst = text_dst.with_suffix(".txt")
            conv = {
                "kind": "text_to_utf8",
                "source": rel_posix,
                "output": text_dst.relative_to(output).as_posix(),
                "status": "ok",
            }
            if not args.dry_run:
                data = src.read_bytes()
                text, encoding = decode_text(data)
                ensure_parent(text_dst)
                text_dst.write_text(text.replace("\r\n", "\n").replace("\r", "\n"), encoding="utf-8")
                conv["input_encoding"] = encoding
            conversions.append(conv)
            item.setdefault("converted_outputs", []).append(conv["output"])

        if args.convert_dds and ext == ".dds":
            if dds_converted >= args.max_dds:
                conversions.append(
                    {
                        "kind": "dds_to_png",
                        "source": rel_posix,
                        "status": "skipped",
                        "reason": "max_dds_reached",
                    }
                )
            elif not magick:
                conversions.append(
                    {
                        "kind": "dds_to_png",
                        "source": rel_posix,
                        "status": "skipped",
                        "reason": "magick_missing",
                    }
                )
            else:
                png_dst = output / "converted" / "textures_png" / rel.with_suffix(".png")
                conv = {
                    "kind": "dds_to_png",
                    "source": rel_posix,
                    "output": png_dst.relative_to(output).as_posix(),
                    "status": "ok",
                }
                if not args.dry_run:
                    ensure_parent(png_dst)
                    code, msg = run_cmd([magick, src.as_posix(), png_dst.as_posix()])
                    if code != 0:
                        conv["status"] = "error"
                        conv["error"] = msg
                    else:
                        dds_converted += 1
                        item.setdefault("converted_outputs", []).append(conv["output"])
                conversions.append(conv)

        if args.convert_bik and ext == ".bik":
            if bik_converted >= args.max_bik:
                conversions.append(
                    {
                        "kind": "bik_to_mp4",
                        "source": rel_posix,
                        "status": "skipped",
                        "reason": "max_bik_reached",
                    }
                )
            elif not ffmpeg:
                conversions.append(
                    {
                        "kind": "bik_to_mp4",
                        "source": rel_posix,
                        "status": "skipped",
                        "reason": "ffmpeg_missing",
                    }
                )
            else:
                mp4_dst = output / "converted" / "video_mp4" / rel.with_suffix(".mp4")
                conv = {
                    "kind": "bik_to_mp4",
                    "source": rel_posix,
                    "output": mp4_dst.relative_to(output).as_posix(),
                    "status": "ok",
                }
                if not args.dry_run:
                    ensure_parent(mp4_dst)
                    code, msg = run_cmd(
                        [
                            ffmpeg,
                            "-y",
                            "-v",
                            "error",
                            "-i",
                            src.as_posix(),
                            "-c:v",
                            "libx264",
                            "-preset",
                            "fast",
                            "-crf",
                            "23",
                            "-an",
                            mp4_dst.as_posix(),
                        ]
                    )
                    if code != 0:
                        conv["status"] = "error"
                        conv["error"] = msg
                    else:
                        bik_converted += 1
                        item.setdefault("converted_outputs", []).append(conv["output"])
                conversions.append(conv)

        assets.append(item)

    summary = {
        "created_utc": now_iso(),
        "source": source.as_posix(),
        "output": output.as_posix(),
        "file_count": len(assets),
        "extension_counts": dict(sorted(ext_counts.items())),
        "category_counts": dict(sorted(category_counts.items())),
        "conversion_counts": {
            "dds_converted": dds_converted,
            "bik_converted": bik_converted,
            "total_conversion_records": len(conversions),
        },
        "options": {
            "hash": args.hash,
            "copy_raw": args.copy_raw,
            "convert_text": args.convert_text,
            "convert_dds": args.convert_dds,
            "convert_bik": args.convert_bik,
            "max_files": args.max_files,
            "max_dds": args.max_dds,
            "max_bik": args.max_bik,
            "dry_run": args.dry_run,
            "tools": {"magick": bool(magick), "ffmpeg": bool(ffmpeg)},
        },
    }

    manifest = {"summary": summary, "assets": assets, "conversions": conversions}

    import_plan = {
        "target_engines": ["Godot 4.x", "Unity 2022+"],
        "notes": [
            "Model/animation formats (.nod/.nad/.nnb/.nmb) remain proprietary and need custom converters.",
            "UI/menu scripting files converted to UTF-8 can seed recreation of flow and mission scripting.",
            "DDS and BIK transcodes are for prototyping; original files should remain source-of-truth.",
        ],
        "next_steps": [
            "Write parsers for .nmb/.nod/.nad and emit glTF + animation clips.",
            "Write XWB/XSB extraction bridge to WAV/OGG for engine import.",
            "Map level logic from .nsd/.nil/.nco and mission chronicles (.nsc) into engine scenes.",
        ],
    }

    if not args.dry_run:
        manifests = output / "manifests"
        (manifests / "assets_manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
        (manifests / "extension_counts.json").write_text(
            json.dumps(dict(sorted(ext_counts.items())), indent=2), encoding="utf-8"
        )
        (manifests / "godot_unity_import_plan.json").write_text(
            json.dumps(import_plan, indent=2), encoding="utf-8"
        )

    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
