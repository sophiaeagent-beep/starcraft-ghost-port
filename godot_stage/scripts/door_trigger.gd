extends Node3D
## Interactive door/console/ladder trigger for StarCraft: Ghost port.
##
## Uses an Area3D to detect when the player enters the trigger zone.
## Doors slide open, hack consoles show interaction prompt, ladders
## allow vertical movement.

enum DoorType { DOOR, HACK_CONSOLE, LADDER, ELEVATOR, GENERIC }

@export var door_type: DoorType = DoorType.DOOR
@export var interaction_text: String = "Press F to interact"
@export var open_speed: float = 2.0
@export var door_name: String = "door"
@export var model_path: String = ""  # glTF path set by level loader

## How far the door slides when opening (meters)
const DOOR_SLIDE_DISTANCE := 3.0
const LADDER_CLIMB_SPEED := 5.0

var is_open: bool = false
var is_locked: bool = false
var player_in_zone: bool = false
var door_mesh: MeshInstance3D = null
var prompt_label: Label3D = null
var initial_position: Vector3 = Vector3.ZERO
var target_position: Vector3 = Vector3.ZERO
var current_t: float = 0.0  # 0 = closed, 1 = open


func _ready() -> void:
	initial_position = position
	# Door slides up by default
	target_position = initial_position + Vector3(0, DOOR_SLIDE_DISTANCE, 0)
	_setup_visuals()
	_setup_trigger_area()


func _setup_visuals() -> void:
	# Try loading a glTF model if model_path was set by the level loader
	var model_loaded := false
	if model_path != "":
		var scene = load(model_path)
		if scene is PackedScene:
			var model := (scene as PackedScene).instantiate()
			if model is Node3D:
				model.name = "DoorModel"
				add_child(model)
				door_mesh = null  # No box mesh — model handles visuals
				model_loaded = true

	if not model_loaded:
		# Fallback: colored box marker
		door_mesh = MeshInstance3D.new()
		door_mesh.name = "DoorMesh"

		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

		match door_type:
			DoorType.DOOR:
				var box := BoxMesh.new()
				box.size = Vector3(2.0, 3.0, 0.2)
				door_mesh.mesh = box
				mat.albedo_color = Color(0.3, 0.4, 0.7, 0.85)
				mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				door_mesh.position.y = 1.5
			DoorType.HACK_CONSOLE:
				var box := BoxMesh.new()
				box.size = Vector3(0.8, 1.2, 0.4)
				door_mesh.mesh = box
				mat.albedo_color = Color(0.1, 0.8, 0.3, 0.9)
				mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				door_mesh.position.y = 0.6
			DoorType.LADDER:
				var box := BoxMesh.new()
				box.size = Vector3(0.6, 4.0, 0.2)
				door_mesh.mesh = box
				mat.albedo_color = Color(0.7, 0.5, 0.2, 0.8)
				mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				door_mesh.position.y = 2.0
			DoorType.ELEVATOR:
				var box := BoxMesh.new()
				box.size = Vector3(2.5, 0.2, 2.5)
				door_mesh.mesh = box
				mat.albedo_color = Color(0.5, 0.5, 0.6, 0.8)
				mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			_:
				var box := BoxMesh.new()
				box.size = Vector3(1.0, 1.0, 1.0)
				door_mesh.mesh = box
				mat.albedo_color = Color(0.4, 0.4, 0.8, 0.6)
				mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

		door_mesh.material_override = mat
		add_child(door_mesh)

	# Interaction prompt (hidden by default)
	prompt_label = Label3D.new()
	prompt_label.text = interaction_text
	prompt_label.position = Vector3(0, 3.5, 0)
	prompt_label.pixel_size = 0.008
	prompt_label.font_size = 32
	prompt_label.modulate = Color(1.0, 1.0, 0.5, 0.9)
	prompt_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	prompt_label.no_depth_test = true
	prompt_label.visible = false
	prompt_label.name = "Prompt"
	add_child(prompt_label)

	# Name label (always visible)
	var name_label := Label3D.new()
	name_label.text = door_name
	name_label.position = Vector3(0, 3.0, 0)
	name_label.pixel_size = 0.006
	name_label.font_size = 20
	name_label.modulate = Color(0.5, 0.7, 1.0, 0.7)
	name_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	name_label.no_depth_test = true
	name_label.name = "NameLabel"
	add_child(name_label)


func _setup_trigger_area() -> void:
	var area := Area3D.new()
	area.name = "TriggerZone"

	var col := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	# Trigger zone is larger than the visual
	match door_type:
		DoorType.DOOR:
			box_shape.size = Vector3(4.0, 4.0, 3.0)
		DoorType.HACK_CONSOLE:
			box_shape.size = Vector3(2.5, 2.0, 2.5)
		DoorType.LADDER:
			box_shape.size = Vector3(2.0, 5.0, 2.0)
		_:
			box_shape.size = Vector3(3.0, 3.0, 3.0)

	col.shape = box_shape
	col.position.y = box_shape.size.y * 0.5
	area.add_child(col)
	add_child(area)

	area.body_entered.connect(_on_body_entered)
	area.body_exited.connect(_on_body_exited)


func _on_body_entered(body: Node3D) -> void:
	if not (body is CharacterBody3D):
		return
	# Distinguish the player from enemies — player has a heal() method
	if not body.has_method("heal"):
		return
	player_in_zone = true
	if prompt_label:
		prompt_label.visible = true
	# Auto-open doors when player enters
	if door_type == DoorType.DOOR and not is_locked:
		_open()


func _on_body_exited(body: Node3D) -> void:
	if not (body is CharacterBody3D):
		return
	if not body.has_method("heal"):
		return
	player_in_zone = false
	if prompt_label:
		prompt_label.visible = false
	# Auto-close doors when player leaves
	if door_type == DoorType.DOOR and is_open:
		_close()


func _process(delta: float) -> void:
	# Animate door position
	if is_open and current_t < 1.0:
		current_t = minf(current_t + delta * open_speed, 1.0)
		_update_door_position()
	elif not is_open and current_t > 0.0:
		current_t = maxf(current_t - delta * open_speed, 0.0)
		_update_door_position()

	# Handle F key interaction when in zone
	if player_in_zone and Input.is_action_just_pressed("ui_focus_next"):
		_interact()


func _unhandled_input(event: InputEvent) -> void:
	if not player_in_zone:
		return
	if event is InputEventKey:
		var key := event as InputEventKey
		if key.pressed and not key.echo and key.keycode == KEY_F:
			_interact()


func _interact() -> void:
	match door_type:
		DoorType.DOOR:
			if is_locked:
				print("[%s] Door is locked!" % door_name)
			elif is_open:
				_close()
			else:
				_open()
		DoorType.HACK_CONSOLE:
			print("[%s] Hacking console... (placeholder)" % door_name)
			is_locked = false
		DoorType.LADDER:
			print("[%s] Climbing ladder... (placeholder)" % door_name)
		DoorType.ELEVATOR:
			if is_open:
				_close()
			else:
				_open()
		_:
			print("[%s] Interacted (placeholder)" % door_name)


func _open() -> void:
	is_open = true
	print("[%s] Opening" % door_name)


func _close() -> void:
	is_open = false
	print("[%s] Closing" % door_name)


func _update_door_position() -> void:
	var slide := (target_position - initial_position) * current_t
	if door_mesh:
		# Slide the box mesh, not the whole node (so trigger zone stays put)
		door_mesh.position = Vector3(0, 1.5, 0) + slide
	else:
		# Slide the glTF model node
		var model := get_node_or_null("DoorModel")
		if model:
			model.position = slide
