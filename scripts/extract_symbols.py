#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import re
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path


SECTION_RE = re.compile(
    r"^\s*([0-9A-F]{4}:[0-9A-F]{8})\s+([0-9A-F]{8})H\s+(\S+)\s+(\S+)\s*$",
    re.IGNORECASE,
)
SYMBOL_RE = re.compile(
    r"^\s*([0-9A-F]{4}:[0-9A-F]{8})\s+(\S+)\s+([0-9A-F]{8})\s+(.*)$",
    re.IGNORECASE,
)
HEX_RE = re.compile(r"^[0-9A-F]{8}$", re.IGNORECASE)


SYSTEM_KEYWORDS: dict[str, tuple[str, ...]] = {
    "ui": ("vui", "menu", "hud", "brief", "shell", "textbox", "icon", "window"),
    "render": ("render", "draw", "shader", "texture", "d3d", "xgrph", "camera", "vertex", "material"),
    "audio": ("sound", "audio", "xact", "wma", "dsound", "mixer", "voice", "music"),
    "video": ("bink", "video", "movie", "clip", "cutscene"),
    "input": ("input", "joy", "gamepad", "button", "controller", "xid"),
    "network": ("net", "xnet", "live", "socket", "udp", "tcp"),
    "ai": ("ai", "path", "nav", "enemy", "squad", "perception", "tactic"),
    "physics": ("phys", "collision", "raycast", "trace", "rigid", "kinematic"),
    "gameplay": (
        "mission",
        "level",
        "weapon",
        "power",
        "inventory",
        "objective",
        "player",
        "ghost",
        "calldown",
        "combat",
    ),
    "scripting": ("script", "console", "command", "nui", "nsc"),
    "system": ("memory", "alloc", "thread", "file", "stream", "zlib", "debug", "error", "assert"),
}


INTERESTING_STRINGS_RE = re.compile(
    r"(menu|level|mission|ghost|calldown|cloak|video|audio|shader|d3d|debug|error|xbox|weapon|inventory|script|render|camera|texture|sound|music)",
    re.IGNORECASE,
)
PATHLIKE_RE = re.compile(r"^([A-Za-z]:\\|\\Device\\|/|-[A-Za-z])")


def now_iso() -> str:
    return datetime.now(tz=timezone.utc).isoformat()


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while True:
            chunk = f.read(1024 * 1024)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def parse_map(path: Path) -> tuple[list[dict], list[dict]]:
    text = path.read_text(encoding="latin-1", errors="replace")
    lines = text.splitlines()
    sections: list[dict] = []
    symbols: list[dict] = []
    in_publics = False

    for line in lines:
        if not in_publics and "Publics by Value" in line:
            in_publics = True
            continue

        if not in_publics:
            m = SECTION_RE.match(line)
            if not m:
                continue
            start, length_hex, name, cls = m.groups()
            sections.append(
                {
                    "source_map": path.name,
                    "start": start,
                    "length_hex": length_hex,
                    "name": name,
                    "class": cls,
                }
            )
            continue

        m = SYMBOL_RE.match(line)
        if not m:
            continue
        addr, symbol, rva, tail = m.groups()
        if not HEX_RE.match(rva):
            continue
        tail_parts = tail.split()
        obj = None
        for part in reversed(tail_parts):
            if part.lower().endswith(".obj"):
                obj = part
                break
            if part.startswith("<") and part.endswith(">"):
                obj = part
                break
        symbols.append(
            {
                "source_map": path.name,
                "address": addr,
                "rva_plus_base": rva,
                "symbol_raw": symbol,
                "object": obj,
            }
        )

    return sections, symbols


