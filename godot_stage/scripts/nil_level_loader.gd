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
const NSD_ENTITIES_PATH := "res://data/nsd_entities_1_2_1.json"
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

# Texture system
var texture_map: Dictionary = {}  # material_name → texture_name (from NSA)
var loaded_textures: Dictionary = {}  # texture_name → Texture2D
var material_assignments: Dictionary = {}  # group_id → material_name
var level_materials: Array = []  # material names from NIL header
var textured_mode: bool = true  # Toggle between textured and vertex-color-only
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
	_load_textures()
	_load_level(LEVEL_DATA_PATH)
	_load_entities()
	_setup_environment()
	_setup_audio()
	_update_hud()


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

	# Scan texture directory for PNG files and preload
	var dir := DirAccess.open(TEXTURE_DIR)
	if dir == null:
		print("No texture directory found at %s" % TEXTURE_DIR)
		return

	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname.ends_with(".png") and not fname.ends_with(".import"):
			var tex_name := fname.get_basename()  # Remove .png extension
			var tex_path := TEXTURE_DIR + fname
			var tex = load(tex_path)
			if tex is Texture2D:
				loaded_textures[tex_name] = tex
				# Also store lowercase variant for case-insensitive lookup
				loaded_textures[tex_name.to_lower()] = tex
				tex_loaded_count += 1
		fname = dir.get_next()
	dir.list_dir_end()
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

	var stats: Dictionary = data.get("stats", {})
	var bbox_min: Array = stats.get("bbox_min", [0, 0, 0])
	var bbox_max: Array = stats.get("bbox_max", [0, 0, 0])

	# Compute level center for camera placement
	level_center = Vector3(
		(bbox_min[0] + bbox_max[0]) * 0.5,
		(bbox_min[1] + bbox_max[1]) * 0.5,
		(bbox_min[2] + bbox_max[2]) * 0.5
	) * LEVEL_SCALE

	var groups: Array = data.get("mesh_groups", [])
	print("Loading %d mesh groups..." % groups.size())

	for raw_group in groups:
		if not (raw_group is Dictionary):
			continue
		var group: Dictionary = raw_group
		_build_mesh_group(group)

	print("Level loaded: %d meshes, %d verts, %d tris" % [mesh_count, vert_count, tri_count])

	# Position camera above the center, looking down at the level
	cam.position = level_center + Vector3(0, 30, 40)
	cam.look_at(level_center, Vector3.UP)
	# Extract pitch/yaw from resulting rotation
	var euler := cam.rotation
	pitch = euler.x
	yaw = euler.y


func _build_mesh_group(group: Dictionary) -> void:
	var positions: Array = group.get("positions", [])
	var normals: Array = group.get("normals", [])
	var colors: Array = group.get("colors", [])
	var uvs: Array = group.get("uvs", [])
	var indices: Array = group.get("indices", [])
	var v_count: int = group.get("vertex_count", 0)
	var t_count: int = group.get("triangle_count", 0)

	if v_count < 3 or positions.size() < 9:
		return

	# Build packed arrays
	var pos_arr := PackedVector3Array()
	var norm_arr := PackedVector3Array()
	var color_arr := PackedColorArray()
	var uv_arr := PackedVector2Array()
	var idx_arr := PackedInt32Array()

	pos_arr.resize(v_count)
	norm_arr.resize(v_count)
	color_arr.resize(v_count)
	uv_arr.resize(v_count)

	for i in range(v_count):
		var i3 := i * 3
		var i4 := i * 4
		var i2 := i * 2
		if i3 + 2 >= positions.size():
			break
		pos_arr[i] = Vector3(positions[i3], positions[i3 + 1], positions[i3 + 2]) * LEVEL_SCALE
		if i3 + 2 < normals.size():
			norm_arr[i] = Vector3(normals[i3], normals[i3 + 1], normals[i3 + 2])
		if i4 + 3 < colors.size():
			color_arr[i] = Color(
				colors[i4] / 255.0,
				colors[i4 + 1] / 255.0,
				colors[i4 + 2] / 255.0,
				colors[i4 + 3] / 255.0
			)
		if i2 + 1 < uvs.size():
			uv_arr[i] = Vector2(uvs[i2], uvs[i2 + 1])

	idx_arr.resize(indices.size())
	for i in range(indices.size()):
		idx_arr[i] = int(indices[i])

	# Build ArrayMesh
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pos_arr
	arrays[Mesh.ARRAY_NORMAL] = norm_arr
	arrays[Mesh.ARRAY_COLOR] = color_arr
	arrays[Mesh.ARRAY_TEX_UV] = uv_arr
	arrays[Mesh.ARRAY_INDEX] = idx_arr

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	# Create material — try to apply texture from NSA mapping
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.roughness = 0.85
	mat.metallic = 0.05

	var group_id: int = group.get("id", mesh_count)
	if textured_mode:
		var mat_name: String = material_assignments.get(group_id, "")
		if mat_name != "":
			var tex: Texture2D = _find_texture_for_material(mat_name)
			if tex != null:
				mat.albedo_texture = tex
				# Blend texture with vertex colors for material tinting
				mat.vertex_color_use_as_albedo = true

	mesh.surface_set_material(0, mat)

	# Create MeshInstance3D
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.name = "Mesh_%d" % group.get("id", mesh_count)
	level_root.add_child(mi)

	# Generate trimesh collision for larger mesh groups
	if t_count >= COLLISION_MIN_TRIS:
		var body := StaticBody3D.new()
		body.name = "Collision_%d" % group.get("id", mesh_count)
		var shape := ConcavePolygonShape3D.new()
		# Build face array from indices
		var faces := PackedVector3Array()
		faces.resize(idx_arr.size())
		for i in range(idx_arr.size()):
			faces[i] = pos_arr[idx_arr[i]]
		shape.set_faces(faces)
		var col := CollisionShape3D.new()
		col.shape = shape
		body.add_child(col)
		level_root.add_child(body)

	mesh_count += 1
	vert_count += v_count
	tri_count += t_count


