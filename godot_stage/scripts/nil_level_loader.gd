extends Node3D
## NIL Level Loader — loads level geometry from parser JSON output.
##
## Reads compact JSON produced by nil_parser.py (flat arrays for
## positions, normals, colors, uvs, indices) and builds ArrayMesh
## instances. Generates trimesh collision for walkable surfaces.

const LEVEL_DATA_PATH := "res://data/level_1_2_1.json"
const TEXTURE_MAP_PATH := "res://data/texture_map_1_2_1.json"
const GLOBAL_TEXTURE_MAP_PATH := "res://data/texture_map_global.json"
const MATERIAL_ASSIGN_PATH := "res://data/material_assignments_1_2_1.json"
const NSD_ENTITIES_PATH := "res://data/nsd_entities_1_2_1_enhanced.json"
const TEXTURE_DIR := "res://assets/textures/"
const PLAYER_SCENE := "res://scenes/Player.tscn"
const ENEMY_SCENE := "res://scenes/Enemy.tscn"

## Model paths for enemy types
const ENEMY_MODELS := {
	"marinesidekick": "res://assets/models_all/MarineSuit_prop.gltf",
	"marinesidekick_wounded": "res://assets/models_all/MarineSuit_prop.gltf",
	"overlord": "res://assets/models_all/Overlord_smash.gltf",
	"zergling": "res://assets/models_all/Zergling_collide.gltf",
	"hydralisk": "res://assets/models_all/HydraliskRUSH_collide.gltf",
}

## Manual entity→model overrides for names that don't match filenames directly.
## Keys are lowercase entity names (stripped of .nag), values are glTF basenames.
const ENTITY_MODEL_OVERRIDES := {
	# Doors — level-specific door models
	"doormetal01": "1_2_1_BunkerDoor_01",
	"hackconsole_floor_activate": "hackConsole_floor",
	"ladder_dynamic": "GE_ladderMain_01",
	# Pickups — footlockers share the green footlocker model
	"ge_footlocker_grn_gauss": "GE_footLocker_grn",
	"ge_footlocker_grn_health": "GE_footLocker_grn",
	"ge_footlocker_grn_spider": "GE_footLocker_grn",
	# Props
	"propterrlift": "lift",
}

## Runtime model index: lowercase base name → full res:// path
## Built by _build_model_index() at startup
var model_index: Dictionary = {}

## Enemy stats by type
const ENEMY_STATS := {
	"marinesidekick": { "health": 80.0, "speed": 5.0, "chase_speed": 8.0, "range": 20.0, "attack_range": 12.0, "damage": 8.0 },
	"marinesidekick_wounded": { "health": 30.0, "speed": 3.0, "chase_speed": 5.0, "range": 15.0, "attack_range": 10.0, "damage": 5.0 },
	"overlord": { "health": 200.0, "speed": 2.0, "chase_speed": 3.0, "range": 40.0, "attack_range": 5.0, "damage": 15.0 },
	"zergling": { "health": 35.0, "speed": 8.0, "chase_speed": 12.0, "range": 18.0, "attack_range": 2.5, "damage": 12.0 },
	"hydralisk": { "health": 120.0, "speed": 4.0, "chase_speed": 6.0, "range": 30.0, "attack_range": 15.0, "damage": 10.0 },
}

## Mesh groups smaller than this get no collision (decorations)
const COLLISION_MIN_TRIS := 10
## Scale factor — NIL units are roughly 1:1 meters
const LEVEL_SCALE := 1.0

const LEVEL_AUDIO_DIR := "res://assets/audio/1_2_1/"

@onready var level_root: Node3D = $LevelGeometry
@onready var cam: Camera3D = $FreeFlyCamera
@onready var hud_label: Label = $HUD/InfoLabel

var mesh_count: int = 0
var tri_count: int = 0
var vert_count: int = 0
var _ss_frame: int = 0
var level_center: Vector3 = Vector3.ZERO
var player_node: CharacterBody3D = null
var player_mode: bool = false
var ambient_player: AudioStreamPlayer = null
var audio_tracks: Array = []
var audio_idx: int = 0
var audio_playing: bool = false

# Entity system (from NSD parser)
var entity_root: Node3D = null
var entities_visible: bool = true
var entity_counts: Dictionary = {}  # category → count
var entity_total: int = 0
var player_spawn: Vector3 = Vector3.ZERO
var enemy_count: int = 0
var models_loaded_count: int = 0

# Texture system
var texture_map: Dictionary = {}  # material_name → texture_name (from NSA)
var loaded_textures: Dictionary = {}  # texture_name → Texture2D
var material_assignments: Dictionary = {}  # group_id → material_name
var level_materials: Array = []  # material names from NIL header
var textured_mode: bool = true  # Toggle between textured and vertex-color-only
var unshaded_mode: bool = false  # Toggle unshaded rendering for debug
var tex_loaded_count: int = 0

# Camera fly controls
var fly_speed: float = 20.0
var fly_fast_speed: float = 60.0
var mouse_sensitivity: float = 0.002
var pitch: float = 0.0
var yaw: float = 0.0
var mouse_captured: bool = true


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_build_model_index()
	_load_textures()
	_load_level(LEVEL_DATA_PATH)
	_load_entities()
	_setup_environment()
	_setup_audio()
	# Auto-start in player walking mode if spawn point was found
	if player_spawn != Vector3.ZERO:
		_toggle_player_mode()
	_update_hud()