def demangle_guess(symbol: str) -> str:
    if not symbol:
        return symbol
    if symbol.startswith("??0"):
        cls = symbol[3:].split("@@", 1)[0]
        return f"{cls}::{cls}"
    if symbol.startswith("??1"):
        cls = symbol[3:].split("@@", 1)[0]
        return f"{cls}::~{cls}"
    if symbol.startswith("?"):
        core = symbol[1:].split("@@", 1)[0]
        parts = core.split("@")
        if len(parts) >= 2 and parts[0] and parts[1]:
            return f"{parts[1]}::{parts[0]}"
        if parts and parts[0]:
            return parts[0]
    return symbol


def classify_system(symbol: str, obj: str | None) -> str:
    hay = f"{symbol} {obj or ''}".lower()
    for system, keywords in SYSTEM_KEYWORDS.items():
        if any(k in hay for k in keywords):
            return system
    return "unknown"


def extract_ascii_strings(path: Path, min_len: int = 5) -> list[str]:
    data = path.read_bytes()
    out: list[str] = []
    buf: list[int] = []

    for b in data:
        if 32 <= b <= 126:
            buf.append(b)
            continue
        if len(buf) >= min_len:
            out.append(bytes(buf).decode("ascii", errors="ignore"))
        buf = []

    if len(buf) >= min_len:
        out.append(bytes(buf).decode("ascii", errors="ignore"))
    return out


def looks_human_readable(s: str) -> bool:
    if len(s) < 5:
        return False
    letters = sum(ch.isalpha() for ch in s)
    if letters < 3:
        return False
    allowed = sum(ch.isalnum() or ch in " ._:/\\-@[](){}%'\"+" for ch in s)
    if allowed / len(s) < 0.85:
        return False
    return True


def top_n(counter: Counter, n: int) -> list[dict]:
    return [{"name": name, "count": count} for name, count in counter.most_common(n)]


