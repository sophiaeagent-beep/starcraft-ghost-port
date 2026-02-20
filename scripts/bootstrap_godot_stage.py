#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import shutil
from datetime import datetime, timezone
from pathlib import Path


def now_iso() -> str:
    return datetime.now(tz=timezone.utc).isoformat()


def ensure_parent(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def classify_mode(record: dict) -> str:
    geo = record.get("geometry_parse") or {}
    mode = str(geo.get("mode") or "").strip().lower()
    if mode == "triangle_index":
        return "triangle"
    if mode == "pointcloud":
        return "pointcloud"
    return "fallback"


def stage_file(src: Path, dst: Path, stage_mode: str) -> str:
    ensure_parent(dst)
    if dst.exists() or dst.is_symlink():
        dst.unlink()

    if stage_mode == "copy":
        shutil.copy2(src, dst)
        return "copied"

    os.symlink(src, dst)
    return "linked"


def model_sort_key(record: dict) -> tuple:
    rel = str(record.get("source_relative_path") or "").lower()
    return (rel,)


def audio_sort_key(path: Path) -> tuple:
    bank = path.parent.name.lower()
    stem = path.stem
    if stem.isdigit():
        return (bank, 0, int(stem))
    return (bank, 1, stem.lower())


def collect_models(
    model_manifest: dict,
    max_models: int,
    include_pointcloud: bool,
    include_fallback: bool,
    project_root: Path,
) -> list[dict]:
    summary = model_manifest.get("summary") or {}
    out_root = Path(summary.get("output") or "")
    records = model_manifest.get("records") or []
    records = sorted(records, key=model_sort_key)

    triangles: list[dict] = []
    pointclouds: list[dict] = []
    fallbacks: list[dict] = []

    for rec in records:
        gltf_rel = str(rec.get("gltf_stub_file") or "").strip()
        if not gltf_rel:
            continue

        src = out_root / gltf_rel
        if not src.exists():
            continue

        rel_path = Path(gltf_rel)
        if rel_path.parts and rel_path.parts[0] == "gltf_stub":
            rel_path = Path(*rel_path.parts[1:])
        dst_rel = Path("assets/models") / rel_path
        mode = classify_mode(rec)

        geo = rec.get("geometry_parse") or {}
        item = {
            "name": Path(str(rec.get("source_relative_path") or src.stem)).stem,
            "source_relative_path": str(rec.get("source_relative_path") or ""),
            "resource_path": f"res://{dst_rel.as_posix()}",
            "mode": mode,
            "triangle_count": int(geo.get("triangle_count") or 0),
            "point_count": int(geo.get("point_count") or 0),
            "_src": src,
            "_dst": project_root / dst_rel,
        }

        if mode == "triangle":
            triangles.append(item)
        elif mode == "pointcloud":
            pointclouds.append(item)
        else:
            fallbacks.append(item)

    selected = list(triangles)
    if include_pointcloud:
        selected.extend(pointclouds)
    if include_fallback:
        selected.extend(fallbacks)
    if max_models > 0:
        selected = selected[:max_models]

    deduped: list[dict] = []
    seen_dst: set[str] = set()
    for item in selected:
        key = Path(item["_dst"]).as_posix()
        if key in seen_dst:
            continue
        seen_dst.add(key)
        deduped.append(item)
    return deduped


def collect_audio(audio_manifest: dict, max_audio: int, project_root: Path) -> list[dict]:
    summary = audio_manifest.get("summary") or {}
    out_root = Path(summary.get("output") or "")
    wav_root = out_root / "wav_vgmstream"

    cue_map: dict[str, dict[int, str]] = {}
    for bank in (audio_manifest.get("banks") or []):
        bank_stem = Path(str(bank.get("bank_file") or "")).stem.lower()
        entries = bank.get("entries") or []
        by_idx: dict[int, str] = {}
        for ent in entries:
            idx = int(ent.get("index") or 0) + 1
            cue = str(ent.get("cue_name_guess") or "").strip()
            by_idx[idx] = cue
        cue_map[bank_stem] = by_idx

    if not wav_root.exists():
        return []

    wavs = sorted((p for p in wav_root.rglob("*.wav") if p.is_file()), key=audio_sort_key)
    if max_audio > 0:
        wavs = wavs[:max_audio]

    catalog: list[dict] = []
    for src in wavs:
        bank = src.parent.name
        stem = src.stem
        stream_idx = int(stem) if stem.isdigit() else -1
        cue = ""
        if stream_idx > 0:
            cue = cue_map.get(bank.lower(), {}).get(stream_idx, "")

        dst_rel = Path("assets/audio") / bank / src.name
        catalog.append(
            {
                "bank": bank,
                "stream_index": stream_idx,
                "cue_name_guess": cue,
                "resource_path": f"res://{dst_rel.as_posix()}",
                "_src": src,
                "_dst": project_root / dst_rel,
            }
        )
    return catalog


def write_project_files(project_root: Path, project_name: str, run_scene: str) -> None:
    (project_root / "scripts").mkdir(parents=True, exist_ok=True)
    (project_root / "scenes").mkdir(parents=True, exist_ok=True)
    (project_root / "data").mkdir(parents=True, exist_ok=True)

    main_scene_path = "res://scenes/Level1.tscn" if run_scene == "level1" else "res://scenes/Main.tscn"

    project_godot = f"""\
; Engine configuration file.
; Auto-generated by bootstrap_godot_stage.py
config_version=5

[application]
config/name="{project_name}"
run/main_scene="{main_scene_path}"
config/features=PackedStringArray("4.3")
config/icon="res://icon.svg"

[display]
window/size/viewport_width=1600
window/size/viewport_height=900

[rendering]
renderer/rendering_method="forward_plus"
"""
    (project_root / "project.godot").write_text(project_godot, encoding="utf-8")

    icon_svg = """\
<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128" viewBox="0 0 128 128">
  <rect width="128" height="128" rx="16" ry="16" fill="#101820"/>
  <path d="M18 96 L64 18 L110 96 Z" fill="#00a6a6"/>
  <circle cx="64" cy="76" r="14" fill="#f2f2f2"/>
</svg>
"""
    (project_root / "icon.svg").write_text(icon_svg, encoding="utf-8")

    main_tscn = """\
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://scripts/main.gd" id="1_main"]

[node name="Main" type="Node3D"]
script = ExtResource("1_main")

[node name="ModelRoot" type="Node3D" parent="."]

[node name="Camera3D" type="Camera3D" parent="."]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 2.2, 9)
current = true

[node name="DirectionalLight3D" type="DirectionalLight3D" parent="."]
transform = Transform3D(0.965926, -0.258819, 0, 0.183013, 0.683013, -0.707107, 0.183013, 0.683013, 0.707107, 0, 4, 0)
light_energy = 2.0

[node name="AudioPlayer" type="AudioStreamPlayer" parent="."]

[node name="HUD" type="CanvasLayer" parent="."]

[node name="InfoPanel" type="Panel" parent="HUD"]
offset_left = 16.0
offset_top = 16.0
offset_right = 820.0
offset_bottom = 212.0

[node name="InfoLabel" type="Label" parent="HUD/InfoPanel"]
offset_left = 12.0
offset_top = 12.0
offset_right = 792.0
offset_bottom = 184.0
autowrap_mode = 3
"""
    (project_root / "scenes/Main.tscn").write_text(main_tscn, encoding="utf-8")

    level1_tscn = """\
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://scripts/level1_assembler.gd" id="1_level1"]

[node name="Level1" type="Node3D"]
script = ExtResource("1_level1")

[node name="Environment" type="Node3D" parent="."]

[node name="Props" type="Node3D" parent="."]

[node name="Actors" type="Node3D" parent="."]

[node name="Camera3D" type="Camera3D" parent="."]
transform = Transform3D(1, 0, 0, 0, 0.945519, -0.325568, 0, 0.325568, 0.945519, 0, 18, 56)
current = true
fov = 60.0

[node name="DirectionalLight3D" type="DirectionalLight3D" parent="."]
transform = Transform3D(0.965926, -0.258819, 0, 0.183013, 0.683013, -0.707107, 0.183013, 0.683013, 0.707107, 0, 6, 0)
light_energy = 2.4

[node name="AmbientPlayer" type="AudioStreamPlayer" parent="."]
volume_db = -9.0

[node name="HUD" type="CanvasLayer" parent="."]

[node name="InfoPanel" type="Panel" parent="HUD"]
offset_left = 16.0
offset_top = 16.0
offset_right = 860.0
offset_bottom = 232.0

[node name="InfoLabel" type="Label" parent="HUD/InfoPanel"]
offset_left = 12.0
offset_top = 12.0
offset_right = 832.0
offset_bottom = 204.0
autowrap_mode = 3
"""
    (project_root / "scenes/Level1.tscn").write_text(level1_tscn, encoding="utf-8")

    main_gd = """\
extends Node3D

const MODEL_CATALOG_PATH := "res://data/model_catalog.json"
const AUDIO_CATALOG_PATH := "res://data/audio_catalog.json"
const SAFE_NO_ASSET_LOAD := true

@onready var model_root: Node3D = $ModelRoot
@onready var audio_player: AudioStreamPlayer = $AudioPlayer
@onready var info_label: Label = $HUD/InfoPanel/InfoLabel

var model_catalog: Array = []
var audio_catalog: Array = []
var model_index: int = 0
var audio_index: int = 0
var current_model: Node = null


func _ready() -> void:
	print("MAIN_READY: model/audio browser")
	if SAFE_NO_ASSET_LOAD:
		info_label.text = "
".join([
			"Main Scene Safe Mode",
			"Asset loading is disabled to prevent crashes.",
			"",
			"Press L to return to Level1.",
		])
		return
	model_catalog = _read_json_array(MODEL_CATALOG_PATH)
	audio_catalog = _read_json_array(AUDIO_CATALOG_PATH)
	_spawn_model(0)
	_load_audio(0)
	_refresh_info()


func _unhandled_input(event: InputEvent) -> void:
	if SAFE_NO_ASSET_LOAD:
		if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_L:
			get_tree().change_scene_to_file("res://scenes/Level1.tscn")
		return
	if event.is_action_pressed("ui_right"):
		_spawn_model(1)
		_refresh_info()
	elif event.is_action_pressed("ui_left"):
		_spawn_model(-1)
		_refresh_info()
	elif event.is_action_pressed("ui_up"):
		_load_audio(1)
		_refresh_info()
	elif event.is_action_pressed("ui_down"):
		_load_audio(-1)
		_refresh_info()
	elif event.is_action_pressed("ui_accept"):
		_toggle_audio()
		_refresh_info()
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_L:
			get_tree().change_scene_to_file("res://scenes/Level1.tscn")


func _spawn_model(step: int) -> void:
	if SAFE_NO_ASSET_LOAD:
		return
	if model_catalog.is_empty():
		_clear_current_model()
		return

	model_index = wrapi(model_index + step, 0, model_catalog.size())
	_clear_current_model()

	var item: Dictionary = model_catalog[model_index]
	var resource_path := str(item.get("resource_path", ""))
	var packed := load(resource_path)
	if packed is PackedScene:
		current_model = (packed as PackedScene).instantiate()
		model_root.add_child(current_model)
	else:
		current_model = null


func _clear_current_model() -> void:
	if current_model != null and is_instance_valid(current_model):
		current_model.queue_free()
	current_model = null


func _load_audio(step: int) -> void:
	if SAFE_NO_ASSET_LOAD:
		audio_player.stop()
		audio_player.stream = null
		return
	if audio_catalog.is_empty():
		audio_player.stop()
		audio_player.stream = null
		return

	audio_index = wrapi(audio_index + step, 0, audio_catalog.size())
	var item: Dictionary = audio_catalog[audio_index]
	var resource_path := str(item.get("resource_path", ""))
	var stream := load(resource_path)
	if stream is AudioStream:
		audio_player.stream = stream
		audio_player.stop()


func _toggle_audio() -> void:
	if audio_player.stream == null:
		return
	if audio_player.playing:
		audio_player.stop()
	else:
		audio_player.play()


func _refresh_info() -> void:
	var model_text := "Model: none"
	if not model_catalog.is_empty():
		var m: Dictionary = model_catalog[model_index]
		model_text = "Model %d/%d: %s  [%s]" % [
			model_index + 1,
			model_catalog.size(),
			str(m.get("name", "unnamed")),
			str(m.get("mode", "unknown")),
		]

	var audio_text := "Audio: none"
	var play_text := "stopped"
	if audio_player.playing:
		play_text = "playing"
	if not audio_catalog.is_empty():
		var a: Dictionary = audio_catalog[audio_index]
		var cue := str(a.get("cue_name_guess", ""))
		if cue == "":
			cue = "(no cue)"
		audio_text = "Audio %d/%d: %s/%s %s (%s)" % [
			audio_index + 1,
			audio_catalog.size(),
			str(a.get("bank", "")),
			str(a.get("stream_index", "")),
			cue,
			play_text,
		]

	info_label.text = "
".join([
		"Ghost Model/Audio Browser",
		model_text,
		audio_text,
		"",
		"Controls:",
		"Left/Right = previous/next model",
		"Up/Down = previous/next audio stream",
		"Enter = play/stop audio",
		"L = open Level1 assembler scene",
	])


func _read_json_array(path: String) -> Array:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var parsed = JSON.parse_string(f.get_as_text())
	if parsed is Array:
		return parsed
	return []
"""
    (project_root / "scripts/main.gd").write_text(main_gd, encoding="utf-8")

    level1_gd = """\
extends Node3D

const MODEL_CATALOG_PATH := "res://data/model_catalog.json"
const AUDIO_CATALOG_PATH := "res://data/audio_catalog.json"

const ENV_TOKENS = [
	"121", "1_2_1", "trench", "bridge", "catwalk", "platform", "hangar",
	"hallway", "room", "corridor", "deck", "door", "wall", "floor", "stair", "support"
]
const PROP_TOKENS = [
	"crate", "barrel", "lamp", "console", "panel", "pipe", "vent", "generator", "antenna",
	"canister", "cable", "fan", "lift", "turret", "terminal"
]
const ACTOR_TOKENS = [
	"nova", "ghost", "marine", "zerg", "hydralisk", "firebat", "dragoon", "observer", "goliath"
]
const AVOID_TOKENS = [
	"physclip", "_phys", "_clip", "_pclip", "collision", "muzzle", "fx", "decal", "shaderball", "dflt"
]
const AMBIENT_TOKENS = [
	"env_", "ambient", "battle_lp", "music_", "wind", "alarm", "machinery", "loop"
]

const MAX_ENV := 10
const MAX_PROPS := 10
const MAX_ACTORS := 3
const DEFAULT_PROXY_MODE := true
const DISABLE_RUNTIME_AUDIO := false
const USE_SAFE_SYNTH_AUDIO := true
const PALETTE_ENV_DARK := Color(0.23, 0.28, 0.26, 1.0)
const PALETTE_ENV_LIGHT := Color(0.34, 0.40, 0.36, 1.0)
const PALETTE_PROP_DARK := Color(0.31, 0.29, 0.23, 1.0)
const PALETTE_PROP_LIGHT := Color(0.42, 0.39, 0.29, 1.0)
const PALETTE_ACTOR_DARK := Color(0.36, 0.29, 0.26, 1.0)
const PALETTE_ACTOR_LIGHT := Color(0.49, 0.37, 0.31, 1.0)

@onready var env_root: Node3D = $Environment
@onready var prop_root: Node3D = $Props
@onready var actor_root: Node3D = $Actors
@onready var cam: Camera3D = $Camera3D
@onready var ambient_player: AudioStreamPlayer = $AmbientPlayer
@onready var info_label: Label = $HUD/InfoPanel/InfoLabel

var model_catalog: Array = []
var audio_catalog: Array = []
var ambient_indices: Array = []
var ambient_idx: int = 0
var active_ambient_desc: String = "none"
var spawned_counts := {"env": 0, "props": 0, "actors": 0}
var use_proxy_mode: bool = DEFAULT_PROXY_MODE


func _ready() -> void:
	print("LEVEL1_READY: safe proxy mode")
	randomize()
	model_catalog = _read_json_array(MODEL_CATALOG_PATH)
	audio_catalog = _read_json_array(AUDIO_CATALOG_PATH)
	_ensure_world_environment()
	_ensure_fill_light()
	_tune_key_light()
	_add_debug_ground()
	_rebuild_level()
	ambient_indices = _pick_ambient(audio_catalog)
	_prime_ambient_selection()
	cam.look_at(Vector3(0, 4, 22), Vector3.UP)
	_refresh_info()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key_event := event as InputEventKey
	if not key_event.pressed or key_event.echo:
		return
	if key_event.keycode == KEY_ENTER or key_event.keycode == KEY_KP_ENTER:
		_toggle_ambient()
		_refresh_info()
	elif key_event.keycode == KEY_RIGHT or key_event.keycode == KEY_M:
		_set_ambient_step(1)
		_refresh_info()
	elif key_event.keycode == KEY_LEFT:
		_set_ambient_step(-1)
		_refresh_info()
	elif key_event.keycode == KEY_R:
		_rebuild_level()
		_refresh_info()
	elif key_event.keycode == KEY_G:
		_rebuild_level()
		_refresh_info()
	elif key_event.keycode == KEY_B:
		# Disabled in safe mode: entering Main can trigger unstable asset loads.
		_refresh_info()


func _rebuild_level() -> void:
	_clear_children(env_root)
	_clear_children(prop_root)
	_clear_children(actor_root)

	var curated := _collect_curated(model_catalog)
	spawned_counts["env"] = _spawn_grid(curated["env"], env_root, 8, 12.0, -28.0, false, 0.0, "env")
	spawned_counts["props"] = _spawn_grid(curated["props"], prop_root, 8, 8.0, 46.0, true, 0.2, "props")
	spawned_counts["actors"] = _spawn_ring(curated["actors"], actor_root, 14.0, "actors")


func _collect_curated(models: Array) -> Dictionary:
	var curated := {"env": [], "props": [], "actors": []}
	for raw in models:
		if not (raw is Dictionary):
			continue
		var item: Dictionary = raw
		var klass := _classify_model(item)
		if klass == "env" and curated["env"].size() < MAX_ENV:
			curated["env"].append(item)
		elif klass == "props" and curated["props"].size() < MAX_PROPS:
			curated["props"].append(item)
		elif klass == "actors" and curated["actors"].size() < MAX_ACTORS:
			curated["actors"].append(item)
		if (
			curated["env"].size() >= MAX_ENV
			and curated["props"].size() >= MAX_PROPS
			and curated["actors"].size() >= MAX_ACTORS
		):
			break
	return curated


func _classify_model(item: Dictionary) -> String:
	var mode := str(item.get("mode", "")).to_lower()
	if mode != "triangle":
		return ""
	var tri_count := int(item.get("triangle_count", 0))
	if tri_count <= 0 or tri_count > 800:
		return ""
	var text := "%s %s" % [str(item.get("source_relative_path", "")).to_lower(), str(item.get("name", "")).to_lower()]
	if _contains_any(text, AVOID_TOKENS):
		return ""
	if _contains_any(text, ACTOR_TOKENS):
		return "actors"
	if _contains_any(text, ENV_TOKENS):
		return "env"
	if _contains_any(text, PROP_TOKENS):
		return "props"
	if ("121" in text or "1_2_1" in text) and mode == "triangle":
		return "env"
	if mode == "triangle":
		return "props"
	return ""


func _spawn_grid(
	items: Array,
	root: Node3D,
	columns: int,
	spacing: float,
	z_start: float,
	random_yaw: bool,
	y_jitter: float,
	klass: String
) -> int:
	var placed := 0
	if columns <= 0:
		return placed
	for i in range(items.size()):
		var item: Dictionary = items[i]
		var inst := _instantiate_visual(item, klass)
		if inst == null:
			continue
		root.add_child(inst)
		_style_instance(inst, klass, str(item.get("name", "")))
		if inst is Node3D:
			var n3 := inst as Node3D
			_normalize_instance_scale(n3, 7.0)
			var row := i / columns
			var col := i % columns
			var x := (float(col) - (float(columns - 1) * 0.5)) * spacing
			if row % 2 == 1:
				x += spacing * 0.35
			var z := z_start + float(row) * spacing
			var y := randf_range(-y_jitter, y_jitter)
			n3.position = Vector3(x, y, z)
			if random_yaw:
				n3.rotation.y = randf() * TAU
			if not n3.position.is_finite():
				n3.position = Vector3(0.0, 0.0, z_start)
		placed += 1
	return placed


func _spawn_ring(items: Array, root: Node3D, radius: float, klass: String) -> int:
	var placed := 0
	if items.is_empty():
		return placed
	for i in range(items.size()):
		var item: Dictionary = items[i]
		var inst := _instantiate_visual(item, klass)
		if inst == null:
			continue
		root.add_child(inst)
		_style_instance(inst, klass, str(item.get("name", "")))
		if inst is Node3D:
			var n3 := inst as Node3D
			_normalize_instance_scale(n3, 3.2)
			var angle := (TAU * float(i)) / float(items.size())
			n3.position = Vector3(cos(angle) * radius, 0.0, 12.0 + sin(angle) * radius)
			n3.look_at(Vector3(0, 0, 14.0), Vector3.UP)
		placed += 1
	return placed


func _pick_ambient(audio_rows: Array) -> Array:
	var picks: Array = []
	for i in range(audio_rows.size()):
		if not (audio_rows[i] is Dictionary):
			continue
		var item: Dictionary = audio_rows[i]
		var text := "%s %s" % [str(item.get("bank", "")).to_lower(), str(item.get("cue_name_guess", "")).to_lower()]
		if _contains_any(text, AMBIENT_TOKENS):
			picks.append(i)
	if picks.is_empty():
		var limit: int = min(audio_rows.size(), 64)
		for i in range(limit):
			picks.append(i)
	return picks


func _set_ambient_step(step: int) -> void:
	_set_ambient(step, ambient_player.playing)


func _set_ambient(step: int, autoplay: bool) -> void:
	if ambient_indices.is_empty():
		ambient_player.stop()
		ambient_player.stream = null
		active_ambient_desc = "none"
		return
	ambient_idx = wrapi(ambient_idx + step, 0, ambient_indices.size())
	var src_idx := int(ambient_indices[ambient_idx])
	var row: Dictionary = audio_catalog[src_idx]
	if DISABLE_RUNTIME_AUDIO:
		ambient_player.stop()
		ambient_player.stream = null
		active_ambient_desc = _describe_ambient_row(row)
		return
	if USE_SAFE_SYNTH_AUDIO:
		var idx := int(row.get("stream_index", ambient_idx + 1))
		var idx_mod := idx % 12
		if idx_mod < 0:
			idx_mod += 12
		var hz := 96.0 + float(idx_mod) * 8.0
		ambient_player.stream = _build_sine_stream(hz, 1.6)
		if autoplay:
			ambient_player.play()
		else:
			ambient_player.stop()
		active_ambient_desc = "safe-tone %.0fHz :: %s" % [hz, _describe_ambient_row(row)]
		return
	var resource_path := str(row.get("resource_path", ""))
	var stream := load(resource_path)
	if stream is AudioStream:
		ambient_player.stream = stream
		if autoplay:
			ambient_player.play()
		else:
			ambient_player.stop()
	active_ambient_desc = _describe_ambient_row(row)


func _toggle_ambient() -> void:
	if DISABLE_RUNTIME_AUDIO:
		return
	if ambient_player.stream == null:
		_set_ambient(0, true)
		return
	if ambient_player.playing:
		ambient_player.stop()
	else:
		ambient_player.play()


func _build_sine_stream(freq_hz: float, seconds: float) -> AudioStreamWAV:
	var sample_rate := 22050
	var count := int(maxf(1.0, float(sample_rate) * seconds))
	var pcm := PackedByteArray()
	pcm.resize(count * 2)
	for i in range(count):
		var t := float(i) / float(sample_rate)
		var s := sin(TAU * freq_hz * t) * 0.18
		var q := int(clampf(s, -1.0, 1.0) * 32767.0)
		pcm[i * 2] = q & 0xFF
		pcm[i * 2 + 1] = (q >> 8) & 0xFF
	var wav := AudioStreamWAV.new()
	wav.data = pcm
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = sample_rate
	wav.stereo = false
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	return wav


func _prime_ambient_selection() -> void:
	ambient_player.stop()
	ambient_player.stream = null
	if ambient_indices.is_empty():
		active_ambient_desc = "none"
		return
	ambient_idx = 0
	var src_idx := int(ambient_indices[ambient_idx])
	var row: Dictionary = audio_catalog[src_idx]
	active_ambient_desc = _describe_ambient_row(row)


func _describe_ambient_row(row: Dictionary) -> String:
	var cue := str(row.get("cue_name_guess", ""))
	if cue == "":
		cue = "(no cue)"
	return "%s/%s %s" % [str(row.get("bank", "")), str(row.get("stream_index", "")), cue]


func _style_instance(node: Node, klass: String, model_name: String) -> void:
	var color := _pick_display_color(klass, model_name)
	_apply_material_recursive(node, color)


func _apply_material_recursive(node: Node, color: Color) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			return
		var mat := StandardMaterial3D.new()
		mat.albedo_color = color
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.roughness = 0.84
		mat.metallic = 0.08
		mat.emission_enabled = true
		mat.emission = color * 0.05
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	for child in node.get_children():
		_apply_material_recursive(child, color)


func _normalize_instance_scale(n3: Node3D, target_span: float) -> void:
	var longest := _first_mesh_longest(n3)
	if longest <= 0.0001 or longest > 100000.0:
		return
	var s := clampf(target_span / longest, 0.04, 4.0)
	if is_nan(s) or is_inf(s):
		return
	n3.scale = Vector3.ONE * s


func _first_mesh_longest(node: Node) -> float:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			return -1.0
		var aabb := mi.mesh.get_aabb().size
		if not aabb.is_finite():
			return -1.0
		return maxf(aabb.x, maxf(aabb.y, aabb.z))
	for child in node.get_children():
		var v := _first_mesh_longest(child)
		if v > 0.0:
			return v
	return -1.0


func _add_debug_ground() -> void:
	if has_node("DebugGround"):
		return
	var ground := MeshInstance3D.new()
	ground.name = "DebugGround"
	var box := BoxMesh.new()
	box.size = Vector3(240.0, 1.0, 240.0)
	ground.mesh = box
	ground.position = Vector3(0.0, -0.7, 10.0)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.10, 0.12, 0.10, 1.0)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	ground.material_override = mat
	add_child(ground)


func _ensure_world_environment() -> void:
	var world_env: WorldEnvironment
	if has_node("WorldEnvironment"):
		world_env = get_node("WorldEnvironment") as WorldEnvironment
	else:
		world_env = WorldEnvironment.new()
		world_env.name = "WorldEnvironment"
		add_child(world_env)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.04, 0.05, 0.06, 1.0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.46, 0.50, 0.46, 1.0)
	env.ambient_light_energy = 0.85
	world_env.environment = env


func _ensure_fill_light() -> void:
	if has_node("FillLight"):
		return
	var fill := OmniLight3D.new()
	fill.name = "FillLight"
	fill.light_energy = 1.2
	fill.omni_range = 140.0
	fill.light_color = Color(0.66, 0.72, 0.69, 1.0)
	fill.position = Vector3(0.0, 14.0, 24.0)
	add_child(fill)


func _tune_key_light() -> void:
	if not has_node("DirectionalLight3D"):
		return
	var key := get_node("DirectionalLight3D")
	if key is DirectionalLight3D:
		var d := key as DirectionalLight3D
		d.light_energy = 1.55
		d.light_color = Color(0.76, 0.78, 0.74, 1.0)


func _instantiate_visual(item: Dictionary, klass: String) -> Node:
	# Force proxy mode for stability in runtime launcher sessions.
	# Real imported GLTF scenes can be toggled back in a later diagnostic branch.
	var _unused := item
	return _build_proxy_instance(klass)


func _build_proxy_instance(klass: String) -> Node3D:
	var root := Node3D.new()
	var mi := MeshInstance3D.new()
	var mesh: Mesh
	if klass == "env":
		var box := BoxMesh.new()
		box.size = Vector3(5.4, 2.8, 5.4)
		mesh = box
	elif klass == "actors":
		var capsule := CapsuleMesh.new()
		capsule.radius = 0.75
		capsule.height = 2.5
		mesh = capsule
	else:
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.60
		cyl.bottom_radius = 0.72
		cyl.height = 1.8
		mesh = cyl
	mi.mesh = mesh
	root.add_child(mi)
	return root


func _pick_display_color(klass: String, model_name: String) -> Color:
	var dark := PALETTE_PROP_DARK
	var light := PALETTE_PROP_LIGHT
	if klass == "env":
		dark = PALETTE_ENV_DARK
		light = PALETTE_ENV_LIGHT
	elif klass == "actors":
		dark = PALETTE_ACTOR_DARK
		light = PALETTE_ACTOR_LIGHT
	var mix := _name_mix_01(model_name)
	return dark.lerp(light, mix)


func _name_mix_01(model_name: String) -> float:
	var h: int = model_name.hash()
	var m: int = h % 11
	if m < 0:
		m = -m
	return float(m) / 10.0


func _contains_any(text: String, needles: Array) -> bool:
	for needle in needles:
		if needle != "" and text.find(needle) != -1:
			return true
	return false


func _clear_children(root: Node) -> void:
	for child in root.get_children():
		child.queue_free()


func _refresh_info() -> void:
	var ambient_state := "stopped"
	if ambient_player.playing:
		ambient_state = "playing"
	var visual_mode := "proxy/forced (gritty)"
	var audio_mode := "wav assets"
	if DISABLE_RUNTIME_AUDIO:
		audio_mode = "off"
	elif USE_SAFE_SYNTH_AUDIO:
		audio_mode = "safe tone synth"
	info_label.text = "
".join([
		"Ghost Level1 Assembler",
		"Environment models: %d" % int(spawned_counts.get("env", 0)),
		"Props: %d" % int(spawned_counts.get("props", 0)),
		"Actors: %d" % int(spawned_counts.get("actors", 0)),
		"Visual mode: %s" % visual_mode,
		"Audio mode: %s" % audio_mode,
		"Ambient: %s (%s)" % [active_ambient_desc, ambient_state],
		"",
		"Controls:",
		"Left/Right or M = previous/next ambient track",
		"Enter = play/stop ambient",
		"R = rebuild curated layout",
		"G = rebuild (proxy remains forced)",
		"B = disabled in safe mode",
	])


func _read_json_array(path: String) -> Array:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var parsed = JSON.parse_string(f.get_as_text())
	if parsed is Array:
		return parsed
	return []
"""
    (project_root / "scripts/level1_assembler.gd").write_text(level1_gd, encoding="utf-8")


def write_catalog(path: Path, rows: list[dict]) -> None:
    clean_rows: list[dict] = []
    for row in rows:
        clean_row = {k: v for k, v in row.items() if not k.startswith("_")}
        clean_rows.append(clean_row)
    path.write_text(json.dumps(clean_rows, indent=2), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Create a Godot 4 playable import stage from Ghost model/audio manifests."
    )
    parser.add_argument(
        "--project",
        type=Path,
        default=Path("/home/scott/Games/xemu/ghost_port/godot_stage"),
        help="Output Godot project directory.",
    )
    parser.add_argument(
        "--model-manifest",
        type=Path,
        default=Path("/home/scott/Games/xemu/ghost_port/out/model_stubs_starcraft_ghost/manifests/model_stub_manifest.json"),
        help="Model stub manifest produced by build_model_stubs.py.",
    )
    parser.add_argument(
        "--audio-manifest",
        type=Path,
        default=Path("/home/scott/Games/xemu/ghost_port/out/audio_bridge/manifests/audio_manifest.json"),
        help="Audio manifest produced by extract_audio_banks.py.",
    )
    parser.add_argument(
        "--stage-mode",
        choices=("symlink", "copy"),
        default="symlink",
        help="How files are staged inside the Godot project.",
    )
    parser.add_argument("--max-models", type=int, default=400, help="Max models to stage (0 = all selected).")
    parser.add_argument("--max-audio", type=int, default=128, help="Max WAV files to stage (0 = all).")
    parser.add_argument("--include-pointcloud", action="store_true", help="Include pointcloud-only models.")
    parser.add_argument("--include-fallback", action="store_true", help="Include fallback stub models.")
    parser.add_argument("--clean-assets", action="store_true", help="Delete staged assets folders before restaging.")
    parser.add_argument("--project-name", default="GhostPortStage", help="Godot project display name.")
    parser.add_argument(
        "--run-scene",
        choices=("main", "level1"),
        default="level1",
        help="Scene to configure as the default startup scene.",
    )
    args = parser.parse_args()

    project_root = args.project.resolve()
    model_manifest_path = args.model_manifest.resolve()
    audio_manifest_path = args.audio_manifest.resolve()

    if not model_manifest_path.exists():
        raise SystemExit(f"Missing model manifest: {model_manifest_path}")
    if not audio_manifest_path.exists():
        raise SystemExit(f"Missing audio manifest: {audio_manifest_path}")

    model_manifest = read_json(model_manifest_path)
    audio_manifest = read_json(audio_manifest_path)

    write_project_files(project_root, args.project_name, args.run_scene)

    if args.clean_assets:
        shutil.rmtree(project_root / "assets/models", ignore_errors=True)
        shutil.rmtree(project_root / "assets/audio", ignore_errors=True)

    models = collect_models(
        model_manifest=model_manifest,
        max_models=max(0, args.max_models),
        include_pointcloud=args.include_pointcloud,
        include_fallback=args.include_fallback,
        project_root=project_root,
    )
    audio = collect_audio(
        audio_manifest=audio_manifest,
        max_audio=max(0, args.max_audio),
        project_root=project_root,
    )

    model_linked = 0
    audio_linked = 0

    for item in models:
        stage_file(Path(item["_src"]), Path(item["_dst"]), args.stage_mode)
        model_linked += 1

    for item in audio:
        stage_file(Path(item["_src"]), Path(item["_dst"]), args.stage_mode)
        audio_linked += 1

    write_catalog(project_root / "data/model_catalog.json", models)
    write_catalog(project_root / "data/audio_catalog.json", audio)

    summary = {
        "created_utc": now_iso(),
        "project": project_root.as_posix(),
        "stage_mode": args.stage_mode,
        "model_manifest": model_manifest_path.as_posix(),
        "audio_manifest": audio_manifest_path.as_posix(),
        "models_staged": model_linked,
        "audio_staged": audio_linked,
        "run_scene": args.run_scene,
        "selection": {
            "max_models": args.max_models,
            "max_audio": args.max_audio,
            "include_pointcloud": args.include_pointcloud,
            "include_fallback": args.include_fallback,
        },
        "run_hint": f"/home/scott/Applications/Godot_v4.3-stable_linux.x86_64 --path {project_root.as_posix()}",
    }
    (project_root / "data/stage_manifest.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")

    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