func _build_model_index() -> void:
	## Scan assets/models_all/ and build a case-insensitive lookup from
	## base filename (no extension) → res:// path.
	var scan_dir := "res://assets/models_all/"
	var dir := DirAccess.open(scan_dir)
	if dir == null:
		print("No models directory at %s" % scan_dir)
		return
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname.ends_with(".gltf") and not fname.ends_with(".import"):
			var base := fname.get_basename()  # strip .gltf
			model_index[base.to_lower()] = scan_dir + fname
		fname = dir.get_next()
	dir.list_dir_end()
	print("Model index: %d glTF models indexed" % model_index.size())


func _find_model_for_entity(ent_name: String) -> String:
	## Look up a glTF model path for an entity name.
	## Returns "" if no matching model found.
	## Priority: manual override → direct match → stripped match
	var clean := ent_name.replace(".nag", "")
	var lower := clean.to_lower()

	# 1. Check manual override table
	if ENTITY_MODEL_OVERRIDES.has(lower):
		var override_base: String = ENTITY_MODEL_OVERRIDES[lower]
		var override_lower := override_base.to_lower()
		if model_index.has(override_lower):
			return model_index[override_lower]

	# 2. Direct case-insensitive match
	if model_index.has(lower):
		return model_index[lower]

	# 3. Try without common prefixes/suffixes
	for suffix in ["_01", "_02", "_collide", "_smash", "_phys"]:
		if model_index.has(lower + suffix):
			return model_index[lower + suffix]

	return ""


func _load_model_scene(model_path: String) -> Node3D:
	## Load a glTF model and return the root Node3D.
	## Returns null if loading fails.
	var scene = load(model_path)
	if scene is PackedScene:
		var instance := (scene as PackedScene).instantiate()
		if instance is Node3D:
			return instance as Node3D
		instance.queue_free()
	return null


func _load_textures() -> void:
	# Load texture maps (material_name → texture_name from NSA parser)
	for map_path in [TEXTURE_MAP_PATH, GLOBAL_TEXTURE_MAP_PATH]:
		var f := FileAccess.open(map_path, FileAccess.READ)
		if f == null:
			continue
		var parsed = JSON.parse_string(f.get_as_text())
		f.close()
		if parsed is Dictionary:
			for key in (parsed as Dictionary):
				if not texture_map.has(key):
					texture_map[key] = (parsed as Dictionary)[key]

	# Load material assignments (group_id → material_name)
	var af := FileAccess.open(MATERIAL_ASSIGN_PATH, FileAccess.READ)
	if af != null:
		var assign_data = JSON.parse_string(af.get_as_text())
		af.close()
		if assign_data is Array:
			for entry in (assign_data as Array):
				if entry is Dictionary:
					var d: Dictionary = entry
					var gid: int = int(d.get("group_id", -1))
					var mname: String = d.get("material_name", "")
					if gid >= 0 and mname != "":
						material_assignments[gid] = mname

	print("Loaded %d texture mappings, %d material assignments" % [texture_map.size(), material_assignments.size()])

	# Scan texture directory for PNG files and load directly from disk.
	# Uses Image.load() to bypass Godot's import pipeline —
	# textures added outside the editor won't have .import files yet.
	var tex_dir_abs := ProjectSettings.globalize_path(TEXTURE_DIR)
	var dir := DirAccess.open(TEXTURE_DIR)
	if dir == null:
		print("No texture directory found at %s" % TEXTURE_DIR)
		return

	# Two-pass loading: load all-lowercase filenames first (albedo textures),
	# then load mixed-case as fallback (specular/AO/other map channels).
	# DDS→PNG export produced both variants; the lowercase files are the albedo.
	var all_pngs: Array[String] = []
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname.ends_with(".png") and not fname.ends_with(".import"):
			all_pngs.append(fname)
		fname = dir.get_next()
	dir.list_dir_end()

	# Sort: all-lowercase filenames first, then mixed-case
	all_pngs.sort_custom(func(a: String, b: String) -> bool:
		var a_lower := (a == a.to_lower())
		var b_lower := (b == b.to_lower())
		if a_lower != b_lower:
			return a_lower  # lowercase names sort first
		return a < b
	)

	for png_fname in all_pngs:
		var tex_name := png_fname.get_basename()
		var abs_path := tex_dir_abs.path_join(png_fname)
		var img := Image.new()
		var err := img.load(abs_path)
		if err == OK:
			img.generate_mipmaps()
			var tex := ImageTexture.create_from_image(img)
			# Always store exact-case name
			loaded_textures[tex_name] = tex
			# Store lowercase alias ONLY if no albedo already claimed it.
			# Lowercase filenames are albedo textures from the DDS export;
			# mixed-case filenames are specular/AO/other channels.
			var lower := tex_name.to_lower()
			if not loaded_textures.has(lower):
				loaded_textures[lower] = tex
			tex_loaded_count += 1
	print("Loaded %d PNG textures from %s" % [tex_loaded_count, TEXTURE_DIR])


