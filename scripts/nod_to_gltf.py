#!/usr/bin/env python3
"""
NOD-to-glTF Converter for StarCraft: Ghost Xbox assets.

Converts Nihilistic Software .NOD binary mesh files to glTF 2.0 format
with optional texture support via .NSA material definitions.

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
import shutil
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
# NSA material parsing and texture mapping
# ---------------------------------------------------------------------------

def parse_nsa_file(filepath: Path) -> dict:
    """Parse a single .nsa material definition file.

    Returns dict of material_name -> {param: value, ...}
    Based on scg-modeldump parse.py read_material_file().
    """
    materials = {}
    try:
        text = filepath.read_text(errors='ignore')
    except (OSError, IOError):
        return materials

    lines = text.splitlines()
    pos = [0]  # mutable for nested function

    def next_line():
        while pos[0] < len(lines):
            line = lines[pos[0]].strip()
            pos[0] += 1
            if line and not line.startswith(';') and not line.startswith('//'):
                return line
        return None

    while True:
        name = next_line()
        if name is None:
            break

        bracket = next_line()
        if bracket != '{':
            continue

        params = {}
        depth = 0
        while True:
            line = next_line()
            if line is None:
                break
            if line == '{':
                depth += 1
            elif line == '}':
                if depth > 0:
                    depth -= 1
                else:
                    break
            else:
                parts = line.split(maxsplit=1)
                if len(parts) == 2:
                    params[parts[0]] = parts[1]
                elif len(parts) == 1:
                    params[parts[0]] = None

        materials[name] = params

    return materials


def parse_all_nsa(materials_dir: Path) -> dict:
    """Parse all .nsa files in a directory.

    Returns combined dict of material_name -> {param: value, ...}
    """
    all_materials = {}
    nsa_files = sorted(materials_dir.glob('*.nsa')) + sorted(materials_dir.glob('*.NSA'))
    seen = set()
    for nsa_path in nsa_files:
        key = nsa_path.name.lower()
        if key in seen:
            continue
        seen.add(key)
        mats = parse_nsa_file(nsa_path)
        all_materials.update(mats)
    return all_materials


def find_all_textures(*search_dirs: Path) -> dict:
    """Walk directories to find all .dds texture files.

    Returns dict of filename -> full_path (case-preserved).
    """
    textures = {}
    for search_dir in search_dirs:
        if not search_dir.is_dir():
            continue
        for dds_path in search_dir.rglob('*.dds'):
            textures[dds_path.name] = dds_path
        for dds_path in search_dir.rglob('*.DDS'):
            if dds_path.name not in textures:
                textures[dds_path.name] = dds_path
    return textures


def build_material_map(nsa_materials: dict, texture_dict: dict) -> dict:
    """Build shader name -> texture path mapping.

    Uses the same case-insensitive fallback logic as scg-modeldump:
    1. Try exact texture name from NSA
    2. Try name + ".dds"
    3. Try lowercase
    4. Try lowercase + ".dds"

    Returns dict of lowercase_shader_name -> Path
    """
    lower_textures = {}
    for name, path in texture_dict.items():
        lower_textures[name.lower()] = path

    mat_map = {}
    for mat_name, params in nsa_materials.items():
        tex = params.get('texture')
        if not tex:
            continue

        if tex in texture_dict:
            mat_map[mat_name.lower()] = texture_dict[tex]
        elif tex + '.dds' in texture_dict:
            mat_map[mat_name.lower()] = texture_dict[tex + '.dds']
        elif tex.lower() in lower_textures:
            mat_map[mat_name.lower()] = lower_textures[tex.lower()]
        elif (tex.lower() + '.dds') in lower_textures:
            mat_map[mat_name.lower()] = lower_textures[tex.lower() + '.dds']

    return mat_map


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
    """Extract mesh data from all mesh groups.

    Each mesh group has its own strip and list index ranges within the flat
    index buffer. Returns combined vertex data plus per-material triangle
    index groups for textured glTF output.
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

    total = 0
    for gi, group in enumerate(all_vertices):
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

            # UV V-flip: NOD uses DirectX convention (V=0 at top),
            # glTF/OpenGL uses V=0 at bottom
            v = 1.0 - v

            flat_positions.append((px, py, pz))
            flat_normals.append((nx, ny, nz))
            flat_uvs.append((u, v))
            total += 1

    if total < 3:
        return None

    # Triangulate each mesh group, tracking per-material index groups
    all_triangles = []
    group_triangles = {}  # material_id -> list of triangle indices
    vtx_offset = 0  # accumulated vertex offset for indexing

    for mg in mesh_groups:
        mat_id = mg['material_id']
        if mat_id not in group_triangles:
            group_triangles[mat_id] = []
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
                    tri = [a, b, c]
                else:
                    tri = [a, c, b]

                all_triangles.extend(tri)
                group_triangles[mat_id].extend(tri)
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

                tri = [i0, i1, i2]
                all_triangles.extend(tri)
                group_triangles[mat_id].extend(tri)

        vtx_offset += mg['vertex_count']

    if len(all_triangles) < 3:
        return None

    return {
        'positions': flat_positions,
        'normals': flat_normals,
        'uvs': flat_uvs,
        'indices': all_triangles,
        'group_triangles': group_triangles,
        'vertex_count': total,
        'triangle_count': len(all_triangles) // 3,
        'shaders': shaders,
        'mesh_groups': len(mesh_groups),
    }


