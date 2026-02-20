#!/usr/bin/env python3
"""
NIL Level Parser for StarCraft: Ghost Xbox assets.

Parses Nihilistic Software .NIL binary level files and extracts geometry
as triangle-strip meshes with material assignments.

NIL Format (magic "NIL\x10"):
  Header (0x60 bytes):
    0x00: u8[4]  magic "NIL\x10"
    0x04: u32    mesh section count (e.g. 35)
    0x08: u32    flags
    0x0C: u32    sub-section count
    0x10: u32    reserved
    0x14: float[3] bounding box dimensions
    0x20: float[4] orientation quaternion
    0x30: u8[16]  padding/reserved
    0x50: float[3] unknown floats
    0x5C: u32    material name count

  Material Names:
    name_count × 0x20 bytes (null-padded ASCII)

  Mesh Sections (variable):
    Multiple vertex blocks with 36-byte stride:
      float[3] position  (12 bytes)
      float[3] normal    (12 bytes)
      u8[4]   rgba       (4 bytes) - vertex color / material tint
      float[2] uv        (8 bytes) - texture coordinates

  Vertex blocks form triangle strips. Consecutive vertices
  alternate winding: (v0,v1,v2), (v1,v3,v2), (v2,v3,v4), ...

Usage:
  python3 nil_parser.py --input path/to/level.nil --output level.json
  python3 nil_parser.py --input path/to/level.nil --output level.gltf --format gltf
"""
from __future__ import annotations

import argparse
import base64
import json
import math
import os
import struct
import sys
from pathlib import Path


# ---------------------------------------------------------------------------
# Binary helpers (matching nod_to_gltf.py conventions)
# ---------------------------------------------------------------------------

def read_u8(data: bytes, off: int) -> int:
    return data[off]

def read_u16(data: bytes, off: int) -> int:
    return struct.unpack_from('<H', data, off)[0]

def read_u32(data: bytes, off: int) -> int:
    return struct.unpack_from('<I', data, off)[0]

def read_f32(data: bytes, off: int) -> float:
    return struct.unpack_from('<f', data, off)[0]


# ---------------------------------------------------------------------------
# Vertex validation
# ---------------------------------------------------------------------------

VERTEX_STRIDE = 36  # pos(3f) + normal(3f) + rgba(4B) + uv(2f)

def is_valid_vertex(data: bytes, off: int, max_coord: float = 500.0) -> bool:
    """Check if 36 bytes at off form a valid NIL vertex."""
    if off + VERTEX_STRIDE > len(data):
        return False
    try:
        px, py, pz = struct.unpack_from('<3f', data, off)
        nx, ny, nz = struct.unpack_from('<3f', data, off + 12)

        # Position must be finite and within level bounds
        if not all(math.isfinite(v) and abs(v) < max_coord for v in (px, py, pz)):
            return False
        # At least one coordinate should be meaningful (not all near zero)
        if not any(abs(v) > 3.0 for v in (px, py, pz)):
            return False

        # Normal must be a unit vector
        mag_sq = nx * nx + ny * ny + nz * nz
        if not (0.81 < mag_sq < 1.21):  # ~0.9 to ~1.1 magnitude
            return False
        if not all(abs(v) <= 1.05 for v in (nx, ny, nz)):
            return False

        # Alpha byte should be high (vertex colors use full alpha)
        alpha = data[off + 27]
        if alpha < 0xF0:
            return False

        return True
    except (struct.error, IndexError):
        return False


# ---------------------------------------------------------------------------
# NIL parsing
# ---------------------------------------------------------------------------

