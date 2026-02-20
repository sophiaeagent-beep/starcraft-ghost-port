#!/usr/bin/env python3
"""
NOD-to-glTF Converter for StarCraft: Ghost Xbox assets.

Converts Nihilistic Software .NOD binary mesh files to glTF 2.0 format.
Based on proven parsing from RenolY2/scg-modeldump (read_nod.py).

NOD Format (version 0xA):
  Header (0x5C bytes):
    0x00: u32 version (must be 10 / 0xA)
    0x04: u8 shaderCount, u8 boneCount, u8 vertGroupCount, u8 meshGroupCount
    0x08: u32 flags
    0x0C: float[6] bounding box (min xyz, max xyz)
    0x24: 4x vertex group slots (u8 vtxtype + 3 pad + u32 vtxcount = 8 bytes each)
    0x44: u32 indexCount
    0x48: u32[4] lodStarts
    0x58: u8 lodCount + padding to 0x5C

  Then: shader names (shaderCount * 0x20 bytes, null-padded ASCII)
  Then: bones (boneCount * 0x40 bytes each)
  Then: vertex data (per vertex group, type determines stride)
  Then: index buffer (indexCount * u16)
  Then: mesh group descriptors (meshGroupCount * 0x38 bytes)

  Vertex types:
    Type 0/3: 0x20 (32 bytes) = pos(3f) + normal(3f) + uv(2f)
    Type 1:   0x24 (36 bytes) = pos(3f) + normal(3f) + uv(2f) + 4 extra bytes
    Type 2:   0x30 (48 bytes) = pos(3f) + normal(3f) + uv(2f) + 16 extra bytes

  MeshGroupFile (0x38 bytes):
    u32 materialid
    4x LOD: u16 stripCount + u16 listCount + u16 vtxCount (6 bytes each = 24 bytes)
    u16 vertexCount
    u8 groupFlags, u8 blendShapeCount, u8 blendGroup
    20 bytes bones
    u8 boneCount, u8 vtxGroup, 1 byte padding
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
# Binary read helpers
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
# Vertex type strides
# ---------------------------------------------------------------------------

VERTEX_STRIDES = {
    0: 0x20,  # 32 bytes: pos(3f) + normal(3f) + uv(2f)
    1: 0x24,  # 36 bytes: + 4 unknown bytes
    2: 0x30,  # 48 bytes: + 16 unknown bytes (skinning data)
    3: 0x20,  # 32 bytes: same as type 0
}


# ---------------------------------------------------------------------------
# NOD parsing — matches scg-modeldump read_nod.py structure exactly
# ---------------------------------------------------------------------------

def parse_nod(data: bytes) -> dict | None:
    """Parse a NOD binary file into a structured dict.

    Returns None if the file is too small or has wrong magic.
    """
    if len(data) < 0x5C:
        return None

    version = read_u32(data, 0x00)
    if version != 0xA:
        return None

    shader_count = read_u8(data, 0x04)
    bone_count = read_u8(data, 0x05)
    vert_group_count = read_u8(data, 0x06)
    mesh_group_count = read_u8(data, 0x07)
    flags = read_u32(data, 0x08)

    # Bounding box: 6 floats at 0x0C
    bbox_min = struct.unpack_from('<3f', data, 0x0C)
    bbox_max = struct.unpack_from('<3f', data, 0x18)

    # 4 vertex group slots at 0x24 (8 bytes each: u8 type + 3 pad + u32 count)
    vtx_groups = []
    off = 0x24
    for i in range(4):
        vtx_type = read_u8(data, off)
        # 3 bytes padding
        vtx_count = read_u32(data, off + 4)
        vtx_groups.append((vtx_type, vtx_count))
        off += 8

    # Index count at 0x44
    index_count = read_u32(data, 0x44)

    # LOD starts at 0x48 (4 x u32)
    lod_starts = [read_u32(data, 0x48 + i * 4) for i in range(4)]

    # LOD count at 0x58
    lod_count = read_u8(data, 0x58)

    # ---- Shader names at 0x5C (shader_count * 0x20 bytes) ----
    off = 0x5C
    shaders = []
    for i in range(shader_count):
        raw = data[off:off + 0x20]
        name = raw.split(b'\x00')[0].decode('ascii', errors='ignore')
        shaders.append(name)
        off += 0x20

    # ---- Bones (bone_count * 0x40 bytes) ----
    for i in range(bone_count):
        off += 0x40  # Skip bone data for now

    # ---- Vertex data (per vertex group) ----
    all_vertices = []  # list of lists, one per vertex group

    for gi in range(vert_group_count):
        vtx_type, vtx_count = vtx_groups[gi]
        stride = VERTEX_STRIDES.get(vtx_type)
        if stride is None:
            return None  # Unknown vertex type

        group_verts = []
        for vi in range(vtx_count):
            if off + stride > len(data):
                break

            px = read_f32(data, off + 0)
            py = read_f32(data, off + 4)
            pz = read_f32(data, off + 8)
            nx = read_f32(data, off + 12)
            ny = read_f32(data, off + 16)
            nz = read_f32(data, off + 20)
            u = read_f32(data, off + 24)
            v = read_f32(data, off + 28)

            group_verts.append({
                'pos': (px, py, pz),
                'normal': (nx, ny, nz),
                'uv': (u, v),
            })
            off += stride

        all_vertices.append(group_verts)

    # ---- Index buffer (index_count * u16) ----
    indices = []
    for i in range(index_count):
        if off + 2 > len(data):
            break
        indices.append(read_u16(data, off))
        off += 2

    # ---- Mesh group descriptors (mesh_group_count * 0x38 bytes) ----
    mesh_groups = []
    accumulated_index_offset = 0

    for mi in range(mesh_group_count):
        if off + 0x38 > len(data):
            break

        mg_start = off
        material_id = read_u32(data, off)
        off += 4

        # 4 LODs, each: u16 stripCount + u16 listCount + u16 vtxCount = 6 bytes
        lods = []
        idx_offset = accumulated_index_offset
        for li in range(4):
            strip_count = read_u16(data, off)
            list_count = read_u16(data, off + 2)
            vtx_count = read_u16(data, off + 4)
            off += 6

            lod = {
                'strip_start': idx_offset,
                'strip_count': strip_count,
                'list_start': idx_offset + strip_count,
                'list_count': list_count,
                'vtx_count': vtx_count,
            }
            lods.append(lod)
            idx_offset += strip_count + list_count

        accumulated_index_offset = idx_offset

        vertex_count = read_u16(data, off)
        off += 2
        group_flags = read_u8(data, off)
        off += 1
        blend_shape_count = read_u8(data, off)
        off += 1
        blend_group = read_u8(data, off)
        off += 1
        bones_data = data[off:off + 20]
        off += 20
        mg_bone_count = read_u8(data, off)
        off += 1
        vtx_group = read_u8(data, off)
        off += 1
        off += 1  # padding

        mesh_groups.append({
            'material_id': material_id,
            'lods': lods,
            'vertex_count': vertex_count,
            'group_flags': group_flags,
            'vtx_group': vtx_group,
        })

    return {
        'version': version,
        'shader_count': shader_count,
        'bone_count': bone_count,
        'vert_group_count': vert_group_count,
        'mesh_group_count': mesh_group_count,
        'flags': flags,
        'bbox_min': bbox_min,
        'bbox_max': bbox_max,
        'vtx_groups': vtx_groups,
        'index_count': index_count,
        'shaders': shaders,
        'all_vertices': all_vertices,
        'indices': indices,
        'mesh_groups': mesh_groups,
        'raw': data,
    }


# ---------------------------------------------------------------------------
# Mesh extraction — per-mesh-group strip+list triangulation
# ---------------------------------------------------------------------------

def extract_mesh(nod: dict) -> dict | None:
    """Extract combined mesh data from all mesh groups.

    Each mesh group has its own strip and list index ranges within the flat
    index buffer. We combine all mesh groups into a single vertex+index set
    for glTF output, with vtxOffset tracking per mesh group.
    """
    all_vertices = nod['all_vertices']
    indices = nod['indices']
    mesh_groups = nod['mesh_groups']
    shaders = nod['shaders']

    if not all_vertices or not indices or not mesh_groups:
        return None

    # Flatten all vertex groups into a single list, tracking group start offsets
    flat_positions = []
    flat_normals = []
    flat_uvs = []
    vtx_group_offsets = []

    total = 0
    for gi, group in enumerate(all_vertices):
        vtx_group_offsets.append(total)
        for vert in group:
            px, py, pz = vert['pos']
            nx, ny, nz = vert['normal']
            u, v = vert['uv']

            # Sanitize
            if not all(math.isfinite(val) for val in (px, py, pz)):
                px, py, pz = 0.0, 0.0, 0.0
            if not all(math.isfinite(val) for val in (nx, ny, nz)):
                nx, ny, nz = 0.0, 1.0, 0.0
            if not all(math.isfinite(val) for val in (u, v)):
                u, v = 0.0, 0.0

            # Normalize normals
            nlen = math.sqrt(nx * nx + ny * ny + nz * nz)
            if nlen < 0.001:
                nx, ny, nz = 0.0, 1.0, 0.0
            else:
                nx, ny, nz = nx / nlen, ny / nlen, nz / nlen

            # Clamp UVs
            u = max(-10.0, min(10.0, u))
            v = max(-10.0, min(10.0, v))

            flat_positions.append((px, py, pz))
            flat_normals.append((nx, ny, nz))
            flat_uvs.append((u, v))
            total += 1

    if total < 3:
        return None

    # Triangulate each mesh group using its strip + list index ranges
    all_triangles = []
    vtx_offset = 0  # accumulated vertex offset for indexing

    for mg in mesh_groups:
        lod0 = mg['lods'][0]  # Use highest-detail LOD

        # --- Triangle strips (matches scg-modeldump sliding window) ---
        if lod0['strip_count'] > 0:
            v1 = None
            v2 = None
            v3 = None
            n = 0  # alternating winding counter

            for i in range(lod0['strip_start'],
                           lod0['strip_start'] + lod0['strip_count']):
                if i >= len(indices):
                    break

                if v1 is None:
                    v1 = indices[i]
                    continue
                elif v2 is None:
                    v2 = indices[i]
                    continue
                elif v3 is None:
                    v3 = indices[i]
                else:
                    v1 = v2
                    v2 = v3
                    v3 = indices[i]

                # Apply vertex offset for global index space
                a = v1 + vtx_offset
                b = v2 + vtx_offset
                c = v3 + vtx_offset

                # Skip degenerate triangles (strip restart markers)
                if v1 == v2 or v2 == v3 or v1 == v3:
                    n = (n + 1) % 2
                    continue

                # Bounds check
                if a >= total or b >= total or c >= total:
                    n = (n + 1) % 2
                    continue

                # Alternate winding for consistent face normals
                if n == 0:
                    all_triangles.extend([a, b, c])
                else:
                    all_triangles.extend([a, c, b])

                n = (n + 1) % 2

        # --- Triangle lists ---
        if lod0['list_count'] > 0:
            for i in range(lod0['list_count'] // 3):
                base = lod0['list_start'] + i * 3
                if base + 2 >= len(indices):
                    break

                i0 = indices[base] + vtx_offset
                i1 = indices[base + 1] + vtx_offset
                i2 = indices[base + 2] + vtx_offset

                # Bounds check
                if i0 >= total or i1 >= total or i2 >= total:
                    continue

                all_triangles.extend([i0, i1, i2])

        vtx_offset += mg['vertex_count']

    if len(all_triangles) < 3:
        return None

    return {
        'positions': flat_positions,
        'normals': flat_normals,
        'uvs': flat_uvs,
        'indices': all_triangles,
        'vertex_count': total,
        'triangle_count': len(all_triangles) // 3,
        'shaders': shaders,
        'mesh_groups': len(mesh_groups),
    }


# ---------------------------------------------------------------------------
# glTF 2.0 export
# ---------------------------------------------------------------------------

def mesh_to_gltf(mesh: dict, name: str, source_path: str = "") -> dict:
    """Convert extracted mesh data to a glTF 2.0 dictionary."""
    positions = mesh['positions']
    normals = mesh['normals']
    uvs = mesh['uvs']
    indices = mesh['indices']

    # Build binary buffers
    pos_bytes = b''.join(struct.pack('<3f', *p) for p in positions)
    normal_bytes = b''.join(struct.pack('<3f', *n) for n in normals)
    uv_bytes = b''.join(struct.pack('<2f', u, v) for u, v in uvs)

    # Use u32 indices if vertex count > 65535, else u16
    vcount = len(positions)
    icount = len(indices)

    if vcount > 65535:
        idx_bytes = b''.join(struct.pack('<I', i) for i in indices)
        idx_component_type = 5125  # UNSIGNED_INT
    else:
        idx_bytes = b''.join(struct.pack('<H', i) for i in indices)
        idx_component_type = 5123  # UNSIGNED_SHORT

    # Pad to 4-byte alignment
    def pad4(b):
        r = len(b) % 4
        return b + b'\x00' * (4 - r) if r else b

    pos_bytes = pad4(pos_bytes)
    normal_bytes = pad4(normal_bytes)
    uv_bytes = pad4(uv_bytes)
    idx_bytes = pad4(idx_bytes)

    blob = pos_bytes + normal_bytes + uv_bytes + idx_bytes
    b64 = base64.b64encode(blob).decode('ascii')

    # Compute position bounds
    xs = [p[0] for p in positions]
    ys = [p[1] for p in positions]
    zs = [p[2] for p in positions]

    pos_view_offset = 0
    normal_view_offset = len(pos_bytes)
    uv_view_offset = normal_view_offset + len(normal_bytes)
    idx_view_offset = uv_view_offset + len(uv_bytes)

    gltf = {
        "asset": {
            "version": "2.0",
            "generator": "ghost_port nod_to_gltf.py v2",
            "extras": {
                "source": source_path,
                "vertex_count": mesh['vertex_count'],
                "triangle_count": mesh['triangle_count'],
                "mesh_groups": mesh['mesh_groups'],
                "shaders": mesh['shaders'],
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
                },
                "indices": 3,
                "mode": 4,  # TRIANGLES
            }]
        }],
        "buffers": [{
            "uri": f"data:application/octet-stream;base64,{b64}",
            "byteLength": len(blob),
        }],
        "bufferViews": [
            {"buffer": 0, "byteOffset": pos_view_offset, "byteLength": len(pos_bytes),
             "target": 34962, "byteStride": 12},
            {"buffer": 0, "byteOffset": normal_view_offset, "byteLength": len(normal_bytes),
             "target": 34962, "byteStride": 12},
            {"buffer": 0, "byteOffset": uv_view_offset, "byteLength": len(uv_bytes),
             "target": 34962, "byteStride": 8},
            {"buffer": 0, "byteOffset": idx_view_offset, "byteLength": len(idx_bytes),
             "target": 34963},
        ],
        "accessors": [
            {
                "bufferView": 0, "componentType": 5126, "count": vcount,
                "type": "VEC3",
                "min": [min(xs), min(ys), min(zs)],
                "max": [max(xs), max(ys), max(zs)],
            },
            {
                "bufferView": 1, "componentType": 5126, "count": vcount,
                "type": "VEC3",
            },
            {
                "bufferView": 2, "componentType": 5126, "count": vcount,
                "type": "VEC2",
            },
            {
                "bufferView": 3, "componentType": idx_component_type, "count": icount,
                "type": "SCALAR",
            },
        ],
    }

    return gltf


def write_gltf(gltf: dict, output_path: Path):
    """Write glTF JSON to file."""
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, 'w') as f:
        json.dump(gltf, f, indent=2)


# ---------------------------------------------------------------------------
# Batch conversion
# ---------------------------------------------------------------------------

def convert_nod_file(nod_path: Path, output_dir: Path, stats: dict,
                     verbose: bool = False) -> bool:
    """Convert a single NOD file to glTF."""
    try:
        data = nod_path.read_bytes()
    except (OSError, IOError):
        stats['errors'] += 1
        return False

    nod = parse_nod(data)
    if nod is None:
        if verbose:
            print(f"  SKIP {nod_path.name}: parse failed (bad magic or too small)")
        stats['parse_fail'] += 1
        return False

    mesh = extract_mesh(nod)
    if mesh is None:
        if verbose:
            print(f"  SKIP {nod_path.name}: no valid geometry extracted")
        stats['extract_fail'] += 1
        return False

    name = nod_path.stem
    gltf = mesh_to_gltf(mesh, name, str(nod_path))

    out_path = output_dir / f"{name}.gltf"
    write_gltf(gltf, out_path)

    vtx_types = set()
    for vtype, vcount in nod['vtx_groups'][:nod['vert_group_count']]:
        if vcount > 0:
            vtx_types.add(vtype)
    type_str = '+'.join(str(t) for t in sorted(vtx_types))

    print(f"  OK  {name}: {mesh['vertex_count']} verts, {mesh['triangle_count']} tris, "
          f"{mesh['mesh_groups']} meshgrps, vtypes={type_str}")

    stats['ok'] += 1
    stats['total_verts'] += mesh['vertex_count']
    stats['total_tris'] += mesh['triangle_count']
    return True


def main():
    parser = argparse.ArgumentParser(
        description='Convert StarCraft Ghost NOD files to glTF 2.0')
    parser.add_argument('--source', required=True,
                        help='Directory containing .nod files')
    parser.add_argument('--output', required=True,
                        help='Output directory for .gltf files')
    parser.add_argument('--filter', default='',
                        help='Only convert NODs matching this substring')
    parser.add_argument('--max', type=int, default=0,
                        help='Max files to convert (0=unlimited)')
    parser.add_argument('--verbose', action='store_true',
                        help='Print detailed progress')
    args = parser.parse_args()

    source = Path(args.source)
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)

    nod_files = sorted(source.glob('*.nod')) + sorted(source.glob('*.NOD'))
    # Deduplicate (case-insensitive)
    seen = set()
    unique = []
    for f in nod_files:
        key = f.name.lower()
        if key not in seen:
            seen.add(key)
            unique.append(f)
    nod_files = unique

    if args.filter:
        filt = args.filter.lower()
        nod_files = [f for f in nod_files if filt in f.name.lower()]

    if args.max > 0:
        nod_files = nod_files[:args.max]

    print(f"Converting {len(nod_files)} NOD files from {source}")
    print(f"Output: {output}\n")

    stats = {'ok': 0, 'parse_fail': 0, 'extract_fail': 0, 'errors': 0,
             'total_verts': 0, 'total_tris': 0}

    for nod_path in nod_files:
        convert_nod_file(nod_path, output, stats, args.verbose)

    total = stats['ok'] + stats['parse_fail'] + stats['extract_fail'] + stats['errors']
    print(f"\n{'='*60}")
    print(f"Results: {stats['ok']}/{total} converted successfully")
    print(f"  Vertices: {stats['total_verts']:,}")
    print(f"  Triangles: {stats['total_tris']:,}")
    print(f"  Parse failures: {stats['parse_fail']}")
    print(f"  Extract failures: {stats['extract_fail']}")
    print(f"  Errors: {stats['errors']}")

    # Write summary manifest
    manifest = {
        'stats': stats,
        'files': [f.name for f in nod_files],
    }
    with open(output / 'conversion_manifest.json', 'w') as f:
        json.dump(manifest, f, indent=2)


if __name__ == '__main__':
    main()