# ---------------------------------------------------------------------------
# glTF 2.0 export
# ---------------------------------------------------------------------------

def _pad4(b: bytes) -> bytes:
    """Pad bytes to 4-byte alignment."""
    r = len(b) % 4
    return b + b'\x00' * (4 - r) if r else b


def mesh_to_gltf(mesh: dict, name: str, source_path: str = "",
                 material_map: dict | None = None,
                 texture_output_dir: Path | None = None) -> dict:
    """Convert extracted mesh data to a glTF 2.0 dictionary.

    If material_map is provided, creates per-material primitives with
    texture references. Otherwise, creates a single untextured primitive.
    """
    positions = mesh['positions']
    normals = mesh['normals']
    uvs = mesh['uvs']
    shaders = mesh['shaders']
    group_triangles = mesh.get('group_triangles', {})

    vcount = len(positions)

    # Build shared vertex data buffers
    pos_bytes = _pad4(b''.join(struct.pack('<3f', *p) for p in positions))
    normal_bytes = _pad4(b''.join(struct.pack('<3f', *n) for n in normals))
    uv_bytes = _pad4(b''.join(struct.pack('<2f', u, v) for u, v in uvs))

    # Determine whether to use per-material primitives
    use_materials = (material_map is not None and len(group_triangles) > 0
                     and len(shaders) > 0)

    if use_materials:
        # Build per-material index buffers and resolve textures
        mat_groups = []  # list of (shader_name, indices_bytes, index_count)
        textures_used = []  # list of (shader_name, texture_path)
        shader_to_tex_idx = {}

        for mat_id, tri_indices in sorted(group_triangles.items()):
            if len(tri_indices) < 3:
                continue

            shader_name = shaders[mat_id] if mat_id < len(shaders) else ""

            if vcount > 65535:
                idx_bytes = b''.join(struct.pack('<I', i) for i in tri_indices)
            else:
                idx_bytes = b''.join(struct.pack('<H', i) for i in tri_indices)
            idx_bytes = _pad4(idx_bytes)

            # Check if this shader has a texture
            tex_path = None
            if shader_name and material_map:
                tex_path = material_map.get(shader_name.lower())

            if tex_path and shader_name.lower() not in shader_to_tex_idx:
                shader_to_tex_idx[shader_name.lower()] = len(textures_used)
                textures_used.append((shader_name, tex_path))

            mat_groups.append((shader_name, idx_bytes, len(tri_indices),
                               tex_path))

        if not mat_groups:
            # Fallback: no valid material groups, use combined indices
            use_materials = False

    if not use_materials:
        # Single primitive, no materials (backwards compatible)
        all_indices = mesh['indices']
        icount = len(all_indices)

        if vcount > 65535:
            idx_bytes = _pad4(b''.join(
                struct.pack('<I', i) for i in all_indices))
            idx_comp = 5125  # UNSIGNED_INT
        else:
            idx_bytes = _pad4(b''.join(
                struct.pack('<H', i) for i in all_indices))
            idx_comp = 5123  # UNSIGNED_SHORT

        blob = pos_bytes + normal_bytes + uv_bytes + idx_bytes
        b64 = base64.b64encode(blob).decode('ascii')

        xs = [p[0] for p in positions]
        ys = [p[1] for p in positions]
        zs = [p[2] for p in positions]

        gltf = {
            "asset": {
                "version": "2.0",
                "generator": "ghost_port nod_to_gltf.py v2.1",
                "extras": {
                    "source": source_path,
                    "vertex_count": mesh['vertex_count'],
                    "triangle_count": mesh['triangle_count'],
                    "mesh_groups": mesh['mesh_groups'],
                    "shaders": shaders,
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
                    "mode": 4,
                }]
            }],
            "buffers": [{
                "uri": f"data:application/octet-stream;base64,{b64}",
                "byteLength": len(blob),
            }],
            "bufferViews": [
                {"buffer": 0, "byteOffset": 0,
                 "byteLength": len(pos_bytes),
                 "target": 34962, "byteStride": 12},
                {"buffer": 0, "byteOffset": len(pos_bytes),
                 "byteLength": len(normal_bytes),
                 "target": 34962, "byteStride": 12},
                {"buffer": 0,
                 "byteOffset": len(pos_bytes) + len(normal_bytes),
                 "byteLength": len(uv_bytes),
                 "target": 34962, "byteStride": 8},
                {"buffer": 0,
                 "byteOffset": len(pos_bytes) + len(normal_bytes) +
                 len(uv_bytes),
                 "byteLength": len(idx_bytes),
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
                {"bufferView": 3, "componentType": idx_comp, "count": icount,
                 "type": "SCALAR"},
            ],
        }
        return gltf

    # --- Per-material primitives with texture references ---
    idx_comp = 5125 if vcount > 65535 else 5123  # UNSIGNED_INT or SHORT

    # Assemble binary blob: shared vertices + per-material index buffers
    blob_parts = [pos_bytes, normal_bytes, uv_bytes]
    idx_offsets = []
    for shader_name, idx_bytes, icount, tex_path in mat_groups:
        idx_offsets.append((len(b''.join(blob_parts)), len(idx_bytes), icount))
        blob_parts.append(idx_bytes)

    blob = b''.join(blob_parts)
    b64 = base64.b64encode(blob).decode('ascii')

    xs = [p[0] for p in positions]
    ys = [p[1] for p in positions]
    zs = [p[2] for p in positions]

    # Buffer views: 0=pos, 1=normal, 2=uv, then per-material index views
    buffer_views = [
        {"buffer": 0, "byteOffset": 0,
         "byteLength": len(pos_bytes),
         "target": 34962, "byteStride": 12},
        {"buffer": 0, "byteOffset": len(pos_bytes),
         "byteLength": len(normal_bytes),
         "target": 34962, "byteStride": 12},
        {"buffer": 0, "byteOffset": len(pos_bytes) + len(normal_bytes),
         "byteLength": len(uv_bytes),
         "target": 34962, "byteStride": 8},
    ]

    for bv_offset, bv_length, _ in idx_offsets:
        buffer_views.append({
            "buffer": 0, "byteOffset": bv_offset,
            "byteLength": bv_length, "target": 34963,
        })

    # Accessors: 0=pos, 1=normal, 2=uv, then per-material index accessors
    accessors = [
        {"bufferView": 0, "componentType": 5126, "count": vcount,
         "type": "VEC3",
         "min": [min(xs), min(ys), min(zs)],
         "max": [max(xs), max(ys), max(zs)]},
        {"bufferView": 1, "componentType": 5126, "count": vcount,
         "type": "VEC3"},
        {"bufferView": 2, "componentType": 5126, "count": vcount,
         "type": "VEC2"},
    ]

    for gi, (bv_offset, bv_length, icount) in enumerate(idx_offsets):
        accessors.append({
            "bufferView": 3 + gi, "componentType": idx_comp,
            "count": icount, "type": "SCALAR",
        })

    # Copy textures and build glTF image/texture/material arrays
    gltf_images = []
    gltf_textures = []
    gltf_samplers = [{
        "magFilter": 9729,   # LINEAR
        "minFilter": 9987,   # LINEAR_MIPMAP_LINEAR
        "wrapS": 10497,      # REPEAT
        "wrapT": 10497,      # REPEAT
    }]
    gltf_materials = []
    copied_textures = set()

    # Map shader name -> glTF material index
    shader_to_gltf_mat = {}

    for shader_name, idx_bytes, icount, tex_path in mat_groups:
        shader_key = shader_name.lower()

        if shader_key not in shader_to_gltf_mat:
            mat_idx = len(gltf_materials)
            shader_to_gltf_mat[shader_key] = mat_idx

            material_def = {
                "name": shader_name or f"material_{mat_idx}",
                "pbrMetallicRoughness": {
                    "metallicFactor": 0.0,
                    "roughnessFactor": 0.8,
                },
            }

            if tex_path and texture_output_dir:
                tex_filename = tex_path.name
                # Copy texture to output directory
                if tex_filename not in copied_textures:
                    texture_output_dir.mkdir(parents=True, exist_ok=True)
                    dest = texture_output_dir / tex_filename
                    try:
                        shutil.copy2(tex_path, dest)
                        copied_textures.add(tex_filename)
                    except (OSError, IOError):
                        pass

                if tex_filename in copied_textures:
                    img_idx = len(gltf_images)
                    gltf_images.append({
                        "uri": f"textures/{tex_filename}",
                    })
                    gltf_textures.append({
                        "source": img_idx,
                        "sampler": 0,
                    })
                    material_def["pbrMetallicRoughness"]["baseColorTexture"] = {
                        "index": len(gltf_textures) - 1,
                    }

            gltf_materials.append(material_def)

    # Build primitives (all share vertex attributes, differ in indices+material)
    primitives = []
    for gi, (shader_name, idx_bytes, icount, tex_path) in enumerate(mat_groups):
        shader_key = shader_name.lower()
        prim = {
            "attributes": {
                "POSITION": 0,
                "NORMAL": 1,
                "TEXCOORD_0": 2,
            },
            "indices": 3 + gi,  # index accessor
            "mode": 4,  # TRIANGLES
        }
        if shader_key in shader_to_gltf_mat:
            prim["material"] = shader_to_gltf_mat[shader_key]
        primitives.append(prim)

    gltf = {
        "asset": {
            "version": "2.0",
            "generator": "ghost_port nod_to_gltf.py v2.1",
            "extras": {
                "source": source_path,
                "vertex_count": mesh['vertex_count'],
                "triangle_count": mesh['triangle_count'],
                "mesh_groups": mesh['mesh_groups'],
                "shaders": shaders,
                "textures_resolved": len(copied_textures),
            }
        },
        "scene": 0,
        "scenes": [{"name": name, "nodes": [0]}],
        "nodes": [{"name": name, "mesh": 0}],
        "meshes": [{
            "name": f"{name}_mesh",
            "primitives": primitives,
        }],
        "buffers": [{
            "uri": f"data:application/octet-stream;base64,{b64}",
            "byteLength": len(blob),
        }],
        "bufferViews": buffer_views,
        "accessors": accessors,
    }

    if gltf_materials:
        gltf["materials"] = gltf_materials
    if gltf_samplers and gltf_textures:
        gltf["samplers"] = gltf_samplers
    if gltf_textures:
        gltf["textures"] = gltf_textures
    if gltf_images:
        gltf["images"] = gltf_images

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
                     verbose: bool = False,
                     material_map: dict | None = None) -> bool:
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

    # Set up texture output directory if materials are available
    texture_output_dir = None
    if material_map:
        texture_output_dir = output_dir / 'textures'

    gltf = mesh_to_gltf(mesh, name, str(nod_path),
                         material_map=material_map,
                         texture_output_dir=texture_output_dir)

    out_path = output_dir / f"{name}.gltf"
    write_gltf(gltf, out_path)

    vtx_types = set()
    for vtype, vcount in nod['vtx_groups'][:nod['vert_group_count']]:
        if vcount > 0:
            vtx_types.add(vtype)
    type_str = '+'.join(str(t) for t in sorted(vtx_types))

    # Count resolved textures for this model
    tex_count = gltf.get('asset', {}).get('extras', {}).get(
        'textures_resolved', 0)
    tex_str = f", {tex_count} tex" if tex_count else ""

    print(f"  OK  {name}: {mesh['vertex_count']} verts, "
          f"{mesh['triangle_count']} tris, "
          f"{mesh['mesh_groups']} meshgrps, vtypes={type_str}{tex_str}")

    stats['ok'] += 1
    stats['total_verts'] += mesh['vertex_count']
    stats['total_tris'] += mesh['triangle_count']
    if tex_count:
        stats['textured'] = stats.get('textured', 0) + 1
    return True