func _apply_texture_mode() -> void:
	## Toggle textures on/off for all mesh instances.
	var applied := 0
	for child in level_root.get_children():
		if child is MeshInstance3D:
			var mi := child as MeshInstance3D
			if mi.mesh == null or mi.mesh.get_surface_count() < 1:
				continue
			var mat := mi.mesh.surface_get_material(0)
			if mat is StandardMaterial3D:
				var smat := mat as StandardMaterial3D
				if textured_mode:
					# Re-apply texture from assignment
					var name_parts := mi.name.split("_")
					if name_parts.size() >= 2:
						var gid := int(name_parts[1])
						var mat_name: String = material_assignments.get(gid, "")
						if mat_name != "":
							var tex: Texture2D = _find_texture_for_material(mat_name)
							if tex != null:
								smat.albedo_texture = tex
								applied += 1
				else:
					smat.albedo_texture = null
	var mode_str := "TEXTURED (%d)" % applied if textured_mode else "VERTEX COLORS"
	print("Texture mode: %s" % mode_str)


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
		var pos := Vector3(pos_arr[0], pos_arr[1], pos_arr[2]) * LEVEL_SCALE

		# Track category counts
		entity_counts[category] = entity_counts.get(category, 0) + 1

		# Player spawn — record it but also show marker
		if ent_name == "ghost" and player_spawn == Vector3.ZERO:
			player_spawn = pos

		# Spawn live entities for enemies, doors, pickups; markers for everything else
		if category == "enemy":
			_spawn_enemy(ent_name, pos)
		elif category == "door":
			_spawn_door(ent_name, pos)
		elif category == "pickup":
			_spawn_pickup(ent_name, pos)
		else:
			_spawn_entity_marker(ent_name, pos, category)

	# Summary
	var summary := "Entities loaded: %d total" % entity_total
	for cat in entity_counts:
		summary += " | %s: %d" % [cat, entity_counts[cat]]
	print(summary)

	# Move camera to player spawn if found
	if player_spawn != Vector3.ZERO:
		cam.position = player_spawn + Vector3(0, 8, 15)
		cam.look_at(player_spawn, Vector3.UP)
		var euler := cam.rotation
		pitch = euler.x
		yaw = euler.y
		print("Player spawn found at %s — camera repositioned" % str(player_spawn))


func _spawn_entity_marker(ent_name: String, pos: Vector3, category: String) -> void:
	## Create a colored 3D marker for an entity at the given position.
	var marker := Node3D.new()
	marker.name = ent_name
	marker.position = pos

	# Category → color + shape
	var color: Color
	var marker_size: Vector3
	match category:
		"enemy":
			color = Color(1.0, 0.15, 0.1, 0.85)       # Red
			marker_size = Vector3(0.6, 1.8, 0.6)       # Tall capsule-ish
		"pickup":
			color = Color(0.1, 1.0, 0.2, 0.85)         # Green
			marker_size = Vector3(0.5, 0.5, 0.5)       # Small cube
		"door":
			color = Color(0.2, 0.4, 1.0, 0.85)         # Blue
			marker_size = Vector3(1.5, 2.5, 0.3)       # Tall flat panel
		"trigger":
			color = Color(1.0, 0.9, 0.1, 0.4)          # Yellow translucent
			marker_size = Vector3(2.0, 2.0, 2.0)       # Large zone
		"geometry":
			color = Color(0.5, 0.5, 0.5, 0.5)          # Gray
			marker_size = Vector3(0.4, 0.4, 0.4)
		"script":
			color = Color(0.8, 0.4, 1.0, 0.4)          # Purple
			marker_size = Vector3(0.3, 0.3, 0.3)
		"prop":
			color = Color(0.9, 0.6, 0.2, 0.7)          # Orange
			marker_size = Vector3(0.5, 0.5, 0.5)
		_:
			if ent_name == "ghost":
				color = Color(1.0, 1.0, 1.0, 0.9)      # White for player spawn
				marker_size = Vector3(0.6, 1.8, 0.6)
			else:
				color = Color(0.6, 0.6, 0.6, 0.3)      # Dim gray
				marker_size = Vector3(0.3, 0.3, 0.3)

	# Create mesh (BoxMesh for simplicity — fast to render for 315 entities)
	var mesh := BoxMesh.new()
	mesh.size = marker_size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA if color.a < 1.0 else BaseMaterial3D.TRANSPARENCY_DISABLED
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = (category == "trigger")  # Triggers show through walls
	mesh.material = mat

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.name = "Shape"
	marker.add_child(mi)

	# Add label above the marker
	if category in ["enemy", "pickup", "door"] or ent_name == "ghost":
		var label := Label3D.new()
		label.text = ent_name
		label.position = Vector3(0, marker_size.y * 0.5 + 0.4, 0)
		label.pixel_size = 0.01
		label.font_size = 24
		label.modulate = color
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.no_depth_test = true
		label.name = "Label"
		marker.add_child(label)

	entity_root.add_child(marker)