def parse_nil_header(data: bytes) -> dict | None:
    """Parse the NIL file header and material names."""
    if len(data) < 0x60:
        return None

    magic = data[0:4]
    if magic != b'NIL\x10':
        return None

    section_count = read_u32(data, 0x04)
    flags = read_u32(data, 0x08)
    sub_count = read_u32(data, 0x0C)

    # Bounding box dimensions at 0x14
    bbox_dims = struct.unpack_from('<3f', data, 0x14)

    # Orientation at 0x20
    orient = struct.unpack_from('<4f', data, 0x20)

    # Material name count at 0x5C
    mat_count = read_u32(data, 0x5C)
    if mat_count > 200:  # sanity check
        return None

    # Read material names
    materials = []
    off = 0x60
    for i in range(mat_count):
        if off + 0x20 > len(data):
            break
        raw = data[off:off + 0x20]
        name = raw.split(b'\x00')[0].decode('ascii', errors='ignore')
        materials.append(name)
        off += 0x20

    return {
        'magic': magic.decode('ascii', errors='ignore'),
        'section_count': section_count,
        'flags': flags,
        'sub_count': sub_count,
        'bbox_dims': bbox_dims,
        'orientation': orient,
        'material_count': mat_count,
        'materials': materials,
        'data_start': off,
    }


def find_vertex_blocks(data: bytes, start_offset: int,
                       min_verts: int = 3) -> list[dict]:
    """Scan binary data for vertex blocks (triangle strips).

    Returns list of blocks with start offset, vertex count, and
    whether the block has a vertex count header at offset -4.
    """
    blocks = []
    off = start_offset

    while off < len(data) - VERTEX_STRIDE:
        if is_valid_vertex(data, off):
            block_start = off
            count = 0
            while is_valid_vertex(data, off):
                count += 1
                off += VERTEX_STRIDE

            if count >= min_verts:
                # Check if there's a vertex count at offset -4
                has_header = False
                header_count = 0
                if block_start >= 4:
                    header_count = read_u32(data, block_start - 4)
                    if header_count >= count and header_count < 100000:
                        has_header = True

                blocks.append({
                    'offset': block_start,
                    'count': count,
                    'has_header': has_header,
                    'header_count': header_count if has_header else 0,
                })
        else:
            off += 1  # Scan at byte granularity

    return blocks


def extract_vertices(data: bytes, offset: int, count: int) -> list[dict]:
    """Extract vertex data from a block."""
    vertices = []
    for i in range(count):
        off = offset + i * VERTEX_STRIDE
        if off + VERTEX_STRIDE > len(data):
            break

        px, py, pz = struct.unpack_from('<3f', data, off)
        nx, ny, nz = struct.unpack_from('<3f', data, off + 12)
        r, g, b, a = data[off + 24], data[off + 25], data[off + 26], data[off + 27]
        u, v = struct.unpack_from('<2f', data, off + 28)

        vertices.append({
            'position': [px, py, pz],
            'normal': [nx, ny, nz],
            'color': [r, g, b, a],
            'uv': [u, v],
        })

    return vertices


def triangulate_strip(vertices: list[dict]) -> list[int]:
    """Convert a triangle strip to triangle list indices.

    Triangle strip: v0,v1,v2 → (0,1,2), then alternating winding.
    Degenerate triangles (duplicate vertices) act as strip restarts.
    """
    if len(vertices) < 3:
        return []

    indices = []
    for i in range(len(vertices) - 2):
        i0, i1, i2 = i, i + 1, i + 2

        # Skip degenerate triangles (same position = strip restart)
        p0 = vertices[i0]['position']
        p1 = vertices[i1]['position']
        p2 = vertices[i2]['position']

        if p0 == p1 or p1 == p2 or p0 == p2:
            continue

        # Alternate winding for consistent face normals
        if i % 2 == 0:
            indices.extend([i0, i1, i2])
        else:
            indices.extend([i0, i2, i1])

    return indices


# ---------------------------------------------------------------------------
# Coordinate transform: DirectX (LH, Y-up) → Godot (RH, Y-up)
# ---------------------------------------------------------------------------

def dx_to_godot_position(pos: list[float]) -> list[float]:
    """Convert DirectX left-handed to Godot right-handed coords.

    DirectX: +X right, +Y up, +Z into screen
    Godot:   +X right, +Y up, +Z out of screen

    Transform: negate Z axis.
    """
    return [pos[0], pos[1], -pos[2]]


