#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import shutil
import struct
import subprocess
import wave
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path


def now_iso() -> str:
    return datetime.now(tz=timezone.utc).isoformat()


def printable_strings(data: bytes, min_len: int = 4, max_items: int = 2000) -> list[str]:
    out: list[str] = []
    buf: list[int] = []
    for b in data:
        if 32 <= b <= 126:
            buf.append(b)
            continue
        if len(buf) >= min_len:
            out.append(bytes(buf).decode("ascii", errors="ignore"))
            if len(out) >= max_items:
                return out
        buf = []
    if len(buf) >= min_len and len(out) < max_items:
        out.append(bytes(buf).decode("ascii", errors="ignore"))
    return out


def parse_xsb_cues(path: Path) -> list[str]:
    data = path.read_bytes()
    strings = printable_strings(data, min_len=4, max_items=8000)
    cue_re = re.compile(r"^[A-Za-z][A-Za-z0-9_]{2,63}$")
    skip = {"SDBK", "XACT", "WAVE", "CUES", "menu", "global"}
    cues: list[str] = []
    seen: set[str] = set()
    for s in strings:
        if not cue_re.match(s):
            continue
        if s in skip:
            continue
        if s in seen:
            continue
        seen.add(s)
        cues.append(s)
    return cues


def parse_xwb(path: Path) -> dict:
    data = path.read_bytes()
    if len(data) < 48 or data[0:4] != b"WBND":
        raise ValueError(f"Not a WBND wave bank: {path}")

    # Ghost dump banks use a 4-segment header.
    seg = struct.unpack_from("<8I", data, 0x08)
    seg_bank_off, seg_bank_len, seg_meta_off, seg_meta_len, seg_seek_off, seg_seek_len, seg_wave_off, seg_wave_len = seg

    if not (0 <= seg_bank_off < len(data)):
        raise ValueError(f"Invalid bank segment in {path}")
    if not (0 <= seg_meta_off <= len(data)):
        raise ValueError(f"Invalid metadata segment in {path}")
    if not (0 <= seg_wave_off <= len(data)):
        raise ValueError(f"Invalid wave segment in {path}")

    flags, entry_count = struct.unpack_from("<II", data, seg_bank_off)
    bank_name_raw = data[seg_bank_off + 8 : seg_bank_off + 72]
    bank_name = bank_name_raw.split(b"\0", 1)[0].decode("ascii", errors="ignore") or path.stem

    entry_size = 0
    if entry_count > 0 and seg_meta_len > 0:
        entry_size = seg_meta_len // entry_count

    entries: list[dict] = []
    for i in range(entry_count):
        if entry_size <= 0:
            break
        off = seg_meta_off + i * entry_size
        if off + 24 > len(data):
            break
        fd, fmt, play_off, play_len, loop_start, loop_len = struct.unpack_from("<6I", data, off)
        tag = fmt & 0x3
        channels_field = (fmt >> 2) & 0x7
        channels = max(1, channels_field)
        sample_rate = (fmt >> 5) & 0x3FFFF
        block_align_field = (fmt >> 23) & 0xFF
        bit_flag = (fmt >> 31) & 0x1
        bits_per_sample_guess = 16 if bit_flag else 8

        abs_start = seg_wave_off + play_off
        abs_end = abs_start + play_len
        if abs_start > len(data):
            blob = b""
        else:
            blob = data[abs_start : min(abs_end, len(data))]

        entries.append(
            {
                "index": i,
                "flags_duration": fd,
                "format_raw": fmt,
                "tag": tag,
                "channels": channels,
                "sample_rate": sample_rate,
                "block_align_field": block_align_field,
                "bits_per_sample_guess": bits_per_sample_guess,
                "play_offset": play_off,
                "play_length": play_len,
                "loop_start": loop_start,
                "loop_length": loop_len,
                "raw_blob": blob,
            }
        )

    return {
        "bank_file": path,
        "bank_name": bank_name,
        "flags": flags,
        "entry_count_header": entry_count,
        "entry_size": entry_size,
        "segments": {
            "bank_data": {"offset": seg_bank_off, "length": seg_bank_len},
            "entry_meta": {"offset": seg_meta_off, "length": seg_meta_len},
            "seek_table": {"offset": seg_seek_off, "length": seg_seek_len},
            "wave_data": {"offset": seg_wave_off, "length": seg_wave_len},
        },
        "entries": entries,
    }


def write_pcm_wav(path: Path, pcm_bytes: bytes, channels: int, sample_rate: int, bits: int) -> None:
    sampwidth = 2 if bits >= 16 else 1
    frame_size = channels * sampwidth
    if frame_size <= 0:
        return
    aligned = pcm_bytes[: len(pcm_bytes) - (len(pcm_bytes) % frame_size)]
    with wave.open(str(path), "wb") as w:
        w.setnchannels(channels)
        w.setsampwidth(sampwidth)
        w.setframerate(max(1, sample_rate))
        w.writeframes(aligned)


def sanitize_name(s: str) -> str:
    out = re.sub(r"[^A-Za-z0-9._-]+", "_", s).strip("._")
    return out or "item"