func _spawn_enemy(ent_name: String, pos: Vector3) -> void:
	## Spawn a live enemy with AI at the given position.
	var packed = load(ENEMY_SCENE)
	if not (packed is PackedScene):
		push_warning("Cannot load enemy scene")
		_spawn_entity_marker(ent_name, pos, "enemy")
		return

	var enemy := (packed as PackedScene).instantiate() as CharacterBody3D
	if enemy == null:
		_spawn_entity_marker(ent_name, pos, "enemy")
		return

	enemy.position = pos
	enemy.name = "%s_%d" % [ent_name, enemy_count]

	# Set model path if available
	var base_type := ent_name.to_lower()
	if ENEMY_MODELS.has(base_type):
		enemy.set("model_path", ENEMY_MODELS[base_type])
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


func _spawn_door(ent_name: String, pos: Vector3) -> void:
	## Spawn an interactive door/console/ladder at the given position.
	var door_script = load("res://scripts/door_trigger.gd")
	if door_script == null:
		_spawn_entity_marker(ent_name, pos, "door")
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
	entity_root.add_child(door)


func _spawn_pickup(ent_name: String, pos: Vector3) -> void:
	## Spawn a collectible pickup at the given position.
	var pickup_script = load("res://scripts/pickup_item.gd")
	if pickup_script == null:
		_spawn_entity_marker(ent_name, pos, "pickup")
		return

	var pickup := Node3D.new()
	pickup.set_script(pickup_script)
	pickup.position = pos
	pickup.name = ent_name
	pickup.set("pickup_name", ent_name)
	entity_root.add_child(pickup)


func _setup_environment() -> void:
	# World environment — dark sci-fi bunker
	var world_env := WorldEnvironment.new()
	world_env.name = "WorldEnvironment"
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.02, 0.03, 0.04)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.35, 0.38, 0.42)
	env.ambient_light_energy = 0.6
	# Fog for atmosphere
	env.fog_enabled = true
	env.fog_light_color = Color(0.08, 0.10, 0.14)
	env.fog_density = 0.003
	# Tonemap
	env.tonemap_mode = Environment.TONE_MAP_ACES
	env.tonemap_exposure = 1.1
	world_env.environment = env
	add_child(world_env)

	# Directional light (simulating overhead bunker lights)
	var sun := DirectionalLight3D.new()
	sun.name = "KeyLight"
	sun.light_color = Color(0.75, 0.78, 0.82)
	sun.light_energy = 1.4
	sun.rotation_degrees = Vector3(-45, -30, 0)
	sun.shadow_enabled = true
	add_child(sun)

	# Fill light from below (bounce simulation)
	var fill := DirectionalLight3D.new()
	fill.name = "FillLight"
	fill.light_color = Color(0.4, 0.35, 0.3)
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
			elif key.keycode == KEY_F:
				# Toggle fog
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
			elif key.keycode == KEY_B:
				get_tree().change_scene_to_file("res://scenes/Main.tscn")

	if event is InputEventMouseButton and not mouse_captured:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			mouse_captured = true


func _process(delta: float) -> void:
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


func _toggle_player_mode() -> void:
	player_mode = not player_mode
	if player_mode:
		# Spawn player at camera position
		if player_node == null:
			var packed = load(PLAYER_SCENE)
			if packed is PackedScene:
				player_node = (packed as PackedScene).instantiate() as CharacterBody3D
		if player_node != null:
			if player_node.get_parent() == null:
				add_child(player_node)
			player_node.position = cam.position - Vector3(0, 2, 0)
			cam.current = false
			player_mode = true
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
	var ent_str := "ON" if entities_visible else "OFF"
	var ent_summary := ""
	if entity_total > 0:
		ent_summary = "Entities: %d | Enemies: %d (live AI)" % [entity_total, enemy_count]
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
		"B = back to browser",
	])
