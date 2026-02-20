# StarCraft: Ghost — Godot 4.3 Engine Port

**The game Blizzard cancelled in 2006. We're bringing it back.**

StarCraft: Ghost was a third-person stealth action game for Xbox/PS2/GameCube featuring Nova, a Terran Ghost operative. Blizzard killed it after years of development hell. In 2020, a functional Xbox dev build leaked. The internet preserved it. We're finishing the job.

This project reverse-engineers the leaked Xbox build's proprietary binary formats (NIL, NOD, NPD, NSD) and reconstructs playable levels in Godot 4.3 — because abandoned games deserve a second life, and Nihilistic Software's engineers deserved to see their work played.

## What This Does

Takes raw binary level data from a cancelled 2004 Xbox game and turns it into something you can actually walk through in 2026.

**The Pipeline:**

```
Xbox .NIL binary → nil_parser.py → JSON/glTF → Godot 4.3 ArrayMesh → Playable Level
```

- **NIL Parser** — Reverse-engineered binary format parser that extracts inline geometry (55K+ vertices per level), triangle strips, vertex colors, normals, and UVs from Nihilistic Software's proprietary level format
- **NOD-to-glTF Converter** — Extracts individual 3D models (1,391 assets) with textures, skeleton data, and skinned mesh support
- **Godot Level Loader** — Reads parsed level data and constructs full ArrayMesh geometry with per-vertex coloring, ConcavePolygonShape3D collision, and atmospheric environment
- **Player Controller** — Third-person CharacterBody3D with Nova model, orbit camera, flashlight, and physics
- **Audio Jukebox** — 2,604 extracted audio cues across all levels, playable in-engine

## Extracted Levels

| Level | File | Vertices | Triangles | Mesh Groups |
|-------|------|----------|-----------|-------------|
| Miners Bunker (1_2_1) | 3.2 MB | 55,766 | 52,319 | 226 |
| Miners Bunker A | 2.5 MB | 35,555 | 33,469 | 149 |
| Miners Bunker B | 4.2 MB | 70,170 | 66,524 | 654 |
| Hive Station Outer A | 5.6 MB | 103,187 | 95,569 | 90 |
| Hive Station Outer B | 6.8 MB | 111,223 | 104,523 | 532 |
| Threat Base Upper | 1.9 MB | 42,900 | 40,014 | 69 |
| Threat Base Upper A | 4.1 MB | 89,065 | 82,405 | 110 |
| Main Menu | 2.3 MB | 39,347 | 38,479 | 109 |

**Total: 547,213 vertices across 8 levels.** Every polygon Nihilistic's artists placed, preserved.

## NIL Binary Format

We reverse-engineered this. Nobody had documented it before.

```
Header (0x60 bytes):
  0x00: magic "NIL\x10"
  0x04: u32 mesh section count
  0x5C: u32 material name count

Material Table:
  N × 0x20 bytes (null-padded ASCII shader names)

Geometry:
  Triangle strip vertex blocks, 36-byte stride:
    float[3] position  (12 bytes)
    float[3] normal    (12 bytes)
    uint8[4] RGBA      (4 bytes) — vertex color tint
    float[2] UV        (8 bytes) — texture coordinates
```

Blocks appear at arbitrary byte alignment (not 4-byte aligned — we had to scan byte-by-byte). Degenerate triangles (repeated vertices) serve as strip restart markers. DirectX left-handed coordinates are transformed to Godot's right-handed system.

## Quick Start

**You need the game files.** We can't distribute them. You know where to find them.

```bash
# Parse a level
python3 ghost-port-tools/converters/nil_parser.py \
  --input /path/to/Levels/1_2_1_Miners_Bunker.nil \
  --output godot_stage/data/level_1_2_1.json \
  --format json-compact

# Or export directly to glTF for Blender/other viewers
python3 ghost-port-tools/converters/nil_parser.py \
  --input /path/to/Levels/1_2_1_Miners_Bunker.nil \
  --output level.gltf --format gltf

# Extract NOD models to glTF
python3 ghost-port-tools/converters/nod_to_gltf.py \
  --input /path/to/Models/nova.nod \
  --output nova.gltf

# Open in Godot 4.3
# Set main scene to res://scenes/Level_1_2_1.tscn
```

## Bootstrap Tools

The original pipeline scripts that got us from raw Xbox dump to staged Godot project:

```bash
# Stage assets from Xbox dump
python3 scripts/export_assets.py \
  --source /path/to/starcraft_ghost \
  --output out/assets_export \
  --convert-text --convert-dds --hash

# Extract symbols from XBE/MAP files
python3 scripts/extract_symbols.py \
  --xbe /path/to/GhostR.xbe \
  --map /path/to/Ghost.map \
  --output out/symbols

# Build model stubs (point-cloud + full mesh glTF)
python3 scripts/build_model_stubs.py \
  --source /path/to/3D \
  --output out/model_stubs \
  --write-gltf

# Extract audio banks (XWB/XSB → WAV)
python3 scripts/extract_audio_banks.py \
  --sounds-dir /path/to/Sounds \
  --output out/audio_bridge \
  --extract-raw --decode-pcm --decode-vgmstream

# Build Godot preview project
python3 scripts/bootstrap_godot_stage.py \
  --project godot_stage \
  --stage-mode symlink --max-models 0 --max-audio 0
```

## In-Engine Controls

| Key | Action |
|-----|--------|
| WASD | Move / fly |
| Mouse | Look |
| Shift | Sprint / fast fly |
| Space | Jump / ascend |
| P | Toggle player / free-fly camera |
| T | Flashlight |
| N | Next audio track |
| Enter | Play/stop audio |
| F | Toggle fog |
| L | Toggle shadows |
| Esc | Release mouse cursor |

## Why This Matters

Software archaeology isn't just about nostalgia. It's about respect.

Hundreds of developers at Nihilistic Software (later Naughty Dog Austin) spent years building StarCraft: Ghost. Level designers placed every vertex. Audio engineers mixed every cue. Artists painted every texture. Then a corporation decided their work wasn't worth releasing.

Twenty years later, we can read their binary formats, reconstruct their levels, and walk through the spaces they built. That's not piracy — it's preservation. The game was never sold. The studio was absorbed. The work would have been lost forever.

We remember.

## Project Structure

```
ghost-port-tools/
  converters/
    nil_parser.py         # NIL level geometry parser (reverse-engineered)
    nod_to_gltf.py        # NOD model → glTF converter
    read_nod.py           # NOD format reference parser

scripts/
  export_assets.py        # Asset staging/export manifest
  extract_symbols.py      # XBE/MAP symbol extraction
  build_model_stubs.py    # Model metadata + glTF generation
  extract_audio_banks.py  # XWB/XSB → WAV audio bridge
  bootstrap_godot_stage.py # Godot project builder

godot_stage/
  project.godot           # Godot 4.3 project
  scenes/
    Level_1_2_1.tscn      # Miners Bunker level scene
    Player.tscn           # Nova player character
    Main.tscn             # Model/audio browser
  scripts/
    nil_level_loader.gd   # JSON → ArrayMesh level builder
    player_controller.gd  # Third-person character controller
    level1_assembler.gd   # Curated model showcase
    main.gd               # Asset catalog browser
```

## Tech Stack

- **Godot 4.3** — open-source game engine (GDScript)
- **Python 3** — binary format parsers and converters
- **vgmstream** — Xbox audio extraction (XWB/XSB banks)
- **glTF 2.0** — interchange format for 3D models

## Status

- [x] NIL binary format reverse-engineered
- [x] NOD model format reverse-engineered
- [x] 1,391 models extracted to glTF
- [x] 2,604 audio cues extracted
- [x] All 8 levels parsed (547K vertices)
- [x] Level geometry rendering in Godot
- [x] Collision generation (ConcavePolygonShape3D)
- [x] Free-fly camera exploration
- [x] Third-person player controller (Nova)
- [x] Ambient audio playback
- [x] Atmospheric lighting and fog
- [ ] Texture mapping from TGA/DDS assets
- [ ] Enemy placement from Global.not
- [ ] AI state machines (patrol, alert, chase)
- [ ] Door/elevator interaction triggers
- [ ] Cutscene recreation

## Credits

- **Nihilistic Software / Naughty Dog Austin** — original developers (2002-2006)
- **Blizzard Entertainment** — publisher who cancelled it
- **The preservation community** — for making sure the build survived
- **Elyan Labs** — reverse engineering, Godot port, and software archaeology

*"They built a world. We're just making sure someone gets to see it."*

---

**License:** Tools and engine code are MIT. Game assets belong to their respective copyright holders and are not included in this repository.
