#!/usr/bin/env python3
"""Batch convert all DDS textures to PNG and update glTF references.

1. Convert all DDS in textures/ to PNG via ImageMagick
2. Patch every glTF to reference .png instead of .dds
3. Copy results to Godot project

Usage: python3 batch_dds_to_png.py
"""

import json, os, subprocess, sys, shutil, glob
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed

# ── Paths ─────────────────────────────────────────────────
SRC_DIR  = Path("/home/scott/Games/xemu/ghost_port/out/gltf_textured")
TEX_DIR  = SRC_DIR / "textures"
DST_DIR  = Path("/home/scott/Games/xemu/ghost_port/godot_stage/assets/models_all")
DST_TEX  = DST_DIR / "textures"

def convert_dds_to_png(dds_path: Path) -> bool:
    """Convert a single DDS file to PNG."""
    png_path = dds_path.with_suffix(".png")
    if png_path.exists() and png_path.stat().st_size > 0:
        return True  # Already converted
    try:
        result = subprocess.run(
            ["magick", str(dds_path), str(png_path)],
            capture_output=True, timeout=30
        )
        if result.returncode != 0:
            # Some DDS may have multiple layers; take first
            result = subprocess.run(
                ["magick", f"{dds_path}[0]", str(png_path)],
                capture_output=True, timeout=30
            )
        return png_path.exists() and png_path.stat().st_size > 0
    except Exception as e:
        print(f"  FAIL: {dds_path.name}: {e}")
        return False


def patch_gltf(gltf_path: Path) -> dict:
    """Patch a glTF file: change .dds refs to .png, mimetype to image/png."""
    with open(gltf_path) as f:
        data = json.load(f)

    changed = False
    images = data.get("images", [])
    for img in images:
        uri = img.get("uri", "")
        if uri.lower().endswith(".dds"):
            img["uri"] = uri.rsplit(".", 1)[0] + ".png"
            img["mimeType"] = "image/png"
            changed = True
        mime = img.get("mimeType", "")
        if mime == "image/dds":
            img["mimeType"] = "image/png"
            changed = True

    if changed:
        with open(gltf_path, "w") as f:
            json.dump(data, f, indent=2)

    return {
        "name": gltf_path.stem,
        "images": len(images),
        "patched": changed,
        "prims": sum(len(m.get("primitives", [])) for m in data.get("meshes", [])),
        "mats": len(data.get("materials", [])),
    }


def main():
    print("=" * 60)
    print("StarCraft: Ghost — Batch DDS→PNG + glTF Patcher")
    print("=" * 60)

    # Step 1: Convert DDS → PNG
    dds_files = sorted(TEX_DIR.glob("*.dds")) + sorted(TEX_DIR.glob("*.DDS"))
    print(f"\n[1/3] Converting {len(dds_files)} DDS textures to PNG...")

    ok, fail = 0, 0
    with ThreadPoolExecutor(max_workers=8) as pool:
        futures = {pool.submit(convert_dds_to_png, f): f for f in dds_files}
        for future in as_completed(futures):
            if future.result():
                ok += 1
            else:
                fail += 1
                print(f"  FAIL: {futures[future].name}")
            # Progress
            done = ok + fail
            if done % 50 == 0 or done == len(dds_files):
                print(f"  {done}/{len(dds_files)} textures processed ({ok} ok, {fail} fail)")

    print(f"  Textures: {ok} converted, {fail} failed")

    # Step 2: Patch all glTF files
    gltf_files = sorted(SRC_DIR.glob("*.gltf"))
    print(f"\n[2/3] Patching {len(gltf_files)} glTF files...")

    textured, untextured, patched = 0, 0, 0
    for i, gf in enumerate(gltf_files):
        info = patch_gltf(gf)
        if info["images"] > 0:
            textured += 1
        else:
            untextured += 1
        if info["patched"]:
            patched += 1
        if (i + 1) % 200 == 0 or (i + 1) == len(gltf_files):
            print(f"  {i + 1}/{len(gltf_files)} glTFs processed")

    print(f"  Models: {textured} textured, {untextured} untextured, {patched} patched")

    # Step 3: Copy to Godot project
    print(f"\n[3/3] Copying to Godot project: {DST_DIR}")
    DST_DIR.mkdir(parents=True, exist_ok=True)
    DST_TEX.mkdir(parents=True, exist_ok=True)

    # Copy glTFs
    for gf in gltf_files:
        shutil.copy2(gf, DST_DIR / gf.name)

    # Copy PNG textures (not DDS)
    png_files = sorted(TEX_DIR.glob("*.png"))
    for pf in png_files:
        shutil.copy2(pf, DST_TEX / pf.name)

    print(f"  Copied {len(gltf_files)} glTF files")
    print(f"  Copied {len(png_files)} PNG textures")

    print("\n" + "=" * 60)
    print("DONE! All models in: assets/models_all/")
    print(f"  {textured} textured models, {untextured} untextured models")
    print(f"  {len(png_files)} PNG textures")
    print("=" * 60)


if __name__ == "__main__":
    main()