func _find_texture_for_material(mat_name: String) -> Texture2D:
	## Look up the texture for a material name through the NSA mapping chain.
	## material_name → texture_name (via texture_map) → Texture2D (via loaded_textures)
	var tex_name: String = texture_map.get(mat_name, "")
	if tex_name == "":
		# Try direct match (material name IS the texture name)
		tex_name = mat_name

	# Strip .dds extension if present
	if tex_name.ends_with(".dds"):
		tex_name = tex_name.substr(0, tex_name.length() - 4)

	# Try exact match
	if loaded_textures.has(tex_name):
		return loaded_textures[tex_name] as Texture2D

	# Try case-insensitive match
	if loaded_textures.has(tex_name.to_lower()):
		return loaded_textures[tex_name.to_lower()] as Texture2D

	return null


func _load_level(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("Cannot open level data: %s" % path)
		return

	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if not (parsed is Dictionary):
		push_error("Level data is not a dictionary")
		return

	var data: Dictionary = parsed
	var header: Dictionary = data.get("header", {})
	level_materials = header.get("materials", [])

	# level_center will be computed from actual vertex positions after loading
	var groups: Array = data.get("mesh_groups", [])

	# Section 12 is the combined level mesh (67% of tris, 37 materials).
	# Sections 0-11 are the per-section originals that overlap with 12.
	# Render ONLY section 12 to avoid doubled geometry.
	var filtered_groups: Array = []
	for raw_group in groups:
		if not (raw_group is Dictionary):
			continue
		var sec_id: int = int(raw_group.get("section_id", -1))
		if sec_id == 12:
			filtered_groups.append(raw_group)

	print("Loading %d mesh groups (section 12 only)..." % filtered_groups.size())

	# Track actual vertex bounds for correct camera placement
	var actual_min := Vector3(INF, INF, INF)
	var actual_max := Vector3(-INF, -INF, -INF)

	# Build a SINGLE ArrayMesh with multiple surfaces (one per submesh).
	# This eliminates Z-fighting: all surfaces share the same MeshInstance3D
	# and model transform, so coplanar geometry gets identical depth values.
	var combined_mesh := ArrayMesh.new()
	var surface_materials: Array = []
	var collision_faces := PackedVector3Array()

	for group in filtered_groups:
		var positions: Array = group.get("positions", [])
		# Track bounds from actual positions AFTER Z-up → Y-up remap
		for vi in range(0, positions.size(), 3):
			var jx: float = positions[vi]
			var jy: float = positions[vi + 1]
			var jz: float = positions[vi + 2]
			var gx := jx
			var gy := -jz
			var gz := -jy
			actual_min.x = minf(actual_min.x, gx)
			actual_min.y = minf(actual_min.y, gy)
			actual_min.z = minf(actual_min.z, gz)
			actual_max.x = maxf(actual_max.x, gx)
			actual_max.y = maxf(actual_max.y, gy)
			actual_max.z = maxf(actual_max.z, gz)
		var mat := _build_mesh_surface(combined_mesh, group, collision_faces)
		surface_materials.append(mat)

	# Apply materials to each surface
	for si in range(surface_materials.size()):
		if surface_materials[si] != null:
			combined_mesh.surface_set_material(si, surface_materials[si])

	# Create a single MeshInstance3D for the entire level
	var mi := MeshInstance3D.new()
	mi.mesh = combined_mesh
	mi.name = "LevelMesh"
	level_root.add_child(mi)

	# Generate trimesh collision from all faces
	if collision_faces.size() >= 9:
		var body := StaticBody3D.new()
		body.name = "LevelCollision"
		var shape := ConcavePolygonShape3D.new()
		shape.set_faces(collision_faces)
		var col := CollisionShape3D.new()
		col.shape = shape
		body.add_child(col)
		level_root.add_child(body)

	# Compute level center from actual vertex positions
	level_center = (actual_min + actual_max) * 0.5 * LEVEL_SCALE
	print("Level loaded: %d surfaces, %d verts, %d tris" % [combined_mesh.get_surface_count(), vert_count, tri_count])
	print("Actual bounds: min=(%.1f, %.1f, %.1f) max=(%.1f, %.1f, %.1f)" % [
		actual_min.x, actual_min.y, actual_min.z,
		actual_max.x, actual_max.y, actual_max.z])
	print("Level center: (%.1f, %.1f, %.1f)" % [level_center.x, level_center.y, level_center.z])

	# Position camera above the center, looking down at the level
	var extent := (actual_max - actual_min) * LEVEL_SCALE
	var cam_height := maxf(extent.x, extent.z) * 0.6
	cam.position = level_center + Vector3(0, cam_height, cam_height * 0.5)
	cam.look_at(level_center, Vector3.UP)
	# Extract pitch/yaw from resulting rotation
	var euler := cam.rotation
	pitch = euler.x
	yaw = euler.y


func _build_mesh_surface(combined_mesh: ArrayMesh, group: Dictionary, collision_faces: PackedVector3Array) -> StandardMaterial3D:
	## Add one surface to the combined level mesh. Returns the material for this surface.
	## Using a single ArrayMesh with multiple surfaces eliminates Z-fighting between
	## coplanar submeshes — they share the same MeshInstance3D transform.
	var positions: Array = group.get("positions", [])
	var normals: Array = group.get("normals", [])
	var uvs: Array = group.get("uvs", [])
	var indices: Array = group.get("indices", [])
	var v_count: int = group.get("vertex_count", 0)
	var t_count: int = group.get("triangle_count", 0)

	if v_count < 3 or positions.size() < 9:
		return null

	# Build packed arrays
	var pos_arr := PackedVector3Array()
	var norm_arr := PackedVector3Array()
	var uv_arr := PackedVector2Array()
	var idx_arr := PackedInt32Array()

	pos_arr.resize(v_count)
	norm_arr.resize(v_count)
	uv_arr.resize(v_count)

	for i in range(v_count):
		var i3 := i * 3
		var i2 := i * 2
		if i3 + 2 >= positions.size():
			break
		var jx: float = positions[i3]
		var jy: float = positions[i3 + 1]
		var jz: float = positions[i3 + 2]
		pos_arr[i] = Vector3(jx, -jz, -jy) * LEVEL_SCALE
		if i3 + 2 < normals.size():
			var nx: float = normals[i3]
			var ny: float = normals[i3 + 1]
			var nz: float = normals[i3 + 2]
			norm_arr[i] = Vector3(nx, -nz, -ny)
		if i2 + 1 < uvs.size():
			uv_arr[i] = Vector2(uvs[i2], uvs[i2 + 1])

	# Flip winding: DX uses CW front faces, Godot uses CCW.
	idx_arr.resize(indices.size())
	for i in range(0, indices.size() - 2, 3):
		idx_arr[i] = int(indices[i])
		idx_arr[i + 1] = int(indices[i + 2])
		idx_arr[i + 2] = int(indices[i + 1])

	# Add surface to combined mesh.
	# NOTE: NIL bytes at +28 are NOT display vertex colors (they contain packed
	# tangent/engine data with saturated rainbow values). Omit ARRAY_COLOR to
	# prevent any rendering artifacts from bogus color data.
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pos_arr
	arrays[Mesh.ARRAY_NORMAL] = norm_arr
	arrays[Mesh.ARRAY_TEX_UV] = uv_arr
	arrays[Mesh.ARRAY_INDEX] = idx_arr
	combined_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	# Accumulate collision faces for larger groups
	if t_count >= COLLISION_MIN_TRIS:
		for i in range(idx_arr.size()):
			collision_faces.append(pos_arr[idx_arr[i]])

	# Create material
	var mat := StandardMaterial3D.new()
	mat.cull_mode = BaseMaterial3D.CULL_BACK
	mat.roughness = 0.85
	mat.metallic = 0.05
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS

	var group_id: int = group.get("id", mesh_count)
	var has_texture := false
	if textured_mode:
		var mat_name: String = material_assignments.get(group_id, "")
		if mat_name == "":
			mat_name = material_assignments.get(str(group_id), "")
		if mat_name != "":
			var tex: Texture2D = _find_texture_for_material(mat_name)
			if tex != null:
				mat.albedo_texture = tex
				has_texture = true
				if "trans" in mat_name.to_lower():
					mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			else:
				print("[TEX] Group %d: mat='%s' -> texture NOT FOUND" % [group_id, mat_name])
		else:
			print("[TEX] Group %d: NO material assignment" % group_id)

	if not has_texture:
		mat.albedo_color = Color(0.5, 0.5, 0.5)

	mesh_count += 1
	vert_count += v_count
	tri_count += t_count
	return mat


func _apply_texture_mode() -> void:
	## Toggle textures on/off for all surfaces in the combined level mesh.
	var applied := 0
	for child in level_root.get_children():
		if child is MeshInstance3D:
			var mi := child as MeshInstance3D
			if mi.mesh == null:
				continue
			for si in range(mi.mesh.get_surface_count()):
				var mat := mi.mesh.surface_get_material(si)
				if mat is StandardMaterial3D:
					var smat := mat as StandardMaterial3D
					if not textured_mode:
						smat.albedo_texture = null
						smat.albedo_color = Color(0.5, 0.5, 0.5)
					else:
						applied += 1  # Textures already applied at load time
	var mode_str := "TEXTURED (%d)" % applied if textured_mode else "VERTEX COLORS"
	print("Texture mode: %s" % mode_str)


func _apply_shading_mode() -> void:
	## Toggle unshaded rendering for all level surfaces (debug visibility).
	for child in level_root.get_children():
		if child is MeshInstance3D:
			var mi := child as MeshInstance3D
			if mi.mesh == null:
				continue
			for si in range(mi.mesh.get_surface_count()):
				var mat := mi.mesh.surface_get_material(si)
				if mat is StandardMaterial3D:
					var smat := mat as StandardMaterial3D
					if unshaded_mode:
						smat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
					else:
						smat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	print("Shading: %s" % ("UNSHADED" if unshaded_mode else "SHADED"))


func _load_entities() -> void:
	## Load NSD entity placement data and spawn visual markers for each entity.
	entity_root = Node3D.new()
	entity_root.name = "Entities"
	add_child(entity_root)

	var f := FileAccess.open(NSD_ENTITIES_PATH, FileAccess.READ)
	if f == null:
		print("No NSD entity data found at %s" % NSD_ENTITIES_PATH)
		return

	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if not (parsed is Dictionary):
		push_error("NSD entity data is not a dictionary")
		return

	var data: Dictionary = parsed
	var entities: Array = data.get("entities", [])
	entity_total = entities.size()
	print("Loading %d NSD entities..." % entity_total)

	for raw_ent in entities:
		if not (raw_ent is Dictionary):
			continue
		var ent: Dictionary = raw_ent
		var ent_name: String = ent.get("name", "unknown")
		var pos_arr: Array = ent.get("position", [0, 0, 0])
		var category: String = ent.get("category", "other")
		# model_ref from enhanced NSD extraction (null if no model)
		var model_ref = ent.get("model_ref", null)
		# NSD positions are Z-up: remap to Godot Y-up: X=X, Y=Z, Z=-Y
		var pos := Vector3(pos_arr[0], pos_arr[2], -pos_arr[1]) * LEVEL_SCALE

		# Track category counts
		entity_counts[category] = entity_counts.get(category, 0) + 1

		# Player spawn — record it but also show marker
		if ent_name == "ghost" and player_spawn == Vector3.ZERO:
			player_spawn = pos

		# Spawn live entities for enemies, doors, pickups; markers for everything else
		if category == "enemy":
			_spawn_enemy(ent_name, pos, model_ref)
		elif category == "door":
			_spawn_door(ent_name, pos, model_ref)
		elif category == "pickup":
			_spawn_pickup(ent_name, pos, model_ref)
		else:
			_spawn_entity_marker(ent_name, pos, category, model_ref)

	# Summary
	var summary := "Entities: %d total" % entity_total
	summary += " | enemies: %d (AI)" % enemy_count
	summary += " | models: %d (glTF)" % models_loaded_count
	for cat in ["door", "pickup", "prop"]:
		if entity_counts.has(cat):
			summary += " | %s: %d" % [cat, entity_counts[cat]]
	var hidden := 0
	for cat in INVISIBLE_CATEGORIES:
		if entity_counts.has(cat):
			hidden += entity_counts[cat]
	summary += " | hidden: %d (game logic)" % hidden
	print(summary)

	# Move camera to player spawn if found
	if player_spawn != Vector3.ZERO:
		cam.position = player_spawn + Vector3(0, 8, 15)
		cam.look_at(player_spawn, Vector3.UP)
		var euler := cam.rotation
		pitch = euler.x
		yaw = euler.y
		print("Player spawn found at %s — camera repositioned" % str(player_spawn))


## Categories that are invisible game logic — never render markers for these.
## Includes: spawn points, AI paths, collision clips, move controllers, triggers, scripts.
const INVISIBLE_CATEGORIES := ["other", "trigger", "script", "geometry"]

## Specific entity names that are game logic even if their category seems visual.
## NOTE: Geometry types (instance_nocfile, instance_hull, etc.) are NO LONGER hidden —
## the enhanced NSD JSON now provides model_ref for these entities.
const INVISIBLE_ENTITIES := [
	"playerclip", "playerclip_prop_hull", "blockall",
	"cblastobj", "caifightpath", "cactorwalk",
	"t_track", "pathnode",
	"movetrack_hull_activate",
]

func _spawn_entity_marker(ent_name: String, pos: Vector3, category: String, model_ref = null) -> void:
	## Create a visual for an entity — loads a glTF model if available,
	## otherwise falls back to a colored box marker.
	## Game-logic entities (triggers, scripts, clips, paths) are invisible.
	var lower_name := ent_name.to_lower().replace(".nag", "")

	# Skip rendering for invisible game-logic entities entirely
	if category in INVISIBLE_CATEGORIES or lower_name in INVISIBLE_ENTITIES:
		# Only exception: "ghost" entity gets a small spawn marker
		if ent_name != "ghost":
			# BUT: if we have a model_ref from NSD, render it even in invisible categories
			if model_ref == null or model_ref is bool:
				return

	var marker := Node3D.new()
	marker.name = ent_name
	marker.position = pos

	# Try to load a real 3D model
	var model_loaded := false

	# Priority 1: Use model_ref from enhanced NSD JSON (highest confidence)
	if model_ref != null and model_ref is String and model_ref != "":
		var ref_base: String = (model_ref as String).get_basename()
		var ref_path := "res://assets/models_all/" + (model_ref as String)
		if model_index.has(ref_base.to_lower()):
			ref_path = model_index[ref_base.to_lower()]
		var model := _load_model_scene(ref_path)
		if model != null:
			model.name = "Model"
			marker.add_child(model)
			model_loaded = true
			models_loaded_count += 1

	# Priority 2: Fall back to name-based matching
	if not model_loaded:
		var model_path := _find_model_for_entity(ent_name)
		if model_path != "":
			var model := _load_model_scene(model_path)
			if model != null:
				model.name = "Model"
				marker.add_child(model)
				model_loaded = true
				models_loaded_count += 1

	if not model_loaded:
		# Fallback: only show markers for important entities (ghost spawn)
		if ent_name == "ghost":
			var mesh := BoxMesh.new()
			mesh.size = Vector3(0.6, 1.8, 0.6)
			var mat := StandardMaterial3D.new()
			mat.albedo_color = Color(1.0, 1.0, 1.0, 0.9)
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mesh.material = mat
			var mi := MeshInstance3D.new()
			mi.mesh = mesh
			mi.name = "Shape"
			marker.add_child(mi)
			var label := Label3D.new()
			label.text = "SPAWN"
			label.position = Vector3(0, 1.4, 0)
			label.pixel_size = 0.01
			label.font_size = 24
			label.modulate = Color(1.0, 1.0, 1.0, 0.9)
			label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			label.no_depth_test = true
			label.name = "Label"
			marker.add_child(label)
		elif category == "prop":
			# Props without models get a small orange marker
			var mesh := BoxMesh.new()
			mesh.size = Vector3(0.3, 0.3, 0.3)
			var mat := StandardMaterial3D.new()
			mat.albedo_color = Color(0.9, 0.6, 0.2, 0.5)
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mesh.material = mat
			var mi := MeshInstance3D.new()
			mi.mesh = mesh
			mi.name = "Shape"
			marker.add_child(mi)
		else:
			# All other unmatched entities: no visual at all
			return

	entity_root.add_child(marker)


func _spawn_enemy(ent_name: String, pos: Vector3, model_ref = null) -> void:
	## Spawn a live enemy with AI at the given position.
	var packed = load(ENEMY_SCENE)
	if not (packed is PackedScene):
		push_warning("Cannot load enemy scene")
		_spawn_entity_marker(ent_name, pos, "enemy", model_ref)
		return

	var enemy := (packed as PackedScene).instantiate() as CharacterBody3D
	if enemy == null:
		_spawn_entity_marker(ent_name, pos, "enemy", model_ref)
		return

	enemy.position = pos
	enemy.name = "%s_%d" % [ent_name, enemy_count]

	# Set model path: ENEMY_MODELS first, then model_ref from NSD
	var base_type := ent_name.to_lower()
	if ENEMY_MODELS.has(base_type):
		enemy.set("model_path", ENEMY_MODELS[base_type])
	elif model_ref != null and model_ref is String and model_ref != "":
		var ref_base: String = (model_ref as String).get_basename()
		if model_index.has(ref_base.to_lower()):
			enemy.set("model_path", model_index[ref_base.to_lower()])
		else:
			enemy.set("model_path", "res://assets/models_all/" + (model_ref as String))
	enemy.set("enemy_type", ent_name)

	# Apply stats for this enemy type
	if ENEMY_STATS.has(base_type):
		var stats: Dictionary = ENEMY_STATS[base_type]
		enemy.set("health", stats.get("health", 100.0))
		enemy.set("max_health", stats.get("health", 100.0))
		enemy.set("move_speed", stats.get("speed", 4.0))
		enemy.set("chase_speed", stats.get("chase_speed", 7.0))
		enemy.set("detection_range", stats.get("range", 25.0))
		enemy.set("attack_range", stats.get("attack_range", 3.0))
		enemy.set("attack_damage", stats.get("damage", 10.0))

	entity_root.add_child(enemy)
	enemy_count += 1


func _spawn_door(ent_name: String, pos: Vector3, model_ref = null) -> void:
	## Spawn an interactive door/console/ladder at the given position.
	var door_script = load("res://scripts/door_trigger.gd")
	if door_script == null:
		_spawn_entity_marker(ent_name, pos, "door", model_ref)
		return

	var door := Node3D.new()
	door.set_script(door_script)
	door.position = pos
	door.name = ent_name

	# Determine door type from entity name
	var lower_name := ent_name.to_lower()
	if "ladder" in lower_name:
		door.set("door_type", 2)  # DoorType.LADDER
		door.set("interaction_text", "Press F to climb")
	elif "hack" in lower_name or "console" in lower_name:
		door.set("door_type", 1)  # DoorType.HACK_CONSOLE
		door.set("interaction_text", "Press F to hack")
	elif "elevator" in lower_name or "lift" in lower_name:
		door.set("door_type", 3)  # DoorType.ELEVATOR
		door.set("interaction_text", "Press F to activate")
	else:
		door.set("door_type", 0)  # DoorType.DOOR
		door.set("interaction_text", "Press F to open")

	door.set("door_name", ent_name)

	# Use model_ref from NSD extraction, fallback to name-based matching
	var model_path := ""
	if model_ref != null and model_ref is String and model_ref != "":
		var ref_base: String = (model_ref as String).get_basename()
		if model_index.has(ref_base.to_lower()):
			model_path = model_index[ref_base.to_lower()]
	if model_path == "":
		model_path = _find_model_for_entity(ent_name)
	if model_path != "":
		door.set("model_path", model_path)

	entity_root.add_child(door)


func _spawn_pickup(ent_name: String, pos: Vector3, model_ref = null) -> void:
	## Spawn a collectible pickup at the given position.
	var pickup_script = load("res://scripts/pickup_item.gd")
	if pickup_script == null:
		_spawn_entity_marker(ent_name, pos, "pickup", model_ref)
		return

	var pickup := Node3D.new()
	pickup.set_script(pickup_script)
	pickup.position = pos
	pickup.name = ent_name
	pickup.set("pickup_name", ent_name)

	# Priority 1: model_ref from enhanced NSD JSON
	var resolved_path := ""
	if model_ref != null and model_ref is String and model_ref != "":
		var ref_base: String = (model_ref as String).get_basename()
		if model_index.has(ref_base.to_lower()):
			resolved_path = model_index[ref_base.to_lower()]
		else:
			resolved_path = "res://assets/models_all/" + (model_ref as String)

	# Priority 2: name-based matching fallback
	if resolved_path == "":
		resolved_path = _find_model_for_entity(ent_name)

	if resolved_path != "":
		pickup.set("model_path", resolved_path)

	entity_root.add_child(pickup)


func _setup_environment() -> void:
	# World environment — dark sci-fi bunker (reference: moody orange/blue industrial)
	var world_env := WorldEnvironment.new()
	world_env.name = "WorldEnvironment"
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.02, 0.025, 0.04)  # Near-black
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.3, 0.32, 0.4)  # Cool blue-gray ambient
	env.ambient_light_energy = 0.8
	# Fog for depth/atmosphere
	env.fog_enabled = true
	env.fog_light_color = Color(0.08, 0.09, 0.12)
	env.fog_density = 0.003
	# Tonemap
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.1
	# Glow for light bloom
	env.glow_enabled = true
	env.glow_intensity = 0.3
	env.glow_bloom = 0.1
	world_env.environment = env
	add_child(world_env)

	# Main overhead light — warm industrial (orange-ish like bunker fluorescents)
	var sun := DirectionalLight3D.new()
	sun.name = "KeyLight"
	sun.light_color = Color(1.0, 0.85, 0.65)  # Warm orange
	sun.light_energy = 1.5
	sun.rotation_degrees = Vector3(-55, -30, 0)
	sun.shadow_enabled = true
	add_child(sun)

	# Cool fill from below (metal floor bounce)
	var fill := DirectionalLight3D.new()
	fill.name = "FillLight"
	fill.light_color = Color(0.4, 0.5, 0.65)  # Cool blue
	fill.light_energy = 0.4
	fill.rotation_degrees = Vector3(60, 150, 0)
	fill.shadow_enabled = false
	add_child(fill)


