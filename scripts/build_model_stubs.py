#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import math
import re
import struct
import time
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path


MODEL_EXTS_DEFAULT = [".nod", ".noc", ".nmb", ".nnb", ".nad", ".nms", ".xvu", ".npd"]
GLTF_STUB_EXTS = {".nod", ".noc", ".nmb", ".nnb", ".xvu", ".npd"}
GLTF_PARSE_EXTS = {".nod", ".noc"}
REF_RE = re.compile(r"([A-Za-z0-9_\-./]+?\.(?:nod|nad|nnb|nmb|noc|dds|xpr|xsb|xwb|nui|nsd|nil))", re.IGNORECASE)
LABEL_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_.\-]{2,63}$")


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


def guess_type(ext: str) -> str:
    if ext in {".nod", ".noc"}:
        return "model_mesh"
    if ext in {".nad"}:
        return "animation_clip"
    if ext in {".nmb", ".nnb"}:
        return "model_bundle_or_scene"
    if ext in {".nms"}:
        return "motion_set_script"
    if ext in {".xvu"}:
        return "vertex_shader_variant_or_visual_unit"
    if ext in {".npd"}:
        return "physics_or_collision_data"
    return "unknown"


def parse_binary_probe(data: bytes) -> dict:
    probe: dict = {}
    if len(data) >= 4:
        probe["u32_0"] = int.from_bytes(data[0:4], "little")
    if len(data) >= 8:
        probe["u32_1"] = int.from_bytes(data[4:8], "little")
    if len(data) >= 12:
        probe["u32_2"] = int.from_bytes(data[8:12], "little")
    if len(data) >= 32:
        floats = []
        for i in range(8, min(len(data), 80), 4):
            fl = struct.unpack("<f", data[i : i + 4])[0]
            if math.isfinite(fl) and -1_000_000.0 <= fl <= 1_000_000.0:
                floats.append(fl)
            else:
                floats.append(None)
            if len(floats) >= 12:
                break
        probe["float_probe"] = floats
    return probe


def c_string(blob: bytes) -> str:
    end = blob.find(b"\0")
    if end >= 0:
        blob = blob[:end]
    return blob.decode("ascii", errors="ignore").strip()


def parse_header_name_guess(data: bytes) -> str | None:
    for off in (0x2C, 0x30, 0x40, 0x5C, 0x60, 0x70, 0x80):
        if off >= len(data):
            continue
        s = c_string(data[off : off + 64])
        if LABEL_RE.match(s):
            return s
    return None


def parse_bbox_guess(data: bytes) -> dict | None:
    if len(data) < 0x24:
        return None
    vals = struct.unpack_from("<6f", data, 0x0C)
    mins = vals[0:3]
    maxs = vals[3:6]
    if not all(math.isfinite(v) for v in vals):
        return None
    if any(abs(v) > 1_000_000.0 for v in vals):
        return None
    if any(mins[i] > maxs[i] for i in range(3)):
        return None
    spans = [maxs[i] - mins[i] for i in range(3)]
    if all(span == 0.0 for span in spans):
        return None
    return {"min": [float(v) for v in mins], "max": [float(v) for v in maxs], "span": [float(v) for v in spans]}


def in_expanded_bbox(x: float, y: float, z: float, bbox: dict) -> bool:
    mins = bbox["min"]
    maxs = bbox["max"]
    spans = bbox["span"]
    margin = [max(0.25, spans[i] * 0.10) for i in range(3)]
    if x < mins[0] - margin[0] or x > maxs[0] + margin[0]:
        return False
    if y < mins[1] - margin[1] or y > maxs[1] + margin[1]:
        return False
    if z < mins[2] - margin[2] or z > maxs[2] + margin[2]:
        return False
    return True


def candidate_count_hint(data: bytes) -> int | None:
    if len(data) < 0x2C:
        return None
    val = struct.unpack_from("<I", data, 0x28)[0]
    if 4 <= val <= 250_000:
        return int(val)
    return None