def resolve_vgmstream_bin(user_value: str) -> str:
    value = (user_value or "").strip()
    if value:
        p = Path(value)
        if p.exists() and p.is_file():
            return p.as_posix()

    found = shutil.which("vgmstream-cli")
    if found:
        return found

    script_dir = Path(__file__).resolve().parent
    repo_root = script_dir.parent
    local_candidates = [
        repo_root / "tools" / "vgmstream-cli",
        Path("/tmp/vgmstream/build/cli/vgmstream-cli"),
    ]
    for candidate in local_candidates:
        if candidate.exists() and candidate.is_file():
            return candidate.as_posix()

    return ""


def run_vgmstream_bank(vgmstream_bin: str, xwb: Path, out_dir: Path) -> dict:
    out_dir.mkdir(parents=True, exist_ok=True)
    for stale in out_dir.glob("*.wav"):
        stale.unlink()
    pattern = (out_dir / "?s.wav").as_posix()
    cmd = [vgmstream_bin, "-S", "0", "-o", pattern, xwb.as_posix()]
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    wavs = sorted(out_dir.glob("*.wav"))
    return {
        "cmd": cmd,
        "returncode": proc.returncode,
        "stdout_tail": (proc.stdout or "").strip().splitlines()[-20:],
        "stderr_tail": (proc.stderr or "").strip().splitlines()[-20:],
        "wav_count": len(wavs),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Extract Ghost XWB banks into raw chunks + PCM WAV; optional vgmstream decode.")
    parser.add_argument(
        "--sounds-dir",
        type=Path,
        default=Path("/home/scott/Games/xemu/starcraft_ghost/Sounds"),
        help="Sounds directory containing .xwb/.xsb files.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("/home/scott/Games/xemu/ghost_port/out/audio_bridge"),
        help="Output directory for manifests and extracted blobs.",
    )
    parser.add_argument("--max-banks", type=int, default=0, help="Limit number of banks (0 = all).")
    parser.add_argument("--max-entries", type=int, default=0, help="Limit entries per bank (0 = all).")
    parser.add_argument("--extract-raw", action="store_true", help="Write raw chunks for every entry.")
    parser.add_argument(
        "--decode-pcm",
        action="store_true",
        help="Decode entries with tag 0 as PCM WAV using inferred channels/rate/bits.",
    )
    parser.add_argument(
        "--decode-vgmstream",
        action="store_true",
        help="Run vgmstream-cli on each XWB and export WAVs (if tool is available).",
    )
    parser.add_argument(
        "--vgmstream-bin",
        default="",
        help="Optional explicit path to vgmstream-cli binary.",
    )
    args = parser.parse_args()

    sounds = args.sounds_dir.resolve()
    output = args.output.resolve()
    if not sounds.exists():
        raise SystemExit(f"Sounds directory missing: {sounds}")

    manifests = output / "manifests"
    raw_root = output / "raw"
    wav_root = output / "wav_pcm"
    wav_vgm_root = output / "wav_vgmstream"
    manifests.mkdir(parents=True, exist_ok=True)
    if args.extract_raw:
        raw_root.mkdir(parents=True, exist_ok=True)
    if args.decode_pcm:
        wav_root.mkdir(parents=True, exist_ok=True)
    if args.decode_vgmstream:
        wav_vgm_root.mkdir(parents=True, exist_ok=True)

    vgmstream_bin = resolve_vgmstream_bin(args.vgmstream_bin)
    vgmstream_available = bool(vgmstream_bin)

    xwb_files = sorted(sounds.glob("*.xwb"), key=lambda p: p.name.lower())
    xsb_files = sorted(sounds.glob("*.xsb"), key=lambda p: p.name.lower())
    if args.max_banks > 0:
        xwb_files = xwb_files[: args.max_banks]

    cues_by_bankstem: dict[str, list[str]] = {p.stem.lower(): parse_xsb_cues(p) for p in xsb_files}

    bank_reports: list[dict] = []
    tag_counts: Counter[int] = Counter()
    raw_count = 0
    pcm_count = 0
    vgm_count = 0

    for xwb in xwb_files:
        parsed = parse_xwb(xwb)
        bank_name = sanitize_name(parsed["bank_name"] or xwb.stem)
        bank_stem = xwb.stem.lower()
        cues = cues_by_bankstem.get(bank_stem, [])

        entry_reports: list[dict] = []
        entries = parsed["entries"]
        if args.max_entries > 0:
            entries = entries[: args.max_entries]

        for entry in entries:
            tag = int(entry["tag"])
            tag_counts[tag] += 1
            idx = int(entry["index"])
            cue_name = cues[idx] if idx < len(cues) else ""
            safe_cue = sanitize_name(cue_name) if cue_name else f"entry_{idx:04d}"
            stem = f"{idx:04d}_{safe_cue}"

            rep = {
                "index": idx,
                "cue_name_guess": cue_name,
                "tag": tag,
                "channels": entry["channels"],
                "sample_rate": entry["sample_rate"],
                "bits_per_sample_guess": entry["bits_per_sample_guess"],
                "play_offset": entry["play_offset"],
                "play_length": entry["play_length"],
                "format_raw": entry["format_raw"],
            }

            blob: bytes = entry["raw_blob"]

            if args.extract_raw:
                raw_path = raw_root / bank_name / f"{stem}.bin"
                raw_path.parent.mkdir(parents=True, exist_ok=True)
                raw_path.write_bytes(blob)
                rep["raw_file"] = raw_path.relative_to(output).as_posix()
                raw_count += 1

            if args.decode_pcm and tag == 0 and blob:
                wav_path = wav_root / bank_name / f"{stem}.wav"
                wav_path.parent.mkdir(parents=True, exist_ok=True)
                write_pcm_wav(
                    wav_path,
                    blob,
                    channels=max(1, int(entry["channels"])),
                    sample_rate=max(1, int(entry["sample_rate"])),
                    bits=max(8, int(entry["bits_per_sample_guess"])),
                )
                rep["pcm_wav_file"] = wav_path.relative_to(output).as_posix()
                pcm_count += 1
            elif args.decode_pcm and tag != 0:
                rep["decode_note"] = (
                    "Non-PCM tag; requires ADPCM/XACT-capable decoder (vgmstream recommended) for WAV/OGG conversion."
                )

            entry_reports.append(rep)

        bank_report = {
            "bank_file": xwb.name,
            "bank_name": parsed["bank_name"],
            "segments": parsed["segments"],
            "entry_count_header": parsed["entry_count_header"],
            "entry_size": parsed["entry_size"],
            "xsb_cue_count_guess": len(cues),
            "entries": entry_reports,
        }

        if args.decode_vgmstream:
            if vgmstream_available:
                vgm_result = run_vgmstream_bank(vgmstream_bin, xwb, wav_vgm_root / bank_name)
                vgm_count += int(vgm_result["wav_count"])
                bank_report["vgmstream"] = {"status": "ok" if vgm_result["returncode"] == 0 else "error", **vgm_result}
            else:
                bank_report["vgmstream"] = {
                    "status": "tool_missing",
                    "note": "vgmstream-cli not found on PATH and --vgmstream-bin not provided.",
                }

        bank_reports.append(bank_report)

    summary = {
        "created_utc": now_iso(),
        "sounds_dir": sounds.as_posix(),
        "output": output.as_posix(),
        "xwb_count": len(xwb_files),
        "xsb_count": len(xsb_files),
        "raw_written": raw_count,
        "pcm_wav_written": pcm_count,
        "vgmstream_wav_written": vgm_count,
        "tag_counts": {str(k): v for k, v in sorted(tag_counts.items())},
        "options": {
            "max_banks": args.max_banks,
            "max_entries": args.max_entries,
            "extract_raw": args.extract_raw,
            "decode_pcm": args.decode_pcm,
            "decode_vgmstream": args.decode_vgmstream,
            "vgmstream_bin": vgmstream_bin,
            "vgmstream_available": vgmstream_available,
        },
    }

    manifest = {"summary": summary, "banks": bank_reports}
    (manifests / "audio_manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")

    decode_help = [
        "#!/usr/bin/env bash",
        "set -euo pipefail",
        "",
        "# Requires vgmstream-cli installed.",
        f"SOUNDS_DIR=\"{sounds.as_posix()}\"",
        f"OUT_DIR=\"{(output / 'wav_vgmstream').as_posix()}\"",
        "mkdir -p \"$OUT_DIR\"",
        "for xwb in \"$SOUNDS_DIR\"/*.xwb; do",
        "  bank=\"$(basename \"${xwb%.*}\")\"",
        "  mkdir -p \"$OUT_DIR/$bank\"",
        "  # vgmstream subsong numbering is 1-based.",
        "  vgmstream-cli -S 0 -o \"$OUT_DIR/$bank/?s.wav\" \"$xwb\" || true",
        "done",
        "",
    ]
    helper = manifests / "decode_with_vgmstream.sh"
    helper.write_text("\n".join(decode_help), encoding="utf-8")
    helper.chmod(0o755)

    md = [
        "# Audio Bridge Pass",
        "",
        f"- Created (UTC): `{summary['created_utc']}`",
        f"- XWB banks: **{summary['xwb_count']}**",
        f"- XSB files: **{summary['xsb_count']}**",
        f"- Raw entry blobs: **{summary['raw_written']}**",
        f"- PCM WAV decoded: **{summary['pcm_wav_written']}**",
        f"- vgmstream WAV decoded: **{summary['vgmstream_wav_written']}**",
        "",
        "## Tag Counts",
    ]
    for k, v in sorted(tag_counts.items()):
        md.append(f"- `tag {k}`: {v}")
    md += [
        "",
        "## Notes",
        "- `tag 0` entries were wrapped as PCM WAV using inferred channel/rate/bit-depth fields.",
        "- Most entries are non-PCM tags and need a dedicated decoder (vgmstream recommended).",
        f"- vgmstream available: `{vgmstream_available}`",
        f"- Helper script: `{helper.as_posix()}`",
    ]
    (manifests / "audio_report.md").write_text("\n".join(md) + "\n", encoding="utf-8")

    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
