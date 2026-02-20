extends Node3D
## NIL Level Loader — loads level geometry from parser JSON output.
##
## Reads compact JSON produced by nil_parser.py (flat arrays for
## positions, normals, colors, uvs, indices) and builds ArrayMesh
## instances. Generates trimesh collision for walkable surfaces.

const LEVEL_DATA_PATH := "res://data/level_1_2_1.json"
const PLAYER_SCENE := "res://scenes/Player.tscn"

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

# Camera fly controls
var fly_speed: float = 20.0
var fly_fast_speed: float = 60.0
var mouse_sensitivity: float = 0.002
var pitch: float = 0.0
var yaw: float = 0.0
var mouse_captured: bool = true


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_load_level(LEVEL_DATA_PATH)
	_setup_environment()
	_setup_audio()
	_update_hud()


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

	# Create material with vertex colors
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.roughness = 0.85
	mat.metallic = 0.05
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

	# Scan for audio tracks
	var dir := DirAccess.open(LEVEL_AUDIO_DIR)
	if dir == null:
		print("No audio directory found")
		return
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname.ends_with(".wav") and not fname.ends_with(".import"):
			audio_tracks.append(LEVEL_AUDIO_DIR + fname)
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
	hud_label.text = "\n".join([
		"StarCraft: Ghost — Miners Bunker (1_2_1)",
		"Meshes: %d | Vertices: %d | Triangles: %d" % [mesh_count, vert_count, tri_count],
		"Mode: %s | Audio: %s" % [mode_str, audio_str],
		"",
		"WASD = move | Mouse = look | Shift = fast",
		"Space = jump/up | Ctrl = down | Esc = release mouse",
		"P = player/free-fly | N = next track | Enter = play/stop",
		"T = flashlight | F = fog (%s) | L = shadows (%s)" % [fog_state, shadow_state],
		"B = back to browser",
	])
