extends CharacterBody3D
## Third-person player controller for StarCraft: Ghost port.
##
## WASD movement, mouse look (third-person orbit camera),
## sprint, jump, gravity, and flashlight toggle.

const MOVE_SPEED := 8.0
const SPRINT_SPEED := 16.0
const JUMP_VELOCITY := 6.0
const GRAVITY := 20.0
const MOUSE_SENSITIVITY := 0.002
const CAMERA_DISTANCE := 5.0
const CAMERA_HEIGHT := 2.0
const CAMERA_MIN_PITCH := -1.2
const CAMERA_MAX_PITCH := 0.6

## Path to Nova model (main character)
const PLAYER_MODEL := "res://assets/models_all/nova.gltf"

@onready var camera_pivot: Node3D = $CameraPivot
@onready var camera: Camera3D = $CameraPivot/Camera3D
@onready var model_root: Node3D = $ModelRoot
@onready var flashlight: SpotLight3D = $CameraPivot/Camera3D/Flashlight

var pitch: float = -0.2
var yaw: float = 0.0
var mouse_captured: bool = true


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_load_player_model()


func _load_player_model() -> void:
	var packed = load(PLAYER_MODEL)
	if packed is PackedScene:
		var inst := (packed as PackedScene).instantiate()
		if inst != null:
			model_root.add_child(inst)
			# Scale Nova model to reasonable size (adjust if needed)
			inst.scale = Vector3.ONE * 0.02
			return
	# Fallback: capsule placeholder
	push_warning("Could not load player model, using capsule placeholder")
	var mi := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.35
	capsule.height = 1.8
	mi.mesh = capsule
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.2, 0.5, 0.8)
	mi.material_override = mat
	model_root.add_child(mi)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and mouse_captured:
		var motion := event as InputEventMouseMotion
		yaw -= motion.relative.x * MOUSE_SENSITIVITY
		pitch -= motion.relative.y * MOUSE_SENSITIVITY
		pitch = clampf(pitch, CAMERA_MIN_PITCH, CAMERA_MAX_PITCH)

	if event is InputEventKey:
		var key := event as InputEventKey
		if key.pressed and not key.echo:
			if key.keycode == KEY_ESCAPE:
				mouse_captured = not mouse_captured
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if mouse_captured else Input.MOUSE_MODE_VISIBLE
			elif key.keycode == KEY_T:
				# Toggle flashlight
				flashlight.visible = not flashlight.visible

	if event is InputEventMouseButton and not mouse_captured:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			mouse_captured = true
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _physics_process(delta: float) -> void:
	# Gravity
	if not is_on_floor():
		velocity.y -= GRAVITY * delta

	# Jump
	if Input.is_key_pressed(KEY_SPACE) and is_on_floor():
		velocity.y = JUMP_VELOCITY

	# Movement direction (relative to camera yaw)
	var input_dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_W):
		input_dir.y -= 1
	if Input.is_key_pressed(KEY_S):
		input_dir.y += 1
	if Input.is_key_pressed(KEY_A):
		input_dir.x -= 1
	if Input.is_key_pressed(KEY_D):
		input_dir.x += 1

	var speed := SPRINT_SPEED if Input.is_key_pressed(KEY_SHIFT) else MOVE_SPEED

	if input_dir.length_squared() > 0.01:
		input_dir = input_dir.normalized()
		# Transform input by camera yaw
		var forward := Vector3(sin(yaw), 0, cos(yaw))
		var right := Vector3(cos(yaw), 0, -sin(yaw))
		var move_dir := (forward * -input_dir.y + right * input_dir.x).normalized()

		velocity.x = move_dir.x * speed
		velocity.z = move_dir.z * speed

		# Rotate model to face movement direction
		model_root.rotation.y = atan2(move_dir.x, move_dir.z)
	else:
		# Decelerate
		velocity.x = move_toward(velocity.x, 0, speed * delta * 10.0)
		velocity.z = move_toward(velocity.z, 0, speed * delta * 10.0)

	move_and_slide()

	# Update camera orbit
	camera_pivot.global_position = global_position + Vector3(0, CAMERA_HEIGHT, 0)
	camera_pivot.rotation = Vector3(pitch, yaw, 0)