def dx_to_godot_normal(n: list[float]) -> list[float]:
    """Convert normal from DirectX to Godot coordinate system."""
    return [n[0], n[1], -n[2]]


# ---------------------------------------------------------------------------
# Full NIL parse
# ---------------------------------------------------------------------------

def parse_nil(data: bytes, godot_coords: bool = True) -> dict | None:
    """Parse a complete NIL file into structured mesh data.

    Returns a dict with header info and mesh groups ready for rendering.
    """
    header = parse_nil_header(data)
    if header is None:
        return None

    # Find all vertex blocks
    blocks = find_vertex_blocks(data, header['data_start'])
    if not blocks:
        return None

    # Extract mesh groups from vertex blocks
    mesh_groups = []
    total_verts = 0
    total_tris = 0

    for bi, block in enumerate(blocks):
        vertices = extract_vertices(data, block['offset'], block['count'])

        # Apply coordinate transform if requested
        if godot_coords:
            for v in vertices:
                v['position'] = dx_to_godot_position(v['position'])
                v['normal'] = dx_to_godot_normal(v['normal'])

        # Triangulate the strip
        indices = triangulate_strip(vertices)

        if not indices:
            continue

        # Compute bounding box
        xs = [v['position'][0] for v in vertices]
        ys = [v['position'][1] for v in vertices]
        zs = [v['position'][2] for v in vertices]

        # Determine dominant vertex color (used as material hint)
        color_counts = {}
        for v in vertices:
            c = tuple(v['color'][:3])
            color_counts[c] = color_counts.get(c, 0) + 1
        dominant_color = max(color_counts, key=color_counts.get) if color_counts else (128, 128, 128)

        mesh_groups.append({
            'id': bi,
            'vertex_count': len(vertices),
            'triangle_count': len(indices) // 3,
            'vertices': vertices,
            'indices': indices,
            'bbox_min': [min(xs), min(ys), min(zs)],
            'bbox_max': [max(xs), max(ys), max(zs)],
            'dominant_color': list(dominant_color),
            'offset': f'0x{block["offset"]:X}',
        })

        total_verts += len(vertices)
        total_tris += len(indices) // 3

    # Compute level bounding box
    all_min = [
        min(mg['bbox_min'][i] for mg in mesh_groups)
        for i in range(3)
    ]
    all_max = [
        max(mg['bbox_max'][i] for mg in mesh_groups)
        for i in range(3)
    ]

    return {
        'header': {
            'magic': header['magic'],
            'section_count': header['section_count'],
            'material_count': header['material_count'],
            'materials': header['materials'],
        },
        'stats': {
            'mesh_groups': len(mesh_groups),
            'total_vertices': total_verts,
            'total_triangles': total_tris,
            'bbox_min': all_min,
            'bbox_max': all_max,
        },
        'mesh_groups': mesh_groups,
    }


# ---------------------------------------------------------------------------
# JSON output (for Godot level loader)
# ---------------------------------------------------------------------------

def export_json(parsed: dict, output_path: Path, compact: bool = False):
    """Export parsed NIL data as JSON for the Godot level loader.

    In compact mode, vertices are stored as flat arrays for efficiency.
    """
    if compact:
        # Convert vertex dicts to flat arrays for smaller JSON
        for mg in parsed['mesh_groups']:
            positions = []
            normals = []
            colors = []
            uvs = []
            for v in mg['vertices']:
                positions.extend(v['position'])
                normals.extend(v['normal'])
                colors.extend(v['color'])
                uvs.extend(v['uv'])
            mg['positions'] = positions
            mg['normals'] = normals
            mg['colors'] = colors
            mg['uvs'] = uvs
            del mg['vertices']

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, 'w') as f:
        json.dump(parsed, f, indent=None if compact else 2)

    size = output_path.stat().st_size
    print(f"Wrote {output_path} ({size / 1024:.1f} KB)")


