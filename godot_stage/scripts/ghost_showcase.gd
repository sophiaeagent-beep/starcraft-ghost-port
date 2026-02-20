extends Node3D
## Ghost Showcase — Nova vs Zerg battle scene
## Loads proper reverse-engineered NOD mesh models from StarCraft: Ghost

const MODELS := {
	"nova": "res://assets/models_test/nova.gltf",
	"ghost_male": "res://assets/models_test/Ghost_male.gltf",
	"zergling": "res://assets/models_test/zergling.gltf",
	"hydralisk": "res://assets/models_test/hydralisk.gltf",
	"rifle": "res://assets/models_test/gaussRifle_1.gltf",
	"trench_long": "res://assets/models_test/121_TrenchLong_01.gltf",
	"trench_corner": "res://assets/models_test/121_TrenchCorner_01.gltf",
	"trench_cap": "res://assets/models_test/121_TrenchCap_01.gltf",
	"marine": "res://assets/models_test/marine1Tex.gltf",
	"firebat": "res://assets/models_test/firebat_elite.gltf",
	"siege_tank": "res://assets/models_test/siegeTank.gltf",
	"wraith": "res://assets/models_test/wraith.gltf",
	"battlecruiser": "res://assets/models_test/battlecruiser.gltf",
	"goliath": "res://assets/models_test/goliath_boss.gltf",
	"zealot": "res://assets/models_test/Zealot.gltf",
	"vulture": "res://assets/models_test/vulture.gltf",
	"mutalisk": "res://assets/models_test/mutalisk.gltf",
	"ultralisk": "res://assets/models_test/ultralisk.gltf",
}

@onready var info_label: Label = $HUD/InfoPanel/InfoLabel

var cam_angle := 0.0
var cam_height := 6.0
var cam_distance := 18.0
var scene_idx := 0
var scene_names := ["Nova vs Zerg", "Terran Arsenal", "Full Lineup"]
var rotate_cam := true
var loaded_models := {}


func _ready() -> void:
	print("GHOST_SHOWCASE: Loading proper NOD meshes")
	_setup_environment()
	_setup_lighting()
	_load_all_models()
	_build_scene(scene_idx)
	_refresh_info()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	var kev := event as InputEventKey
	if kev.keycode == KEY_RIGHT or kev.keycode == KEY_SPACE:
		scene_idx = (scene_idx + 1) % scene_names.size()
		_build_scene(scene_idx)
		_refresh_info()
	elif kev.keycode == KEY_LEFT:
		scene_idx = (scene_idx - 1 + scene_names.size()) % scene_names.size()
		_build_scene(scene_idx)
		_refresh_info()
	elif kev.keycode == KEY_R:
		rotate_cam = not rotate_cam
		_refresh_info()
	elif kev.keycode == KEY_UP:
		cam_height += 1.5
		_refresh_info()
	elif kev.keycode == KEY_DOWN:
		cam_height = maxf(1.0, cam_height - 1.5)
		_refresh_info()
	elif kev.keycode == KEY_L:
		get_tree().change_scene_to_file("res://scenes/Level1.tscn")
	elif kev.keycode == KEY_M:
		get_tree().change_scene_to_file("res://scenes/MarineVsZergling.tscn")


func _process(delta: float) -> void:
	if rotate_cam:
		cam_angle += delta * 0.3
	var cx := cos(cam_angle) * cam_distance
	var cz := sin(cam_angle) * cam_distance
	$Camera3D.position = Vector3(cx, cam_height, cz)
	$Camera3D.look_at(Vector3(0, 2.0, 0), Vector3.UP)


func _load_all_models() -> void:
	var success := 0
	var fail := 0
	for key in MODELS:
		var path: String = MODELS[key]
		var packed = load(path)
		if packed is PackedScene:
			loaded_models[key] = packed
			success += 1
		else:
			push_warning("Failed to load: %s" % path)
			fail += 1
	print("SHOWCASE: Loaded %d/%d models" % [success, success + fail])


func _build_scene(idx: int) -> void:
	# Clear existing models
	for child in $Models.get_children():
		child.queue_free()

	match idx:
		0:
			_scene_nova_vs_zerg()
		1:
			_scene_terran_arsenal()
		2:
			_scene_full_lineup()


func _scene_nova_vs_zerg() -> void:
	# Nova facing off against zerglings and a hydralisk
	# Trench corridor backdrop
	_place("trench_long", Vector3(0, 0, -8), 0.0, 1.0)
	_place("trench_long", Vector3(0, 0, 8), PI, 1.0)
	_place("trench_cap", Vector3(0, 0, -16), 0.0, 1.0)

	# Nova with rifle in firing stance
	_place("nova", Vector3(-4, 0, 0), PI * 0.3, 1.0)
	_place("rifle", Vector3(-3.5, 1.5, -0.5), PI * 0.3, 0.5)

	# Zerglings charging
	_place("zergling", Vector3(5, 0, -2), PI + 0.4, 1.0)
	_place("zergling", Vector3(6, 0, 1), PI - 0.3, 1.0)

	# Hydralisk behind them
	_place("hydralisk", Vector3(8, 0, 0), PI, 1.0)