func _setup_audio() -> void:
	ambient_player = AudioStreamPlayer.new()
	ambient_player.name = "AmbientPlayer"
	ambient_player.volume_db = -6.0
	add_child(ambient_player)

	# Scan level audio dir first, then music dir as fallback
	for scan_dir in [LEVEL_AUDIO_DIR, "res://assets/audio/music/", "res://assets/audio/ambient/"]:
		var dir := DirAccess.open(scan_dir)
		if dir == null:
			continue
		dir.list_dir_begin()
		var fname := dir.get_next()
		while fname != "":
			if fname.ends_with(".wav") and not fname.ends_with(".import"):
				audio_tracks.append(scan_dir + fname)
			fname = dir.get_next()
		dir.list_dir_end()
	audio_tracks.sort()
	print("Found %d audio tracks for level" % audio_tracks.size())

	# Auto-play first track as ambient loop
	if audio_tracks.size() > 0:
		_play_audio_track(0)

	ambient_player.finished.connect(_on_ambient_finished)


func _play_audio_track(idx: int) -> void:
	if audio_tracks.is_empty():
		return
	audio_idx = wrapi(idx, 0, audio_tracks.size())
	var stream = load(audio_tracks[audio_idx])
	if stream is AudioStream:
		ambient_player.stream = stream
		ambient_player.play()
		audio_playing = true