# ---------------------------------------------------------------------------
# glTF output (for direct Godot import)
# ---------------------------------------------------------------------------

def export_gltf(parsed: dict, output_path: Path):
    """Export parsed NIL level geometry as a single glTF 2.0 file.

    Merges all mesh groups into one mesh with multiple primitives.
    """
    all_positions = []
    all_normals = []
    all_uvs = []
    all_colors = []
    all_indices = []

    vtx_offset = 0

    for mg in parsed['mesh_groups']:
        for v in mg['vertices']:
            all_positions.append(v['position'])
            all_normals.append(v['normal'])
            all_uvs.append(v['uv'])
            # Convert RGBA 0-255 to 0.0-1.0 for glTF
            c = v['color']
            all_colors.append([c[0] / 255.0, c[1] / 255.0, c[2] / 255.0, c[3] / 255.0])

        for idx in mg['indices']:
            all_indices.append(idx + vtx_offset)

        vtx_offset += len(mg['vertices'])

    if not all_positions:
        print("ERROR: No geometry to export")
        return

    vcount = len(all_positions)
    icount = len(all_indices)

    # Build binary buffers
    pos_bytes = b''.join(struct.pack('<3f', *p) for p in all_positions)
    normal_bytes = b''.join(struct.pack('<3f', *n) for n in all_normals)
    uv_bytes = b''.join(struct.pack('<2f', *uv) for uv in all_uvs)
    color_bytes = b''.join(struct.pack('<4f', *c) for c in all_colors)

    if vcount > 65535:
        idx_bytes = b''.join(struct.pack('<I', i) for i in all_indices)
        idx_component = 5125  # UNSIGNED_INT
    else:
        idx_bytes = b''.join(struct.pack('<H', i) for i in all_indices)
        idx_component = 5123  # UNSIGNED_SHORT

    # Pad to 4 bytes
    def pad4(b):
        r = len(b) % 4
        return b + b'\x00' * (4 - r) if r else b

    pos_bytes = pad4(pos_bytes)
    normal_bytes = pad4(normal_bytes)
    uv_bytes = pad4(uv_bytes)
    color_bytes = pad4(color_bytes)
    idx_bytes = pad4(idx_bytes)

    blob = pos_bytes + normal_bytes + uv_bytes + color_bytes + idx_bytes
    b64 = base64.b64encode(blob).decode('ascii')

    # Position bounds
    xs = [p[0] for p in all_positions]
    ys = [p[1] for p in all_positions]
    zs = [p[2] for p in all_positions]

    off_pos = 0
    off_norm = len(pos_bytes)
    off_uv = off_norm + len(normal_bytes)
    off_col = off_uv + len(uv_bytes)
    off_idx = off_col + len(color_bytes)

    name = output_path.stem

    gltf = {
        "asset": {
            "version": "2.0",
            "generator": "ghost_port nil_parser.py",
            "extras": {
                "source": "StarCraft: Ghost NIL level",
                "materials": parsed['header']['materials'],
                "mesh_groups": parsed['stats']['mesh_groups'],
                "total_vertices": vcount,
                "total_triangles": icount // 3,
            }
        },
        "scene": 0,
        "scenes": [{"name": name, "nodes": [0]}],
        "nodes": [{"name": name, "mesh": 0}],
        "meshes": [{
            "name": f"{name}_mesh",
            "primitives": [{
                "attributes": {
                    "POSITION": 0,
                    "NORMAL": 1,
                    "TEXCOORD_0": 2,
                    "COLOR_0": 3,
                },
                "indices": 4,
                "mode": 4,  # TRIANGLES
            }]
        }],
        "buffers": [{
            "uri": f"data:application/octet-stream;base64,{b64}",
            "byteLength": len(blob),
        }],
        "bufferViews": [
            {"buffer": 0, "byteOffset": off_pos, "byteLength": len(pos_bytes),
             "target": 34962, "byteStride": 12},
            {"buffer": 0, "byteOffset": off_norm, "byteLength": len(normal_bytes),
             "target": 34962, "byteStride": 12},
            {"buffer": 0, "byteOffset": off_uv, "byteLength": len(uv_bytes),
             "target": 34962, "byteStride": 8},
            {"buffer": 0, "byteOffset": off_col, "byteLength": len(color_bytes),
             "target": 34962, "byteStride": 16},
            {"buffer": 0, "byteOffset": off_idx, "byteLength": len(idx_bytes),
             "target": 34963},
        ],
        "accessors": [
            {"bufferView": 0, "componentType": 5126, "count": vcount,
             "type": "VEC3",
             "min": [min(xs), min(ys), min(zs)],
             "max": [max(xs), max(ys), max(zs)]},
            {"bufferView": 1, "componentType": 5126, "count": vcount,
             "type": "VEC3"},
            {"bufferView": 2, "componentType": 5126, "count": vcount,
             "type": "VEC2"},
            {"bufferView": 3, "componentType": 5126, "count": vcount,
             "type": "VEC4"},
            {"bufferView": 4, "componentType": idx_component, "count": icount,
             "type": "SCALAR"},
        ],
    }

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, 'w') as f:
        json.dump(gltf, f)

    size = output_path.stat().st_size
    print(f"Wrote {output_path} ({size / 1024 / 1024:.1f} MB)")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description='Parse StarCraft Ghost NIL level files')
    parser.add_argument('--input', '-i', required=True,
                        help='Input .nil file')
    parser.add_argument('--output', '-o', required=True,
                        help='Output file (.json or .gltf)')
    parser.add_argument('--format', choices=['json', 'json-compact', 'gltf'],
                        default=None,
                        help='Output format (auto-detected from extension)')
    parser.add_argument('--no-transform', action='store_true',
                        help='Keep DirectX coordinates (skip Godot transform)')
    parser.add_argument('--min-verts', type=int, default=3,
                        help='Minimum vertices per block (default: 3)')
    parser.add_argument('--stats', action='store_true',
                        help='Print statistics only, no output file')
    args = parser.parse_args()

    input_path = Path(args.input)
    output_path = Path(args.output)

    if not input_path.exists():
        print(f"ERROR: {input_path} not found")
        sys.exit(1)

    print(f"Parsing {input_path.name} ({input_path.stat().st_size / 1024:.0f} KB)...")

    data = input_path.read_bytes()
    parsed = parse_nil(data, godot_coords=not args.no_transform)

    if parsed is None:
        print("ERROR: Failed to parse NIL file")
        sys.exit(1)

    # Print stats
    stats = parsed['stats']
    header = parsed['header']
    print(f"  Materials: {header['material_count']}")
    print(f"  Mesh groups: {stats['mesh_groups']}")
    print(f"  Total vertices: {stats['total_vertices']:,}")
    print(f"  Total triangles: {stats['total_triangles']:,}")
    print(f"  Bounding box: ({stats['bbox_min'][0]:.0f},{stats['bbox_min'][1]:.0f},{stats['bbox_min'][2]:.0f}) "
          f"to ({stats['bbox_max'][0]:.0f},{stats['bbox_max'][1]:.0f},{stats['bbox_max'][2]:.0f})")

    if args.stats:
        # Just print material list and exit
        print(f"\n  Materials ({len(header['materials'])}):")
        for i, m in enumerate(header['materials']):
            print(f"    {i:2d}: {m}")
        return

    # Determine format
    fmt = args.format
    if fmt is None:
        ext = output_path.suffix.lower()
        if ext == '.gltf':
            fmt = 'gltf'
        elif ext == '.json':
            fmt = 'json'
        else:
            fmt = 'json'

    # Export
    if fmt == 'gltf':
        export_gltf(parsed, output_path)
    elif fmt == 'json-compact':
        export_json(parsed, output_path, compact=True)
    else:
        export_json(parsed, output_path, compact=False)

    print("Done!")


if __name__ == '__main__':
    main()