def parse_vertex_cloud(
    data: bytes, bbox: dict | None, max_points: int, count_hint: int | None = None
) -> tuple[list[tuple[float, float, float]], list[int], dict] | tuple[None, list[int], dict]:
    if len(data) < 256:
        return None, [], {"status": "too_small"}

    offsets = [0x80, 0x90, 0xA0, 0xB0, 0xC0, 0xE0, 0x100, 0x120]
    offsets.extend(range(0x40, min(len(data) - 12, 0x400), 0x10))
    # Stable unique order.
    seen_off = set()
    offsets = [o for o in offsets if not (o in seen_off or seen_off.add(o))]

    strides = [12, 16, 20, 24, 28, 32, 36, 40, 48, 56, 64]
    best = None

    for off in offsets:
        for stride in strides:
            available = (len(data) - off) // stride
            if available < 12:
                continue
            eval_n = min(available, 256)
            if count_hint:
                eval_n = min(eval_n, max(24, min(count_hint, 256)))

            finite = 0
            inbox = 0
            nonzero = 0
            for i in range(eval_n):
                base = off + i * stride
                try:
                    x, y, z = struct.unpack_from("<fff", data, base)
                except struct.error:
                    break
                if not (math.isfinite(x) and math.isfinite(y) and math.isfinite(z)):
                    continue
                if abs(x) > 1_000_000.0 or abs(y) > 1_000_000.0 or abs(z) > 1_000_000.0:
                    continue
                finite += 1
                if abs(x) + abs(y) + abs(z) > 1e-6:
                    nonzero += 1
                if bbox is None or in_expanded_bbox(x, y, z, bbox):
                    inbox += 1

            if eval_n <= 0:
                continue
            finite_ratio = finite / eval_n
            inbox_ratio = (inbox / finite) if finite else 0.0
            nonzero_ratio = (nonzero / finite) if finite else 0.0
            if bbox is None:
                score = (finite_ratio * 0.75) + (nonzero_ratio * 0.25)
            else:
                score = (finite_ratio * 0.45) + (inbox_ratio * 0.45) + (nonzero_ratio * 0.10)

            cand = {
                "offset": off,
                "stride": stride,
                "available": available,
                "eval_n": eval_n,
                "finite_ratio": round(finite_ratio, 5),
                "inbox_ratio": round(inbox_ratio, 5),
                "nonzero_ratio": round(nonzero_ratio, 5),
                "score": round(score, 5),
            }
            if best is None or cand["score"] > best["score"]:
                best = cand

    if not best:
        return None, [], {"status": "no_candidate"}

    threshold = 0.80 if bbox else 0.88
    if best["score"] < threshold:
        return None, [], {"status": "low_confidence", "best": best}

    off = int(best["offset"])
    stride = int(best["stride"])
    available = int(best["available"])
    target = available
    if count_hint and 4 <= count_hint <= available:
        target = count_hint
    target = min(target, max_points)

    positions: list[tuple[float, float, float]] = []
    orig_indices: list[int] = []
    for i in range(available):
        if len(positions) >= target:
            break
        base = off + i * stride
        try:
            x, y, z = struct.unpack_from("<fff", data, base)
        except struct.error:
            break
        if not (math.isfinite(x) and math.isfinite(y) and math.isfinite(z)):
            continue
        if abs(x) > 1_000_000.0 or abs(y) > 1_000_000.0 or abs(z) > 1_000_000.0:
            continue
        # Keep direct stream order to make later index-buffer remap feasible.
        positions.append((float(x), float(y), float(z)))
        orig_indices.append(i)

    if len(positions) < 8:
        return None, [], {"status": "insufficient_vertices", "best": best, "accepted_vertices": len(positions)}

    parser_meta = {
        "status": "ok",
        "best": best,
        "accepted_vertices": len(positions),
        "stream_offset": off,
        "stream_stride": stride,
        "stream_available": available,
    }
    return positions, orig_indices, parser_meta


