extends CharacterBody3D
## Basic enemy AI with state machine for StarCraft: Ghost port.
##
## States: IDLE → ALERT → CHASE → ATTACK → DEAD
## Enemies detect the player via distance check and optional raycast.

enum State { IDLE, ALERT, CHASE, ATTACK, DEAD }

## Tunable per-enemy-type
@export var move_speed: float = 4.0
@export var chase_speed: float = 7.0
@export var detection_range: float = 25.0
@export var attack_range: float = 3.0
@export var attack_damage: float = 10.0
@export var attack_cooldown: float = 1.5
@export var health: float = 100.0
@export var max_health: float = 100.0
@export var enemy_type: String = "marine"

## Model path — set by spawner based on entity type
@export var model_path: String = ""

const GRAVITY := 20.0
const TURN_SPEED := 8.0
const ALERT_TIME := 2.0  # Seconds in alert before chasing

var state: State = State.IDLE
var player: Node3D = null
var alert_timer: float = 0.0
var attack_timer: float = 0.0
var patrol_origin: Vector3 = Vector3.ZERO
var patrol_dir: float = 0.0
var patrol_timer: float = 0.0

# Visual components
var model_root: Node3D = null
var health_bar: MeshInstance3D = null
var label: Label3D = null


func _ready() -> void:
	patrol_origin = global_position
	_setup_visuals()
	# Player may not exist yet (spawned in same frame) — retry periodically
	_find_player()


var _player_search_timer: float = 0.0


func _find_player() -> void:
	# Look for player CharacterBody3D in scene
	player = _find_node_by_type(get_tree().root, "CharacterBody3D", "Player")


func _find_node_by_type(node: Node, type_name: String, node_name: String) -> Node:
	if node.get_class() == type_name and node.name == node_name:
		return node
	for child in node.get_children():
		var found := _find_node_by_type(child, type_name, node_name)
		if found != null:
			return found
	return null


func _setup_visuals() -> void:
	model_root = Node3D.new()
	model_root.name = "ModelRoot"
	add_child(model_root)

	# Try to load actual model
	var loaded := false
	if model_path != "":
		var packed = load(model_path)
		if packed is PackedScene:
			var inst := (packed as PackedScene).instantiate()
			if inst != null:
				model_root.add_child(inst)
				# Models are in level-native coordinates — no scale needed
				loaded = true

	# Fallback: colored capsule
	if not loaded:
		var mi := MeshInstance3D.new()
		var capsule := CapsuleMesh.new()
		capsule.radius = 0.35
		capsule.height = 1.7
		mi.mesh = capsule
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.8, 0.15, 0.1)  # Red enemy color
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mi.material_override = mat
		mi.position.y = 0.85
		model_root.add_child(mi)

	# Health bar (thin box above head)
	health_bar = MeshInstance3D.new()
	var bar_mesh := BoxMesh.new()
	bar_mesh.size = Vector3(1.0, 0.08, 0.08)
	health_bar.mesh = bar_mesh
	var bar_mat := StandardMaterial3D.new()
	bar_mat.albedo_color = Color(0.1, 1.0, 0.1)
	bar_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	health_bar.material_override = bar_mat
	health_bar.position = Vector3(0, 5.5, 0)
	add_child(health_bar)

	# Name/state label
	label = Label3D.new()
	label.text = "%s [IDLE]" % enemy_type
	label.position = Vector3(0, 6.0, 0)
	label.pixel_size = 0.008
	label.font_size = 28
	label.modulate = Color(1.0, 0.3, 0.2)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	add_child(label)


func _physics_process(delta: float) -> void:
	if state == State.DEAD:
		return
	if not is_inside_tree():
		return

	# Periodically search for player if we haven't found one yet
	if player == null or not is_instance_valid(player):
		_player_search_timer += delta
		if _player_search_timer >= 1.0:
			_player_search_timer = 0.0
			_find_player()

	# Gravity
	if not is_on_floor():
		velocity.y -= GRAVITY * delta

	var dist_to_player := INF
	if player != null and is_instance_valid(player) and player.is_inside_tree():
		dist_to_player = global_position.distance_to(player.global_position)

	match state:
		State.IDLE:
			_state_idle(delta, dist_to_player)
		State.ALERT:
			_state_alert(delta, dist_to_player)
		State.CHASE:
			_state_chase(delta, dist_to_player)
		State.ATTACK:
			_state_attack(delta, dist_to_player)

	move_and_slide()
	_update_label()


