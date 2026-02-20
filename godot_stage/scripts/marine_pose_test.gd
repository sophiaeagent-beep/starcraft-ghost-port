extends Node3D
## Quick pose tester — shows marine variants side by side to find shooting pose.
## Press N/P to cycle, ESC to quit, B to go back to battle scene.

const VARIANTS := [
	["marine1Tex (T-pose)",       "res://assets/models_all/marine1Tex.gltf"],
	["marineBattlefield",         "res://assets/models_all/marineBattlefield.gltf"],
	["gunTurret_marine",          "res://assets/models_all/gunTurret_marine.gltf"],
	["flameTurret_marine",        "res://assets/models_all/flameTurret_marine.gltf"],
	["menu_marineR1",             "res://assets/models_all/menu_marineR1.gltf"],
	["menu_marineR2",             "res://assets/models_all/menu_marineR2.gltf"],
	["menu_marineR3",             "res://assets/models_all/menu_marineR3.gltf"],
	["marine1_elite",             "res://assets/models_all/marine1_elite.gltf"],
	["marine2Joe",                "res://assets/models_all/marine2Joe.gltf"],
	["marineCaptain",             "res://assets/models_all/marineCaptain.gltf"],
]

var current_idx := 0
var model_node: Node3D
var cam_angle := 0.0

func _ready() -> void:
	# Camera
	var cam := Camera3D.new()
	cam.name = "Camera3D"
	add_child(cam)

	# Light
	var light := DirectionalLight3D.new()
	light.light_energy = 2.0
	light.rotation_degrees = Vector3(-45, -30, 0)
	add_child(light)

	var ambient := OmniLight3D.new()
	ambient.light_energy = 0.5
	ambient.omni_range = 30.0
	ambient.position = Vector3(0, 5, 5)
	add_child(ambient)

	# Environment
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.15, 0.15, 0.2)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.4, 0.4, 0.5)
	env.ambient_light_energy = 0.6
	we.environment = env
	add_child(we)

	# HUD
	var canvas := CanvasLayer.new()
	canvas.name = "HUD"
	var label := Label.new()
	label.name = "InfoLabel"
	label.position = Vector2(20, 20)
	label.add_theme_font_size_override("font_size", 24)
	canvas.add_child(label)
	add_child(canvas)

	_show_model(0)


func _show_model(idx: int) -> void:
	current_idx = idx % VARIANTS.size()
	if model_node:
		model_node.queue_free()
		model_node = null

	var info: Array = VARIANTS[current_idx]
	var scene = load(info[1])
	if scene is PackedScene:
		var wrapper := Node3D.new()
		wrapper.name = "ModelWrapper"
		var inst: Node3D = scene.instantiate()
		inst.rotation.x = -PI * 0.5  # NOD stand-up
		# Auto-scale to ~4 units tall
		var longest := _longest_dim(inst)
		if longest > 0.01:
			inst.scale = Vector3.ONE * clampf(4.0 / longest, 0.01, 20.0)
		wrapper.add_child(inst)
		# (all models now use proper textures from production converter)
		add_child(wrapper)
		model_node = wrapper
		print("Showing: %s" % info[0])
	else:
		print("FAILED to load: %s" % info[1])

	$HUD/InfoLabel.text = "%s\n(%d/%d)  N=next  P=prev  B=battle  ESC=quit" % [
		info[0], current_idx + 1, VARIANTS.size()]


func _tint_model(node: Node, color: Color) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh:
			var mat := StandardMaterial3D.new()
			mat.albedo_color = color
			mat.cull_mode = BaseMaterial3D.CULL_DISABLED
			mat.roughness = 0.7
			mat.metallic = 0.15
			mi.material_override = mat
	for child in node.get_children():
		_tint_model(child, color)


func _longest_dim(node: Node) -> float:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh:
			var aabb := mi.mesh.get_aabb().size
			if aabb.is_finite():
				return maxf(aabb.x, maxf(aabb.y, aabb.z))
	for child in node.get_children():
		var v := _longest_dim(child)
		if v > 0.0:
			return v
	return -1.0


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match (event as InputEventKey).keycode:
		KEY_N:
			_show_model(current_idx + 1)
		KEY_P:
			_show_model(current_idx - 1 + VARIANTS.size())
		KEY_B:
			get_tree().change_scene_to_file("res://scenes/MarineVsZergling.tscn")
		KEY_ESCAPE:
			get_tree().quit()


func _process(delta: float) -> void:
	cam_angle += delta * 0.3
	var cx := cos(cam_angle) * 8.0
	var cz := sin(cam_angle) * 8.0
	$Camera3D.position = Vector3(cx, 3.0, cz)
	$Camera3D.look_at(Vector3(0, 1.5, 0), Vector3.UP)