def _read_idx(data: bytes, off: int, idx_size: int, little: bool = True) -> int:
    if idx_size == 2:
        return struct.unpack_from("<H" if little else ">H", data, off)[0]
    return struct.unpack_from("<I" if little else ">I", data, off)[0]


def parse_index_buffer(
    data: bytes,
    vertex_span_count: int,
    stream_offset: int,
    stream_stride: int,
    stream_available: int,
    count_hint: int | None,
    max_tris: int = 10000,
) -> tuple[list[int] | None, dict]:
    if vertex_span_count < 8:
        return None, {"status": "vertex_span_too_small"}

    large_span = vertex_span_count >= 2048
    dense_window = 0x10000 if large_span else 0x24000
    dense_step = 0x20 if large_span else 0x10
    sparse_step = 0x800 if large_span else 0x400
    tri_scan_cap = 3000 if large_span else 6000
    scan_deadline = time.monotonic() + (0.85 if large_span else 1.5)

    # Likely index region starts after packed vertex stream.
    stream_count_guess = count_hint if count_hint and 4 <= count_hint <= stream_available else min(stream_available, vertex_span_count)
    idx_region_start = stream_offset + max(0, stream_count_guess * max(1, stream_stride))
    idx_region_start = max(0x80, min(idx_region_start, max(0x80, len(data) - 6)))

    candidate_offsets: list[int] = []
    # Dense local search around probable region.
    for base in range(max(0x80, idx_region_start - 0x800), min(len(data) - 6, idx_region_start + dense_window), dense_step):
        candidate_offsets.append(base)
    # Sparse global fallback search.
    for base in range(0x80, min(len(data) - 6, 0x200000), sparse_step):
        candidate_offsets.append(base)

    seen = set()
    candidate_offsets = [o for o in candidate_offsets if not (o in seen or seen.add(o))]

    best = None
    best_indices: list[int] | None = None
    timed_out = False
    candidate_checks = 0

    for off in candidate_offsets:
        for idx_size in (2, 4):
            candidate_checks += 1
            if time.monotonic() > scan_deadline:
                timed_out = True
                break
            remain = len(data) - off
            if remain < idx_size * 24:
                continue
            max_values = min(remain // idx_size, max_tris * 3 * 2)
            tri_count_scan = min(max_values // 3, tri_scan_cap)
            if tri_count_scan < 24:
                continue

            vals: list[int] = []
            valid = 0
            invalid = 0
            deg = 0
            consecutive_invalid = 0
            max_idx_seen = 0

            for t in range(tri_count_scan):
                base = off + t * 3 * idx_size
                try:
                    i0 = _read_idx(data, base + 0 * idx_size, idx_size, little=True)
                    i1 = _read_idx(data, base + 1 * idx_size, idx_size, little=True)
                    i2 = _read_idx(data, base + 2 * idx_size, idx_size, little=True)
                except struct.error:
                    break

                if i0 >= vertex_span_count or i1 >= vertex_span_count or i2 >= vertex_span_count:
                    invalid += 1
                    consecutive_invalid += 1
                    if consecutive_invalid > 12 and valid >= 24:
                        break
                    if t > 192 and valid == 0 and invalid > 64:
                        break
                    if t > 256 and invalid > (valid * 4):
                        break
                    continue

                consecutive_invalid = 0
                max_idx_seen = max(max_idx_seen, i0, i1, i2)
                if i0 == i1 or i1 == i2 or i0 == i2:
                    deg += 1
                    if t > 384 and valid < 8 and deg > 192:
                        break
                    continue

                vals.extend([i0, i1, i2])
                valid += 1
                if valid >= max_tris:
                    break

            if valid < 24:
                continue

            total = valid + invalid + deg
            ratio = valid / total if total else 0.0
            score = (valid * 1.0) + (ratio * 150.0) - (invalid * 0.75) - (deg * 0.25)

            cand = {
                "offset": off,
                "index_size": idx_size,
                "triangles_valid": valid,
                "triangles_invalid": invalid,
                "triangles_degenerate": deg,
                "valid_ratio": round(ratio, 5),
                "max_index_seen": int(max_idx_seen),
                "score": round(score, 5),
            }

            if best is None or cand["score"] > best["score"]:
                best = cand
                best_indices = vals

            # Stop searching once a high-confidence candidate is found.
            if best and best["valid_ratio"] >= 0.92 and best["triangles_valid"] >= 240 and candidate_checks >= 96:
                break
        if timed_out:
            break
        if best and best["valid_ratio"] >= 0.92 and best["triangles_valid"] >= 240 and candidate_checks >= 96:
            break

    if best is None or not best_indices:
        return None, {"status": "no_index_candidate"}

    if best["valid_ratio"] < 0.50:
        return None, {"status": "low_index_confidence", "best": best}

    meta = {"status": "ok", "best": best}
    if timed_out:
        meta["scan_note"] = "index_scan_deadline_hit"
    return best_indices, meta


def remap_triangles_to_compact(indices: list[int], orig_indices: list[int]) -> list[int]:
    if not indices or not orig_indices:
        return []
    orig_to_new = {orig: i for i, orig in enumerate(orig_indices)}
    out: list[int] = []
    for t in range(0, len(indices), 3):
        if t + 2 >= len(indices):
            break
        a0, a1, a2 = indices[t], indices[t + 1], indices[t + 2]
        if a0 not in orig_to_new or a1 not in orig_to_new or a2 not in orig_to_new:
            continue
        n0, n1, n2 = orig_to_new[a0], orig_to_new[a1], orig_to_new[a2]
        if n0 == n1 or n1 == n2 or n0 == n2:
            continue
        out.extend([n0, n1, n2])
    return out


def make_stub_gltf(name: str, source_rel: str, meta_rel: str, refs: list[str]) -> dict:
    positions = (
        b"\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
        b"\x00\x00\x80\x3f\x00\x00\x00\x00\x00\x00\x00\x00"
        b"\x00\x00\x00\x00\x00\x00\x80\x3f\x00\x00\x00\x00"
    )
    indices = b"\x00\x00\x01\x00\x02\x00"
    blob = positions + indices
    b64 = base64.b64encode(blob).decode("ascii")
    return {
        "asset": {"version": "2.0", "generator": "ghost_port build_model_stubs.py"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [
            {
                "name": name,
                "mesh": 0,
                "extras": {
                    "source_relative_path": source_rel,
                    "metadata_relative_path": meta_rel,
                    "references": refs,
                    "note": "Fallback stub geometry only; parser could not recover vertex stream with confidence.",
                },
            }
        ],
        "meshes": [{"name": f"{name}_stub", "primitives": [{"attributes": {"POSITION": 0}, "indices": 1}]}],
        "buffers": [{"uri": f"data:application/octet-stream;base64,{b64}", "byteLength": len(blob)}],
        "bufferViews": [
            {"buffer": 0, "byteOffset": 0, "byteLength": len(positions), "target": 34962},
            {"buffer": 0, "byteOffset": len(positions), "byteLength": len(indices), "target": 34963},
        ],
        "accessors": [
            {
                "bufferView": 0,
                "componentType": 5126,
                "count": 3,
                "type": "VEC3",
                "min": [0.0, 0.0, 0.0],
                "max": [1.0, 1.0, 0.0],
            },
            {"bufferView": 1, "componentType": 5123, "count": 3, "type": "SCALAR"},
        ],
    }


def make_pointcloud_gltf(
    name: str, source_rel: str, meta_rel: str, refs: list[str], positions: list[tuple[float, float, float]]
) -> dict:
    blob = b"".join(struct.pack("<fff", *p) for p in positions)
    b64 = base64.b64encode(blob).decode("ascii")
    xs = [p[0] for p in positions]
    ys = [p[1] for p in positions]
    zs = [p[2] for p in positions]
    return {
        "asset": {"version": "2.0", "generator": "ghost_port build_model_stubs.py"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [
            {
                "name": name,
                "mesh": 0,
                "extras": {
                    "source_relative_path": source_rel,
                    "metadata_relative_path": meta_rel,
                    "references": refs,
                    "note": "Auto-parsed vertex stream rendered as POINTS (mode=0).",
                },
            }
        ],
        "meshes": [{"name": f"{name}_pointcloud", "primitives": [{"attributes": {"POSITION": 0}, "mode": 0}]}],
        "buffers": [{"uri": f"data:application/octet-stream;base64,{b64}", "byteLength": len(blob)}],
        "bufferViews": [{"buffer": 0, "byteOffset": 0, "byteLength": len(blob), "target": 34962}],
        "accessors": [
            {
                "bufferView": 0,
                "componentType": 5126,
                "count": len(positions),
                "type": "VEC3",
                "min": [min(xs), min(ys), min(zs)],
                "max": [max(xs), max(ys), max(zs)],
            }
        ],
    }


def make_triangle_gltf(
    name: str,
    source_rel: str,
    meta_rel: str,
    refs: list[str],
    positions: list[tuple[float, float, float]],
    indices: list[int],
) -> dict:
    pos_blob = b"".join(struct.pack("<fff", *p) for p in positions)
    max_idx = max(indices) if indices else 0
    if max_idx < 65536:
        idx_component_type = 5123  # UNSIGNED_SHORT
        idx_blob = b"".join(struct.pack("<H", i) for i in indices)
    else:
        idx_component_type = 5125  # UNSIGNED_INT
        idx_blob = b"".join(struct.pack("<I", i) for i in indices)
    blob = pos_blob + idx_blob
    b64 = base64.b64encode(blob).decode("ascii")
    xs = [p[0] for p in positions]
    ys = [p[1] for p in positions]
    zs = [p[2] for p in positions]
    return {
        "asset": {"version": "2.0", "generator": "ghost_port build_model_stubs.py"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [
            {
                "name": name,
                "mesh": 0,
                "extras": {
                    "source_relative_path": source_rel,
                    "metadata_relative_path": meta_rel,
                    "references": refs,
                    "note": "Auto-parsed vertex stream + inferred index buffer rendered as TRIANGLES.",
                },
            }
        ],
        "meshes": [{"name": f"{name}_triangles", "primitives": [{"attributes": {"POSITION": 0}, "indices": 1}]}],
        "buffers": [{"uri": f"data:application/octet-stream;base64,{b64}", "byteLength": len(blob)}],
        "bufferViews": [
            {"buffer": 0, "byteOffset": 0, "byteLength": len(pos_blob), "target": 34962},
            {"buffer": 0, "byteOffset": len(pos_blob), "byteLength": len(idx_blob), "target": 34963},
        ],
        "accessors": [
            {
                "bufferView": 0,
                "componentType": 5126,
                "count": len(positions),
                "type": "VEC3",
                "min": [min(xs), min(ys), min(zs)],
                "max": [max(xs), max(ys), max(zs)],
            },
            {"bufferView": 1, "componentType": idx_component_type, "count": len(indices), "type": "SCALAR"},
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Create model/animation metadata and glTF outputs with best-effort geometry parsing for NOD/NOC."
    )
    parser.add_argument(
        "--source",
        type=Path,
        default=Path("/home/scott/Games/xemu/starcraft_ghost/3D"),
        help="Path to Ghost 3D folder.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("/home/scott/Games/xemu/ghost_port/out/model_stubs"),
        help="Output folder.",
    )
    parser.add_argument(
        "--ext",
        action="append",
        default=[],
        help="Extension to include (repeatable). Defaults to known model/anim set.",
    )
    parser.add_argument("--max-files", type=int, default=0, help="Limit number of files (0 = all).")
    parser.add_argument("--hash", action="store_true", help="Compute sha256 per source file.")
    parser.add_argument("--write-gltf", action="store_true", help="Write glTF output for mesh-like files.")
    parser.add_argument(
        "--scan-bytes",
        type=int,
        default=262144,
        help="Bytes to scan for embedded strings/references per file.",
    )
    parser.add_argument(
        "--max-points-per-mesh",
        type=int,
        default=1500,
        help="Maximum points exported per parsed mesh glTF.",
    )
    args = parser.parse_args()

    source = args.source.resolve()
    output = args.output.resolve()
    if not source.exists():
        raise SystemExit(f"Source directory missing: {source}")

    exts = [e.lower() if e.startswith(".") else f".{e.lower()}" for e in (args.ext or MODEL_EXTS_DEFAULT)]
    extset = set(exts)

    files = sorted([p for p in source.rglob("*") if p.is_file() and p.suffix.lower() in extset], key=lambda p: p.as_posix())
    if args.max_files > 0:
        files = files[: args.max_files]

    meta_root = output / "metadata"
    gltf_root = output / "gltf_stub"
    manifest_root = output / "manifests"
    meta_root.mkdir(parents=True, exist_ok=True)
    if args.write_gltf:
        gltf_root.mkdir(parents=True, exist_ok=True)
    manifest_root.mkdir(parents=True, exist_ok=True)

    records: list[dict] = []
    ext_counts: Counter[str] = Counter()
    type_counts: Counter[str] = Counter()
    gltf_triangle_count = 0
    gltf_pointcloud_count = 0
    gltf_fallback_stub_count = 0

    for src in files:
        rel = src.relative_to(source)
        rel_posix = rel.as_posix()
        ext = src.suffix.lower()
        typ = guess_type(ext)
        ext_counts[ext] += 1
        type_counts[typ] += 1

        raw = src.read_bytes()
        data_head = raw[:4096]
        data_scan = raw[: max(4096, min(len(raw), int(args.scan_bytes)))]
        strings = printable_strings(data_scan, min_len=4, max_items=3000)
        refs = sorted(set(m.group(1) for s in strings for m in REF_RE.finditer(s)))
        probe = parse_binary_probe(data_head)
        bbox = parse_bbox_guess(data_head)
        name_guess = parse_header_name_guess(data_head)
        count_hint = candidate_count_hint(data_head)

        rec = {
            "source_relative_path": rel_posix,
            "extension": ext,
            "guessed_type": typ,
            "size_bytes": src.stat().st_size,
            "header_hex_64": data_head[:64].hex(),
            "binary_probe": probe,
            "header_name_guess": name_guess,
            "bbox_guess": bbox,
            "count_hint_u32_0x28": count_hint,
            "embedded_strings_head": strings[:200],
            "reference_candidates": refs[:300],
        }
        if ext == ".nms":
            try:
                rec["nms_text_preview"] = raw[:4096].decode("cp1252", errors="replace").replace("\r\n", "\n").splitlines()[:40]
            except Exception:
                rec["nms_text_preview"] = []

        if args.hash:
            rec["sha256"] = sha256_file(src)

        meta_path = meta_root / rel.with_suffix(rel.suffix + ".json")
        meta_path.parent.mkdir(parents=True, exist_ok=True)
        rec["metadata_file"] = meta_path.relative_to(output).as_posix()

        if args.write_gltf and ext in GLTF_STUB_EXTS:
            gltf_path = gltf_root / rel.with_suffix(".gltf")
            gltf_path.parent.mkdir(parents=True, exist_ok=True)

            gltf = None
            if ext in GLTF_PARSE_EXTS:
                positions, orig_indices, parser_meta = parse_vertex_cloud(
                    raw, bbox=bbox, max_points=max(8, int(args.max_points_per_mesh)), count_hint=count_hint
                )
                rec["geometry_parse"] = parser_meta
                if positions:
                    idx_source, idx_meta = parse_index_buffer(
                        raw,
                        vertex_span_count=max(
                            int(parser_meta.get("stream_available", len(orig_indices))),
                            (max(orig_indices) + 1) if orig_indices else len(orig_indices),
                        ),
                        stream_offset=int(parser_meta.get("stream_offset", 0)),
                        stream_stride=int(parser_meta.get("stream_stride", 0)),
                        stream_available=int(parser_meta.get("stream_available", len(orig_indices))),
                        count_hint=count_hint,
                        max_tris=20000,
                    )
                    rec["geometry_parse"]["index_parse"] = idx_meta

                    tri_indices: list[int] = []
                    if idx_source:
                        tri_indices = remap_triangles_to_compact(idx_source, orig_indices)
                        rec["geometry_parse"]["triangle_index_count"] = len(tri_indices)
                        rec["geometry_parse"]["triangle_count"] = len(tri_indices) // 3

                    if tri_indices and len(tri_indices) >= 9:
                        gltf = make_triangle_gltf(src.stem, rel_posix, rec["metadata_file"], refs[:80], positions, tri_indices)
                        rec["geometry_parse"]["mode"] = "triangle_index"
                        rec["geometry_parse"]["point_count"] = len(positions)
                        gltf_triangle_count += 1
                    else:
                        gltf = make_pointcloud_gltf(src.stem, rel_posix, rec["metadata_file"], refs[:80], positions)
                        rec["geometry_parse"]["mode"] = "pointcloud"
                        rec["geometry_parse"]["point_count"] = len(positions)
                        gltf_pointcloud_count += 1

            if gltf is None:
                gltf = make_stub_gltf(src.stem, rel_posix, rec["metadata_file"], refs[:80])
                rec.setdefault("geometry_parse", {"status": "not_attempted"})["mode"] = "fallback_stub"
                gltf_fallback_stub_count += 1

            gltf_path.write_text(json.dumps(gltf, indent=2), encoding="utf-8")
            rec["gltf_stub_file"] = gltf_path.relative_to(output).as_posix()

        meta_path.write_text(json.dumps(rec, indent=2), encoding="utf-8")
        records.append(rec)

    summary = {
        "created_utc": now_iso(),
        "source": source.as_posix(),
        "output": output.as_posix(),
        "file_count": len(records),
        "extensions": dict(sorted(ext_counts.items())),
        "guessed_types": dict(sorted(type_counts.items())),
        "gltf_outputs": {
            "triangle_mesh_generated": gltf_triangle_count,
            "pointcloud_generated": gltf_pointcloud_count,
            "fallback_stub_generated": gltf_fallback_stub_count,
        },
        "options": {
            "extensions": sorted(extset),
            "max_files": args.max_files,
            "hash": args.hash,
            "write_gltf": args.write_gltf,
            "scan_bytes": args.scan_bytes,
            "max_points_per_mesh": args.max_points_per_mesh,
        },
    }

    manifest = {"summary": summary, "records": records}
    (manifest_root / "model_stub_manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")

    md_lines = [
        "# Model Stub Pass",
        "",
        f"- Created (UTC): `{summary['created_utc']}`",
        f"- Source: `{summary['source']}`",
        f"- Files processed: **{summary['file_count']}**",
        f"- Triangle/index glTF parsed: **{gltf_triangle_count}**",
        f"- Point-cloud glTF parsed: **{gltf_pointcloud_count}**",
        f"- Fallback stub glTF: **{gltf_fallback_stub_count}**",
        "",
        "## Extension Counts",
    ]
    for k, v in sorted(ext_counts.items()):
        md_lines.append(f"- `{k}`: {v}")
    md_lines += ["", "## Type Guesses"]
    for k, v in sorted(type_counts.items()):
        md_lines.append(f"- `{k}`: {v}")
    md_lines += [
        "",
        "## Notes",
        "- `.nod/.noc` now attempt best-effort vertex stream parsing and index-buffer reconstruction (TRIANGLES).",
        "- If index parse fails or remap is sparse, output falls back to POINTS.",
        "- Remaining formats still require full reverse-engineered decoders for exact mesh/skeleton/animation fidelity.",
    ]
    (manifest_root / "model_stub_report.md").write_text("\n".join(md_lines) + "\n", encoding="utf-8")

    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