func _scene_terran_arsenal() -> void:
	# Terran military showcase
	_place("ghost_male", Vector3(-6, 0, 0), 0.3, 1.0)
	_place("marine", Vector3(-2, 0, 0), 0.0, 1.0)
	_place("firebat", Vector3(2, 0, 0), -0.3, 1.0)
	_place("siege_tank", Vector3(0, 0, -8), 0.0, 0.8)
	_place("vulture", Vector3(-8, 0, -6), 0.5, 0.7)
	_place("wraith", Vector3(0, 8, -4), 0.0, 1.0)
	_place("goliath", Vector3(6, 0, -3), -0.4, 0.8)


func _scene_full_lineup() -> void:
	# Every model in a circle
	var keys := loaded_models.keys()
	for i in range(keys.size()):
		var angle := (TAU * float(i)) / float(keys.size())
		var radius := 10.0
		var pos := Vector3(cos(angle) * radius, 0, sin(angle) * radius)
		var facing := angle + PI  # Face center
		_place(keys[i], pos, facing, 0.8)


func _place(key: String, pos: Vector3, yaw: float, scale_factor: float) -> Node3D:
	if not loaded_models.has(key):
		# Create fallback cube
		var fallback := MeshInstance3D.new()
		fallback.mesh = BoxMesh.new()
		fallback.position = pos
		$Models.add_child(fallback)
		return fallback

	var inst: Node3D = (loaded_models[key] as PackedScene).instantiate()
	$Models.add_child(inst)

	# Normalize scale based on AABB
	var longest := _longest_dimension(inst)
	var target := 4.0 * scale_factor
	if longest > 0.01:
		var s := clampf(target / longest, 0.01, 10.0)
		inst.scale = Vector3.ONE * s

	inst.position = pos
	inst.rotation.y = yaw

	# Apply wireframe-like material for the untextured look
	_apply_ghost_material(inst, key)
	return inst


func _longest_dimension(node: Node) -> float:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh:
			var aabb := mi.mesh.get_aabb().size
			if aabb.is_finite():
				return maxf(aabb.x, maxf(aabb.y, aabb.z))
	for child in node.get_children():
		var v := _longest_dimension(child)
		if v > 0.0:
			return v
	return -1.0


func _apply_ghost_material(node: Node, key: String) -> void:
	var color := _model_color(key)
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh:
			var mat := StandardMaterial3D.new()
			mat.albedo_color = color
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
			mat.cull_mode = BaseMaterial3D.CULL_DISABLED
			mat.roughness = 0.7
			mat.metallic = 0.15
			mat.emission_enabled = true
			mat.emission = color * 0.08
			mi.material_override = mat
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	for child in node.get_children():
		_apply_ghost_material(child, key)


func _model_color(key: String) -> Color:
	# Terran = blue-grey, Zerg = green-brown, Protoss = gold
	if key in ["zergling", "hydralisk", "mutalisk", "ultralisk"]:
		return Color(0.35, 0.45, 0.2)  # Zerg green-brown
	if key in ["zealot"]:
		return Color(0.7, 0.6, 0.2)  # Protoss gold
	if key in ["nova", "ghost_male"]:
		return Color(0.6, 0.65, 0.7)  # Ghost light steel
	if key in ["trench_long", "trench_corner", "trench_cap"]:
		return Color(0.25, 0.28, 0.22)  # Environment dark green
	# Default terran blue-grey
	return Color(0.4, 0.45, 0.5)


func _setup_environment() -> void:
	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.02, 0.03, 0.04)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.3, 0.35, 0.4)
	env.ambient_light_energy = 0.6
	env.glow_enabled = true
	env.glow_intensity = 0.3
	we.environment = env
	add_child(we)


func _setup_lighting() -> void:
	# Key light (warm directional from above-right)
	var key_light := DirectionalLight3D.new()
	key_light.name = "KeyLight"
	key_light.light_color = Color(0.85, 0.82, 0.75)
	key_light.light_energy = 1.8
	key_light.rotation_degrees = Vector3(-45, -30, 0)
	key_light.shadow_enabled = true
	add_child(key_light)

	# Fill light (cool from left)
	var fill := OmniLight3D.new()
	fill.name = "FillLight"
	fill.light_color = Color(0.4, 0.5, 0.7)
	fill.light_energy = 0.8
	fill.omni_range = 30.0
	fill.position = Vector3(-10, 8, 5)
	add_child(fill)

	# Rim light (red from behind - Zerg threat)
	var rim := OmniLight3D.new()
	rim.name = "RimLight"
	rim.light_color = Color(0.7, 0.2, 0.1)
	rim.light_energy = 0.5
	rim.omni_range = 25.0
	rim.position = Vector3(10, 6, -8)
	add_child(rim)


func _refresh_info() -> void:
	var cam_state := "rotating" if rotate_cam else "fixed"
	info_label.text = "\n".join([
		"StarCraft Ghost — Model Showcase",
		"Scene: %s (%d/%d)" % [scene_names[scene_idx], scene_idx + 1, scene_names.size()],
		"Models loaded: %d / %d" % [loaded_models.size(), MODELS.size()],
		"Camera: %s  Height: %.1f" % [cam_state, cam_height],
		"",
		"Controls:",
		"Left/Right or Space = switch scene",
		"Up/Down = camera height",
		"R = toggle camera rotation",
		"L = Level1 assembler",
		"M = Marine vs Zergling",
	])
