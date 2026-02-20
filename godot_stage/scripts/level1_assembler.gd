extends Node3D

const MODEL_CATALOG_PATH := "res://data/proper_model_catalog.json"
const AUDIO_CATALOG_PATH := "res://data/audio_catalog.json"

const ENV_TOKENS = [
	"121", "1_2_1", "trench", "bridge", "catwalk", "platform", "hangar",
	"hallway", "room", "corridor", "deck", "door", "wall", "floor", "stair", "support",
	"cliff", "tower", "base", "pylon", "elevator"
]
const PROP_TOKENS = [
	"crate", "barrel", "lamp", "console", "panel", "pipe", "vent", "generator", "antenna",
	"canister", "cable", "fan", "lift", "turret", "terminal", "rifle", "grenade",
	"dropship", "vulture", "tank", "wraith", "battlecruiser"
]
const ACTOR_TOKENS = [
	"nova", "ghost", "marine", "zerg", "hydralisk", "firebat", "dragoon", "observer",
	"goliath", "zergling", "zealot", "siege", "banshee"
]
const AVOID_TOKENS = [
	"physclip", "_phys", "_clip", "_pclip", "collision", "muzzle", "fx", "decal",
	"shaderball", "dflt", "collide", "pclip", "testmodel"
]
const AMBIENT_TOKENS = [
	"env_", "ambient", "battle_lp", "music_", "wind", "alarm", "machinery", "loop"
]

const MAX_ENV := 12
const MAX_PROPS := 12
const MAX_ACTORS := 5
const DEFAULT_PROXY_MODE := false
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
	print("LEVEL1_READY: proper glTF mesh mode (proxy=%s)" % str(use_proxy_mode))
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
		use_proxy_mode = not use_proxy_mode
		_rebuild_level()
		_refresh_info()
	elif key_event.keycode == KEY_B:
		get_tree().change_scene_to_file("res://scenes/Main.tscn")


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
	if mode != "triangle" and mode != "skinned":
		return ""
	var tri_count := int(item.get("triangle_count", 0))
	if tri_count <= 0 or tri_count > 12000:
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
	if ("121" in text or "1_2_1" in text):
		return "env"
	if mode == "skinned":
		return "actors"
	return "props"


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
	if use_proxy_mode:
		return _build_proxy_instance(klass)

	var resource_path := str(item.get("resource_path", ""))
	if resource_path == "":
		return _build_proxy_instance(klass)

	var packed = load(resource_path)
	if packed is PackedScene:
		var inst = (packed as PackedScene).instantiate()
		if inst != null:
			return inst
		push_warning("GLTF instantiate failed: %s" % resource_path)

	# Fallback to proxy if load fails
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
	var visual_mode := "REAL MESH (proper glTF)" if not use_proxy_mode else "proxy (boxes/capsules)"
	var audio_mode := "wav assets"
	if DISABLE_RUNTIME_AUDIO:
		audio_mode = "off"
	elif USE_SAFE_SYNTH_AUDIO:
		audio_mode = "safe tone synth"
	info_label.text = "\n".join([
		"Ghost Level1 Assembler — StarCraft Ghost Port",
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
		"G = toggle REAL mesh / proxy mode",
		"B = model/audio browser",
	])


func _read_json_array(path: String) -> Array:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var parsed = JSON.parse_string(f.get_as_text())
	if parsed is Array:
		return parsed
	return []
