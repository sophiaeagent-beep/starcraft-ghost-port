#!/usr/bin/env python3
"""
NSA Shader Parser for StarCraft: Ghost
=======================================
Parses Nihilistic Software .NSA shader definition files to extract
material → texture name mappings.

NSA Format (text-based):
  MaterialName
  {
      shader <type>      # alpha, masked, glow, glossenvmap, etc.
      texture <name>     # Primary texture name
      texture2 <name>    # Secondary texture (for blend shaders)
      glow <name>        # Glow map texture
      envmap <name>      # Environment map texture
      detail <name>      # Detail texture
      sound <type>       # Footstep sound (dirt, metal, etc.)
  }

Usage:
    python3 nsa_parser.py --input level.nsa --output texture_map.json
    python3 nsa_parser.py --input level.nsa --list
"""

import argparse
import json
import os
import re
import sys
from pathlib import Path


def parse_nsa(text: str) -> dict:
    """Parse NSA shader definitions into material→texture mappings.

    Returns dict with:
      materials: {name: {shader, texture, texture2, glow, envmap, detail, sound}}
      texture_map: {material_name: primary_texture_name}
    """
    materials = {}
    texture_map = {}

    # Parse the block structure: Name { ... }
    lines = text.split('\n')
    i = 0
    while i < len(lines):
        line = lines[i].strip()

        # Skip empty lines and lines starting with //
        if not line or line.startswith('//'):
            i += 1
            continue

        # Check if next non-empty line is {
        j = i + 1
        while j < len(lines) and not lines[j].strip():
            j += 1

        if j < len(lines) and lines[j].strip() == '{':
            mat_name = line
            # Parse the block
            props = {}
            k = j + 1
            while k < len(lines):
                bline = lines[k].strip()
                if bline == '}':
                    break
                if bline and not bline.startswith('//'):
                    # Parse key-value: "key value" or "key\tvalue"
                    parts = bline.split(None, 1)
                    if len(parts) >= 2:
                        key = parts[0].lower()
                        val = parts[1].strip()
                        # Remove .dds extension if present
                        if val.endswith('.dds'):
                            val = val[:-4]
                        # Handle "volume" suffix on textures
                        if val.endswith(' volume'):
                            val = val.rsplit(' ', 1)[0]
                        props[key] = val
                    elif len(parts) == 1:
                        # Flag-style properties (e.g., "sightForceHot")
                        props[parts[0].lower()] = True
                k += 1

            # Store material properties
            materials[mat_name] = props

            # Build texture map (material name → primary texture name)
            if 'texture' in props and props['texture'] != 'dflt':
                tex_name = props['texture']
                # Remove path prefix if present (e.g., "common/GE_grate_01")
                if '/' in tex_name:
                    tex_name = tex_name.split('/')[-1]
                if '\\' in tex_name:
                    tex_name = tex_name.split('\\')[-1]
                texture_map[mat_name] = tex_name

            i = k + 1
        else:
            i += 1

    return {
        'materials': materials,
        'texture_map': texture_map,
    }


def main():
    parser = argparse.ArgumentParser(description='Parse NSA shader files')
    parser.add_argument('--input', '-i', required=True, help='Input .nsa file')
    parser.add_argument('--output', '-o', help='Output JSON file')
    parser.add_argument('--list', '-l', action='store_true', help='List mappings')
    args = parser.parse_args()

    text = Path(args.input).read_text(errors='replace')
    result = parse_nsa(text)

    if args.list:
        print(f"\n{Path(args.input).name}: {len(result['texture_map'])} material→texture mappings\n")
        print(f"{'Material':40s} → {'Texture':35s}  {'Shader':15s}")
        print("-" * 95)
        for mat_name, tex_name in sorted(result['texture_map'].items()):
            shader = result['materials'].get(mat_name, {}).get('shader', '?')
            same = '=' if mat_name == tex_name else '→'
            print(f"{mat_name:40s} {same} {tex_name:35s}  {shader}")
        return

    if args.output:
        Path(args.output).parent.mkdir(parents=True, exist_ok=True)
        with open(args.output, 'w') as f:
            json.dump(result['texture_map'], f, indent=2)
        print(f"Wrote {len(result['texture_map'])} mappings to {args.output}")
    else:
        print(json.dumps(result['texture_map'], indent=2))


if __name__ == '__main__':
    main()