func _on_ambient_finished() -> void:
	# Auto-advance to next track
	if audio_playing:
		_play_audio_track(audio_idx + 1)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and mouse_captured and not player_mode:
		var motion := event as InputEventMouseMotion
		yaw -= motion.relative.x * mouse_sensitivity
		pitch -= motion.relative.y * mouse_sensitivity
		pitch = clampf(pitch, -PI * 0.49, PI * 0.49)
		cam.rotation = Vector3(pitch, yaw, 0)

	if event is InputEventKey:
		var key := event as InputEventKey
		if key.pressed and not key.echo:
			if key.keycode == KEY_ESCAPE:
				if mouse_captured:
					Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
					mouse_captured = false
				else:
					Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
					mouse_captured = true
			elif key.keycode == KEY_F and not player_mode:
				# Toggle fog (only in free-fly — F is used for door interaction in player mode)
				var we := get_node_or_null("WorldEnvironment") as WorldEnvironment
				if we and we.environment:
					we.environment.fog_enabled = not we.environment.fog_enabled
					_update_hud()
			elif key.keycode == KEY_L:
				# Toggle shadows
				var key_light := get_node_or_null("KeyLight") as DirectionalLight3D
				if key_light:
					key_light.shadow_enabled = not key_light.shadow_enabled
					_update_hud()
			elif key.keycode == KEY_P:
				_toggle_player_mode()
			elif key.keycode == KEY_N:
				_play_audio_track(audio_idx + 1)
				_update_hud()
			elif key.keycode == KEY_ENTER or key.keycode == KEY_KP_ENTER:
				if audio_playing:
					ambient_player.stop()
					audio_playing = false
				else:
					_play_audio_track(audio_idx)
				_update_hud()
			elif key.keycode == KEY_T:
				# Toggle textured mode
				textured_mode = not textured_mode
				_apply_texture_mode()
				_update_hud()
			elif key.keycode == KEY_E:
				# Toggle entity markers
				entities_visible = not entities_visible
				if entity_root:
					entity_root.visible = entities_visible
				_update_hud()
			elif key.keycode == KEY_U:
				# Toggle unshaded debug mode
				unshaded_mode = not unshaded_mode
				_apply_shading_mode()
				_update_hud()
			elif key.keycode == KEY_B:
				get_tree().change_scene_to_file("res://scenes/Main.tscn")

	if event is InputEventMouseButton and not mouse_captured:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			mouse_captured = true