func _state_idle(delta: float, dist: float) -> void:
	# Simple patrol: wander near origin
	patrol_timer += delta
	if patrol_timer > 3.0:
		patrol_timer = 0.0
		patrol_dir = randf() * TAU

	var patrol_target := patrol_origin + Vector3(cos(patrol_dir), 0, sin(patrol_dir)) * 3.0
	var to_target := patrol_target - global_position
	to_target.y = 0
	if to_target.length() > 0.5:
		var move_dir := to_target.normalized()
		velocity.x = move_dir.x * move_speed * 0.3
		velocity.z = move_dir.z * move_speed * 0.3
		_face_direction(move_dir, delta)
	else:
		velocity.x = 0
		velocity.z = 0

	# Detect player
	if dist < detection_range:
		state = State.ALERT
		alert_timer = 0.0


func _state_alert(delta: float, dist: float) -> void:
	# Face player, pause before chasing
	velocity.x = 0
	velocity.z = 0
	alert_timer += delta

	if player != null and is_instance_valid(player) and player.is_inside_tree():
		var to_player := (player.global_position - global_position)
		to_player.y = 0
		if to_player.length() > 0.1:
			_face_direction(to_player.normalized(), delta)

	if dist > detection_range * 1.5:
		# Lost target
		state = State.IDLE
	elif alert_timer >= ALERT_TIME:
		state = State.CHASE


func _state_chase(delta: float, dist: float) -> void:
	if player == null or not is_instance_valid(player) or not player.is_inside_tree():
		state = State.IDLE
		return

	var to_player := player.global_position - global_position
	to_player.y = 0

	if dist <= attack_range:
		state = State.ATTACK
		attack_timer = 0.0
		velocity.x = 0
		velocity.z = 0
		return

	if dist > detection_range * 2.0:
		# Lost target
		state = State.IDLE
		return

	# Move toward player
	var move_dir := to_player.normalized()
	velocity.x = move_dir.x * chase_speed
	velocity.z = move_dir.z * chase_speed
	_face_direction(move_dir, delta)


func _state_attack(delta: float, dist: float) -> void:
	velocity.x = 0
	velocity.z = 0
	attack_timer += delta

	if player != null and is_instance_valid(player) and player.is_inside_tree():
		var to_player := (player.global_position - global_position)
		to_player.y = 0
		if to_player.length() > 0.1:
			_face_direction(to_player.normalized(), delta)

	if dist > attack_range * 1.5:
		state = State.CHASE
		return

	if attack_timer >= attack_cooldown:
		attack_timer = 0.0
		# Deal damage (placeholder — just prints)
		print("[%s] attacks player! (%.0f dmg)" % [enemy_type, attack_damage])


func _face_direction(dir: Vector3, delta: float) -> void:
	if dir.length_squared() < 0.001:
		return
	var target_angle := atan2(dir.x, dir.z)
	model_root.rotation.y = lerp_angle(model_root.rotation.y, target_angle, TURN_SPEED * delta)


func take_damage(amount: float) -> void:
	if state == State.DEAD:
		return
	health -= amount
	# Flash red
	if health_bar and health_bar.material_override:
		health_bar.material_override.albedo_color = Color(1.0, 0.0, 0.0)
	# Update health bar scale
	var ratio := clampf(health / max_health, 0.0, 1.0)
	if health_bar:
		health_bar.scale.x = ratio
		if ratio > 0.5:
			health_bar.material_override.albedo_color = Color(0.1, 1.0, 0.1)
		elif ratio > 0.25:
			health_bar.material_override.albedo_color = Color(1.0, 0.8, 0.1)
		else:
			health_bar.material_override.albedo_color = Color(1.0, 0.1, 0.1)

	if health <= 0.0:
		_die()


func _die() -> void:
	state = State.DEAD
	health = 0.0
	velocity = Vector3.ZERO
	# Tip over
	if model_root and is_inside_tree():
		var tween := create_tween()
		tween.tween_property(model_root, "rotation_degrees:x", -90.0, 0.5)
	# Hide health bar
	if health_bar:
		health_bar.visible = false
	if label:
		label.modulate = Color(0.5, 0.5, 0.5, 0.5)
	if is_inside_tree():
		print("[%s] died at %s" % [enemy_type, str(global_position)])


func _update_label() -> void:
	if label == null:
		return
	var state_name: String
	match state:
		State.IDLE: state_name = "IDLE"
		State.ALERT: state_name = "ALERT!"
		State.CHASE: state_name = "CHASE"
		State.ATTACK: state_name = "ATTACK"
		State.DEAD: state_name = "DEAD"
	label.text = "%s [%s]" % [enemy_type, state_name]