def main() -> int:
    parser = argparse.ArgumentParser(description="Extract first-pass symbol and subsystem map for Ghost builds.")
    parser.add_argument(
        "--xbe",
        type=Path,
        default=Path("/home/scott/Games/xemu/starcraft_ghost/GhostR.xbe"),
        help="Target XBE to string-scan.",
    )
    parser.add_argument(
        "--map",
        type=Path,
        action="append",
        default=[],
        help="MAP file(s) to parse. Can be provided multiple times.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("/home/scott/Games/xemu/ghost_port/out/symbols"),
        help="Output directory.",
    )
    parser.add_argument(
        "--max-interesting-strings",
        type=int,
        default=400,
        help="Limit of interesting strings saved in report.",
    )
    args = parser.parse_args()

    xbe = args.xbe.resolve()
    if not xbe.exists():
        raise SystemExit(f"XBE not found: {xbe}")

    map_inputs = args.map or [
        Path("/home/scott/Games/xemu/starcraft_ghost/Ghost.map"),
        Path("/home/scott/Games/xemu/starcraft_ghost/GhostU.map"),
    ]
    map_paths: list[Path] = []
    seen_maps: set[Path] = set()
    for p in map_inputs:
        rp = p.resolve()
        if rp in seen_maps:
            continue
        seen_maps.add(rp)
        map_paths.append(rp)
    for m in map_paths:
        if not m.exists():
            raise SystemExit(f"MAP not found: {m}")

    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)

    all_sections: list[dict] = []
    all_symbols: list[dict] = []
    for m in map_paths:
        sections, symbols = parse_map(m)
        all_sections.extend(sections)
        all_symbols.extend(symbols)

    # Deduplicate by source + address + raw symbol so merged maps remain stable.
    dedup: dict[tuple[str, str, str], dict] = {}
    for sym in all_symbols:
        key = (sym["source_map"], sym["address"], sym["symbol_raw"])
        if key not in dedup:
            dedup[key] = sym
    symbols = list(dedup.values())

    system_counts: Counter[str] = Counter()
    object_counts: Counter[str] = Counter()
    class_counts: Counter[str] = Counter()

    for sym in symbols:
        demangled = demangle_guess(sym["symbol_raw"])
        system = classify_system(demangled, sym.get("object"))
        sym["symbol_guess"] = demangled
        sym["system"] = system
        system_counts[system] += 1
        if sym.get("object"):
            object_counts[sym["object"]] += 1
        if "::" in demangled:
            cls = demangled.split("::", 1)[0]
            # Filter compiler-generated template internals to keep the first pass readable.
            if not cls.startswith("_0"):
                class_counts[cls] += 1

    raw_strings = extract_ascii_strings(xbe, min_len=5)
    interesting_strings = []
    seen = set()
    for s in raw_strings:
        if s in seen:
            continue
        if not looks_human_readable(s):
            continue
        if INTERESTING_STRINGS_RE.search(s) or PATHLIKE_RE.match(s):
            seen.add(s)
            interesting_strings.append(s)
        if len(interesting_strings) >= args.max_interesting_strings:
            break

    summary = {
        "created_utc": now_iso(),
        "xbe": {
            "path": xbe.as_posix(),
            "size_bytes": xbe.stat().st_size,
            "sha256": sha256_file(xbe),
        },
        "maps": [m.as_posix() for m in map_paths],
        "counts": {
            "section_records": len(all_sections),
            "symbol_records": len(symbols),
            "raw_string_count": len(raw_strings),
            "interesting_string_count": len(interesting_strings),
        },
        "top_systems": top_n(system_counts, 16),
        "top_objects": top_n(object_counts, 40),
        "top_classes": top_n(class_counts, 40),
    }

    report = {
        "summary": summary,
        "sections": all_sections,
        "symbols": symbols,
        "interesting_strings": interesting_strings,
    }

    (output / "symbol_report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")

    # Also emit flat CSV-like TSV for quick grep/sort in shell tools.
    tsv_lines = ["source_map\taddress\trva_plus_base\tsystem\tobject\tsymbol_raw\tsymbol_guess"]
    for sym in symbols:
        tsv_lines.append(
            "\t".join(
                [
                    sym.get("source_map", ""),
                    sym.get("address", ""),
                    sym.get("rva_plus_base", ""),
                    sym.get("system", ""),
                    sym.get("object", "") or "",
                    sym.get("symbol_raw", ""),
                    sym.get("symbol_guess", ""),
                ]
            )
        )
    (output / "symbols.tsv").write_text("\n".join(tsv_lines) + "\n", encoding="utf-8")

    md = []
    md.append("# Ghost Symbol Pass (Initial)")
    md.append("")
    md.append(f"- Created (UTC): `{summary['created_utc']}`")
    md.append(f"- XBE: `{summary['xbe']['path']}`")
    md.append(f"- XBE sha256: `{summary['xbe']['sha256']}`")
    md.append(f"- MAP sources: {', '.join(f'`{Path(m).name}`' for m in summary['maps'])}")
    md.append(f"- Parsed symbols: **{summary['counts']['symbol_records']}**")
    md.append("")
    md.append("## Top Systems")
    for row in summary["top_systems"][:10]:
        md.append(f"- `{row['name']}`: {row['count']}")
    md.append("")
    md.append("## Top Object Files")
    for row in summary["top_objects"][:20]:
        md.append(f"- `{row['name']}`: {row['count']}")
    md.append("")
    md.append("## Top Class Guesses")
    for row in summary["top_classes"][:20]:
        md.append(f"- `{row['name']}`: {row['count']}")
    md.append("")
    md.append("## Interesting Strings (Sample)")
    for s in interesting_strings[:120]:
        md.append(f"- `{s}`")
    md.append("")
    md.append("## Notes")
    md.append("- MAP coverage is from `Ghost.map` and `GhostU.map`; there is no standalone `GhostR.map` in this dump.")
    md.append("- Use this output as a targeting index for Ghidra and gameplay subsystem reconstruction.")
    (output / "symbol_report.md").write_text("\n".join(md) + "\n", encoding="utf-8")

    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
