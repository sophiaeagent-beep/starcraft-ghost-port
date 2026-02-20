#!/usr/bin/env python3
"""
XPR Texture Extractor for StarCraft: Ghost
==========================================
Extracts DDS textures from Nihilistic Software's XPR1 (Xbox Packed Resource) files.

XPR1 Format (reverse-engineered):
  Header: "XPR1"(4) + totalSize(4) + headerSize(4)     [12 bytes]
  Body (offset 12):
    count(4)
    count × (nameOffset(4), descOffset(4))              [8 bytes each]
    Null-terminated texture name strings
    count × D3DTexture(Common(4), Data(4), Lock(4), Format(4), Size(4))  [20 bytes each]
  Pixel data starts at file offset = headerSize

All internal offsets are relative to byte 12 (start of body).

Usage:
    python3 xpr_texture_extractor.py --input file.xpr --output textures/
    python3 xpr_texture_extractor.py --input file.xpr --list
"""

import argparse
import os
import struct
import sys

# Xbox D3D format codes
D3DFMT_NAMES = {
    0x04: ('A1R5G5B5', 2, False),
    0x05: ('R5G6B5', 2, False),
    0x06: ('A8R8G8B8', 4, False),
    0x07: ('X8R8G8B8', 4, False),
    0x0B: ('P8', 1, False),
    0x0C: ('DXT1', 0, True),
    0x0E: ('DXT3', 0, True),
    0x0F: ('DXT5', 0, True),
    0x11: ('A8', 1, False),
    0x19: ('L8', 1, False),
    0x1A: ('A8L8', 2, False),
}

# DDS file header constants
DDS_MAGIC = 0x20534444  # "DDS "
DDSD_CAPS = 0x1
DDSD_HEIGHT = 0x2
DDSD_WIDTH = 0x4
DDSD_PIXELFORMAT = 0x1000
DDSD_MIPMAPCOUNT = 0x20000
DDSD_LINEARSIZE = 0x80000
DDPF_FOURCC = 0x4
DDPF_RGB = 0x40
DDPF_ALPHAPIXELS = 0x1
DDSCAPS_TEXTURE = 0x1000
DDSCAPS_MIPMAP = 0x400000
DDSCAPS_COMPLEX = 0x8

BASE_OFFSET = 12  # All XPR internal offsets are relative to this