func _process(delta: float) -> void:
	_ss_frame += 1
	# Auto-screenshot on frame 30 (allow time for models to render)
	if _ss_frame == 30:
		get_viewport().get_texture().get_image().save_png("/tmp/godot_level_shot.png")
		print("Screenshot saved to /tmp/godot_level_shot.png")
	if not mouse_captured or player_mode:
		return

	var speed := fly_fast_speed if Input.is_key_pressed(KEY_SHIFT) else fly_speed
	var dir := Vector3.ZERO

	if Input.is_key_pressed(KEY_W):
		dir -= cam.global_transform.basis.z
	if Input.is_key_pressed(KEY_S):
		dir += cam.global_transform.basis.z
	if Input.is_key_pressed(KEY_A):
		dir -= cam.global_transform.basis.x
	if Input.is_key_pressed(KEY_D):
		dir += cam.global_transform.basis.x
	if Input.is_key_pressed(KEY_SPACE):
		dir += Vector3.UP
	if Input.is_key_pressed(KEY_CTRL):
		dir -= Vector3.UP

	if dir.length_squared() > 0.01:
		dir = dir.normalized()
		cam.position += dir * speed * delta
		_update_hud()  # Update cam position display


func _toggle_player_mode() -> void:
	player_mode = not player_mode
	if player_mode:
		# Spawn player
		if player_node == null:
			var packed = load(PLAYER_SCENE)
			if packed is PackedScene:
				player_node = (packed as PackedScene).instantiate() as CharacterBody3D
		if player_node != null:
			if player_node.get_parent() == null:
				add_child(player_node)
			# Use player_spawn if available, otherwise camera position
			# Offset Y+5 above spawn point to clear any collision geometry
			# (NSD spawn points sit ON the floor surface — need clearance for capsule)
			if player_spawn != Vector3.ZERO and player_node.position == Vector3.ZERO:
				player_node.position = player_spawn + Vector3(0, 5.0, 0)
			else:
				player_node.position = cam.position - Vector3(0, 2, 0)
			# Explicitly disable free-fly camera and activate player camera
			cam.current = false
			var player_cam := player_node.get_node_or_null("CameraPivot/Camera3D") as Camera3D
			if player_cam:
				player_cam.current = true
				print("[Player] Camera activated: %s" % str(player_cam))
			player_mode = true
			# Recapture mouse for player controls
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			mouse_captured = true
			print("Switched to PLAYER mode at %s" % str(player_node.position))
	else:
		# Switch back to free-fly
		if player_node != null and player_node.get_parent() != null:
			cam.position = player_node.position + Vector3(0, 5, 10)
			player_node.get_parent().remove_child(player_node)
		cam.current = true
		player_mode = false
		print("Switched to FREE-FLY mode")
	_update_hud()