def main():
    parser = argparse.ArgumentParser(
        description='Convert StarCraft Ghost NOD files to glTF 2.0')
    parser.add_argument('--source', required=True,
                        help='Directory containing .nod files')
    parser.add_argument('--output', required=True,
                        help='Output directory for .gltf files')
    parser.add_argument('--materials', default='',
                        help='Directory containing .nsa material files')
    parser.add_argument('--textures', nargs='*', default=[],
                        help='Directories to search for .dds textures')
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

    # Build material map if --materials is provided
    material_map = None
    if args.materials:
        mat_dir = Path(args.materials)
        if mat_dir.is_dir():
            print(f"Parsing materials from {mat_dir}...")
            nsa_materials = parse_all_nsa(mat_dir)
            print(f"  Found {len(nsa_materials)} material definitions")

            # Build texture search dirs
            tex_dirs = [Path(d) for d in args.textures] if args.textures else []
            # Also search the materials directory itself and its parent
            tex_dirs.append(mat_dir)
            if mat_dir.parent.is_dir():
                tex_dirs.append(mat_dir.parent)

            print(f"Searching for textures in {len(tex_dirs)} directories...")
            texture_dict = find_all_textures(*tex_dirs)
            print(f"  Found {len(texture_dict)} DDS textures")

            material_map = build_material_map(nsa_materials, texture_dict)
            print(f"  Resolved {len(material_map)} shader->texture mappings")
            print()
        else:
            print(f"WARNING: Materials directory not found: {mat_dir}")

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
             'total_verts': 0, 'total_tris': 0, 'textured': 0}

    for nod_path in nod_files:
        convert_nod_file(nod_path, output, stats, args.verbose,
                         material_map=material_map)

    total = stats['ok'] + stats['parse_fail'] + stats['extract_fail'] + stats['errors']
    print(f"\n{'='*60}")
    print(f"Results: {stats['ok']}/{total} converted successfully")
    print(f"  Vertices: {stats['total_verts']:,}")
    print(f"  Triangles: {stats['total_tris']:,}")
    if material_map:
        print(f"  Textured models: {stats.get('textured', 0)}")
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