def parse_xpr(data):
    """Parse XPR1 file and return list of texture entries."""
    if data[0:4] != b'XPR1':
        raise ValueError(f"Not an XPR1 file (magic: {data[0:4]})")

    total_size = struct.unpack_from('<I', data, 4)[0]
    header_size = struct.unpack_from('<I', data, 8)[0]
    count = struct.unpack_from('<I', data, BASE_OFFSET)[0]

    textures = []
    for i in range(count):
        table_off = 16 + i * 8  # 16 = BASE_OFFSET + 4 (count field)
        name_off, desc_off = struct.unpack_from('<II', data, table_off)

        # Read name (offset relative to BASE_OFFSET)
        abs_name = name_off + BASE_OFFSET
        end = data.index(0, abs_name)
        name = data[abs_name:end].decode('ascii', errors='replace')

        # Read D3D texture descriptor (20 bytes)
        abs_desc = desc_off + BASE_OFFSET
        common, pix_data_off, lock, fmt, size_field = struct.unpack_from('<5I', data, abs_desc)

        # Decode format field
        tex_format_code = (fmt >> 8) & 0xFF
        mip_levels = (fmt >> 16) & 0xF
        ulog2_w = (fmt >> 20) & 0xF
        ulog2_h = (fmt >> 24) & 0xF

        # Dimensions
        if ulog2_w > 0:
            width = 1 << ulog2_w
        else:
            width = (size_field & 0xFFF) + 1

        if ulog2_h > 0:
            height = 1 << ulog2_h
        else:
            height = ((size_field >> 12) & 0xFFF) + 1

        # Format info
        fmt_info = D3DFMT_NAMES.get(tex_format_code)
        if fmt_info:
            fmt_name, bpp, is_compressed = fmt_info
        else:
            fmt_name = f'UNK_0x{tex_format_code:02X}'
            bpp = 4
            is_compressed = False

        # Calculate pixel data size (level 0 only for extraction)
        if is_compressed:
            block_w = max(1, width // 4)
            block_h = max(1, height // 4)
            block_size = 8 if tex_format_code == 0x0C else 16  # DXT1=8, DXT3/5=16
            level0_size = block_w * block_h * block_size
        else:
            level0_size = width * height * bpp

        # Total size with mipmaps
        total_tex_size = 0
        mw, mh = width, height
        for m in range(max(1, mip_levels)):
            if is_compressed:
                bw = max(1, mw // 4)
                bh = max(1, mh // 4)
                bs = 8 if tex_format_code == 0x0C else 16
                total_tex_size += bw * bh * bs
            else:
                total_tex_size += max(1, mw) * max(1, mh) * bpp
            mw = max(1, mw // 2)
            mh = max(1, mh // 2)

        textures.append({
            'index': i,
            'name': name,
            'width': width,
            'height': height,
            'format_code': tex_format_code,
            'format_name': fmt_name,
            'is_compressed': is_compressed,
            'bpp': bpp,
            'mip_levels': mip_levels,
            'pixel_offset': pix_data_off,  # Relative to data section
            'data_section_start': header_size,  # Absolute file offset
            'level0_size': level0_size,
            'total_size': total_tex_size,
        })

    return textures


def build_dds_header(tex):
    """Build a DDS file header for extraction."""
    width = tex['width']
    height = tex['height']
    mips = tex['mip_levels']
    fmt_code = tex['format_code']
    is_compressed = tex['is_compressed']

    flags = DDSD_CAPS | DDSD_HEIGHT | DDSD_WIDTH | DDSD_PIXELFORMAT
    caps = DDSCAPS_TEXTURE

    if mips > 1:
        flags |= DDSD_MIPMAPCOUNT
        caps |= DDSCAPS_MIPMAP | DDSCAPS_COMPLEX

    # Pixel format
    pf_size = 32
    pf_flags = 0
    pf_fourcc = 0
    pf_rgbbits = 0
    pf_rmask = 0
    pf_gmask = 0
    pf_bmask = 0
    pf_amask = 0
    pitch_or_linear = 0

    if is_compressed:
        pf_flags = DDPF_FOURCC
        flags |= DDSD_LINEARSIZE
        if fmt_code == 0x0C:
            pf_fourcc = 0x31545844  # "DXT1"
            block_size = 8
        elif fmt_code == 0x0E:
            pf_fourcc = 0x33545844  # "DXT3"
            block_size = 16
        elif fmt_code == 0x0F:
            pf_fourcc = 0x35545844  # "DXT5"
            block_size = 16
        else:
            pf_fourcc = 0x31545844  # Default DXT1
            block_size = 8
        pitch_or_linear = max(1, width // 4) * max(1, height // 4) * block_size
    else:
        pf_flags = DDPF_RGB
        bpp = tex['bpp']
        pf_rgbbits = bpp * 8
        if fmt_code == 0x06:  # A8R8G8B8
            pf_flags |= DDPF_ALPHAPIXELS
            pf_rmask = 0x00FF0000
            pf_gmask = 0x0000FF00
            pf_bmask = 0x000000FF
            pf_amask = 0xFF000000
        elif fmt_code == 0x07:  # X8R8G8B8
            pf_rmask = 0x00FF0000
            pf_gmask = 0x0000FF00
            pf_bmask = 0x000000FF
        elif fmt_code == 0x05:  # R5G6B5
            pf_rmask = 0xF800
            pf_gmask = 0x07E0
            pf_bmask = 0x001F
        pitch_or_linear = width * bpp

    # Build the 128-byte DDS header
    header = struct.pack('<I', DDS_MAGIC)  # "DDS "
    header += struct.pack('<I', 124)  # Header size (after magic)
    header += struct.pack('<I', flags)
    header += struct.pack('<I', height)
    header += struct.pack('<I', width)
    header += struct.pack('<I', pitch_or_linear)
    header += struct.pack('<I', 0)  # Depth
    header += struct.pack('<I', max(1, mips))  # Mipmap count
    header += b'\x00' * 44  # Reserved
    # Pixel format
    header += struct.pack('<I', pf_size)
    header += struct.pack('<I', pf_flags)
    header += struct.pack('<I', pf_fourcc)
    header += struct.pack('<I', pf_rgbbits)
    header += struct.pack('<I', pf_rmask)
    header += struct.pack('<I', pf_gmask)
    header += struct.pack('<I', pf_bmask)
    header += struct.pack('<I', pf_amask)
    # Caps
    header += struct.pack('<I', caps)
    header += b'\x00' * 12  # Caps2-4

    return header


def unswizzle_xbox_texture(data, width, height, bpp):
    """Unswizzle Xbox texture data (Morton/Z-order curve).
    Xbox GPU stores uncompressed textures in swizzled (Morton) order for cache efficiency.
    DXT textures are NOT swizzled (they're already block-organized).
    """
    result = bytearray(len(data))
    pixels = width * height

    for i in range(pixels):
        # Morton decode: interleave bits of x and y
        x = 0
        y = 0
        bit = 0
        val = i
        while val > 0:
            x |= (val & 1) << bit
            val >>= 1
            y |= (val & 1) << bit
            val >>= 1
            bit += 1

        if x < width and y < height:
            src = i * bpp
            dst = (y * width + x) * bpp
            if src + bpp <= len(data) and dst + bpp <= len(result):
                result[dst:dst + bpp] = data[src:src + bpp]

    return bytes(result)


def extract_texture(data, tex, output_dir, unswizzle=True):
    """Extract a single texture from XPR data as a DDS file."""
    name = tex['name']
    abs_pixel_start = tex['data_section_start'] + tex['pixel_offset']

    # Extract pixel data (all mip levels)
    pixel_data = data[abs_pixel_start:abs_pixel_start + tex['total_size']]

    if len(pixel_data) < tex['total_size']:
        print(f"  WARNING: {name} truncated ({len(pixel_data)}/{tex['total_size']} bytes)")
        pixel_data += b'\x00' * (tex['total_size'] - len(pixel_data))

    # Unswizzle non-compressed textures (Xbox stores them in Morton order)
    if not tex['is_compressed'] and unswizzle:
        pixel_data = unswizzle_xbox_texture(
            pixel_data[:tex['level0_size']],
            tex['width'], tex['height'], tex['bpp']
        )

    # Build DDS header + pixel data
    dds_header = build_dds_header(tex)
    dds_data = dds_header + pixel_data

    # Write DDS file
    out_path = os.path.join(output_dir, f"{name}.dds")
    with open(out_path, 'wb') as f:
        f.write(dds_data)

    return out_path


def main():
    parser = argparse.ArgumentParser(description='Extract textures from XPR1 files')
    parser.add_argument('--input', '-i', required=True, help='Input XPR file')
    parser.add_argument('--output', '-o', help='Output directory for DDS files')
    parser.add_argument('--list', '-l', action='store_true', help='List textures only')
    parser.add_argument('--filter', '-f', help='Extract only textures matching this prefix')
    parser.add_argument('--no-unswizzle', action='store_true', help='Skip unswizzle for raw formats')
    args = parser.parse_args()

    with open(args.input, 'rb') as f:
        data = f.read()

    textures = parse_xpr(data)
    xpr_name = os.path.basename(args.input)

    if args.list:
        print(f"\n{xpr_name}: {len(textures)} textures\n")
        print(f"{'#':>3}  {'Name':35s}  {'Size':>10}  {'Format':10s}  {'Mips':>4}  {'DataOff':>8}  {'Bytes':>8}")
        print("-" * 95)
        total_bytes = 0
        for tex in textures:
            size_str = f"{tex['width']}x{tex['height']}"
            print(f"{tex['index']:3d}  {tex['name']:35s}  {size_str:>10}  {tex['format_name']:10s}  {tex['mip_levels']:4d}  0x{tex['pixel_offset']:06X}  {tex['total_size']:8,}")
            total_bytes += tex['total_size']
        print(f"\nTotal pixel data: {total_bytes:,} bytes ({total_bytes/1024/1024:.1f} MB)")
        return

    if not args.output:
        print("Error: --output required for extraction (or use --list)")
        sys.exit(1)

    os.makedirs(args.output, exist_ok=True)

    extracted = 0
    for tex in textures:
        if args.filter and not tex['name'].lower().startswith(args.filter.lower()):
            continue

        out_path = extract_texture(data, tex, args.output, unswizzle=not args.no_unswizzle)
        print(f"  [{tex['index']:2d}] {tex['name']:35s} {tex['width']:4d}x{tex['height']:<4d} {tex['format_name']} -> {os.path.basename(out_path)}")
        extracted += 1

    print(f"\nExtracted {extracted} textures to {args.output}/")


if __name__ == '__main__':
    main()