func _update_hud() -> void:
	var fog_state := "OFF"
	var shadow_state := "OFF"
	var we := get_node_or_null("WorldEnvironment") as WorldEnvironment
	if we and we.environment and we.environment.fog_enabled:
		fog_state = "ON"
	var key_light := get_node_or_null("KeyLight") as DirectionalLight3D
	if key_light and key_light.shadow_enabled:
		shadow_state = "ON"

	var mode_str := "PLAYER (3rd person)" if player_mode else "FREE-FLY"
	var audio_str := "OFF"
	if audio_playing and audio_tracks.size() > 0:
		audio_str = "Track %d/%d" % [audio_idx + 1, audio_tracks.size()]
	var tex_str := "ON (%d tex)" % tex_loaded_count if textured_mode else "OFF"
	var shade_str := "UNSHADED" if unshaded_mode else "SHADED"
	var ent_str := "ON" if entities_visible else "OFF"
	var ent_summary := ""
	if entity_total > 0:
		ent_summary = "Entities: %d | Enemies: %d (live AI) | Models: %d" % [entity_total, enemy_count, models_loaded_count]
		for cat in ["pickup", "door", "trigger"]:
			if entity_counts.has(cat):
				ent_summary += " | %s: %d" % [cat, entity_counts[cat]]
	hud_label.text = "\n".join([
		"StarCraft: Ghost — Miners Bunker (1_2_1)",
		"Meshes: %d | Vertices: %d | Triangles: %d" % [mesh_count, vert_count, tri_count],
		ent_summary,
		"Mode: %s | Audio: %s | Textures: %s" % [mode_str, audio_str, tex_str],
		"",
		"WASD = move | Mouse = look | Shift = fast",
		"Space = jump/up | Ctrl = down | Esc = release mouse",
		"P = player/free-fly | N = next track | Enter = play/stop",
		"T = textures (%s) | E = entities (%s) | F = fog (%s) | L = shadows (%s)" % [tex_str, ent_str, fog_state, shadow_state],
		"U = unshaded (%s) | V = noclip | G = flashlight | B = back to browser" % shade_str,
		"Cam: (%.0f, %.0f, %.0f) | Center: (%.0f, %.0f, %.0f)" % [cam.position.x, cam.position.y, cam.position.z, level_center.x, level_center.y, level_center.z],
	])
