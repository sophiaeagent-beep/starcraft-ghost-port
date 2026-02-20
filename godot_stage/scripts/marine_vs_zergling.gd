extends Node3D
## Marine vs Zergling — Textured SC:Ghost models, extracted Xbox audio,
## and in-game environment assets (trenches, sandbags, crates).
##
## SPACE = fire       R = reset       ESC = quit
## Arrow keys = adjust camera     C = toggle rotation

enum State { IDLE, FIRING, DYING, DEAD }

# Audio paths (wave bank extractions — numbered by cue index)
const SFX := {
	"rifle":       "res://assets/audio/global/5.wav",
	"rifle_alt":   "res://assets/audio/global/6.wav",
	"impact":      "res://assets/audio/global/33.wav",
	"impact_alt":  "res://assets/audio/global/22.wav",
	"zerg_pain":   "res://assets/audio/zerg/61.wav",
	"zerg_death":  "res://assets/audio/zerg/56.wav",
	"zerg_growl":  "res://assets/audio/zerg/41.wav",
	"marine_bark": "res://assets/audio/terran/25.wav",
}

# Environment asset paths
const ENV := {
	"trench_long":  "res://assets/models_env/121_TrenchLong_01.gltf",
	"trench_short": "res://assets/models_env/121_TrenchShort_01.gltf",
	"trench_corner":"res://assets/models_env/121_TrenchCorner_01.gltf",
	"trench_cap":   "res://assets/models_env/121_TrenchCap_01.gltf",
	"sandbag_wall": "res://assets/models_env/Sandbag_Wall_Side1.gltf",
	"sandbag_group":"res://assets/models_env/Sandbag_Group_01.gltf",
	"sandbags":     "res://assets/models_env/SandbagsSmall.gltf",
	"crate_large":  "res://assets/models_env/AB_crateLarge_01.gltf",
	"crate_small":  "res://assets/models_env/AB_crateSmall_01.gltf",
	"barrel":       "res://assets/models_env/GE_BarrelHighPoly.gltf",
	"barrel_exp":   "res://assets/models_env/GE_explosivesBarrel_01.gltf",
	"gun_turret":   "res://assets/models_env/gunTurret.gltf",
	"wall_turret":  "res://assets/models_env/wallTurret.gltf",
	"bunker_gun":   "res://assets/models_env/BunkerGun.gltf",
	"light":        "res://assets/models_env/GE_lightCaged.gltf",
}

const MARINE_MODEL := "res://assets/models_textured/marine1Tex.gltf"
const ZERGLING_MODEL := "res://assets/models_textured/zerglingNORMAL.gltf"
const RIFLE_MODEL := "res://assets/models_test/gaussRifle_1.gltf"

const MARINE_POS := Vector3(-4.0, 0.0, 0.0)
const ZERGLING_POS := Vector3(5.0, 0.0, 0.0)

var state := State.IDLE
var marine_wrapper: Node3D
var marine_node: Node3D
var zergling_wrapper: Node3D
var zergling_node: Node3D
var rifle_wrapper: Node3D
var muzzle_flash: OmniLight3D
var cam_angle := -PI * 0.25
var cam_height := 5.0
var cam_distance := 16.0
var rotate_cam := true

@onready var info_label: Label = $HUD/InfoPanel/InfoLabel


func _ready() -> void:
	_setup_environment()
	_setup_lighting()
	_build_battlefield()
	_spawn_combatants()
	_refresh_info()
	print("MARINE_VS_ZERGLING: Scene ready — press SPACE to fire")


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match (event as InputEventKey).keycode:
		KEY_SPACE:
			if state == State.IDLE:
				_fire_sequence()
		KEY_R:
			_reset_scene()
		KEY_UP:
			cam_height += 1.0
			_refresh_info()
		KEY_DOWN:
			cam_height = maxf(1.0, cam_height - 1.0)
			_refresh_info()
		KEY_LEFT:
			cam_angle -= 0.25
		KEY_RIGHT:
			cam_angle += 0.25
		KEY_C:
			rotate_cam = not rotate_cam
			_refresh_info()
		KEY_ESCAPE:
			get_tree().quit()
		KEY_G:
			get_tree().change_scene_to_file("res://scenes/GhostShowcase.tscn")


func _process(delta: float) -> void:
	if rotate_cam:
		cam_angle += delta * 0.12
	var cx := cos(cam_angle) * cam_distance
	var cz := sin(cam_angle) * cam_distance
	$Camera3D.position = Vector3(cx, cam_height, cz)
	$Camera3D.look_at(Vector3(0.5, 1.5, 0), Vector3.UP)


# ── Helpers ──────────────────────────────────────────────

func _load_model(path: String) -> PackedScene:
	var res = load(path)
	if res is PackedScene:
		return res
	push_warning("Failed to load: %s" % path)
	return null


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


## Place an environment prop with NOD stand-up rotation.
## face_target: if set, wrapper uses look_at to face that point.
func _place_prop(key: String, pos: Vector3, size: float,
		face_target := Vector3.INF, yaw := 0.0, color := Color(-1, 0, 0)) -> Node3D:
	var scene := _load_model(ENV.get(key, ""))
	if not scene:
		return null

	var wrapper := Node3D.new()
	wrapper.position = pos
	$Models.add_child(wrapper)

	var inst: Node3D = scene.instantiate()
	inst.rotation.x = -PI * 0.5  # NOD stand-up
	var longest := _longest_dim(inst)
	if longest > 0.01:
		var s := clampf(size / longest, 0.01, 50.0)
		inst.scale = Vector3.ONE * s
	wrapper.add_child(inst)

	if face_target != Vector3.INF:
		wrapper.look_at(face_target, Vector3.UP)
	elif yaw != 0.0:
		wrapper.rotation.y = yaw

	# Optional color tint for untextured env models
	if color.r >= 0:
		_tint_model(inst, color)

	return wrapper


func _tint_model(node: Node, color: Color) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh:
			var mat := StandardMaterial3D.new()
			mat.albedo_color = color
			mat.cull_mode = BaseMaterial3D.CULL_DISABLED
			mat.roughness = 0.8
			mat.metallic = 0.1
			mi.material_override = mat
	for child in node.get_children():
		_tint_model(child, color)


# ── Battlefield ──────────────────────────────────────────

func _build_battlefield() -> void:
	var dirt := Color(0.25, 0.22, 0.18)     # dirt brown
	var metal := Color(0.35, 0.38, 0.32)    # military green-grey
	var rust := Color(0.4, 0.3, 0.2)        # rusty
	var dark := Color(0.2, 0.22, 0.18)      # dark green

	# ── Trench walls along Z axis (backdrop behind combatants) ──
	_place_prop("trench_long", Vector3(0, 0, -7), 12.0, Vector3.INF, 0.0, metal)
	_place_prop("trench_long", Vector3(0, 0, 7), 12.0, Vector3.INF, PI, metal)
	_place_prop("trench_cap", Vector3(-12, 0, -7), 6.0, Vector3.INF, PI * 0.5, metal)
	_place_prop("trench_cap", Vector3(12, 0, -7), 6.0, Vector3.INF, -PI * 0.5, metal)

	# ── Sandbag cover (marine side) ──
	_place_prop("sandbag_wall", Vector3(-6.5, 0, -2), 3.0, Vector3.INF, 0.0, dirt)
	_place_prop("sandbag_wall", Vector3(-6.5, 0, 2), 3.0, Vector3.INF, 0.0, dirt)
	_place_prop("sandbag_group", Vector3(-7, 0, 0), 2.0, Vector3.INF, 0.3, dirt)

	# ── Crates & barrels (scattered cover) ──
	_place_prop("crate_large", Vector3(-2, 0, -3.5), 2.5, Vector3.INF, 0.2, rust)
	_place_prop("crate_small", Vector3(-1.5, 0, 3), 1.5, Vector3.INF, -0.4, rust)
	_place_prop("crate_large", Vector3(8, 0, -2), 2.0, Vector3.INF, 0.8, rust)
	_place_prop("barrel", Vector3(-3, 0, 4), 1.5, Vector3.INF, 0.0, dark)
	_place_prop("barrel_exp", Vector3(3, 0, -4), 1.5, Vector3.INF, 0.0, Color(0.5, 0.15, 0.1))
	_place_prop("barrel", Vector3(7, 0, 3), 1.5, Vector3.INF, 0.5, dark)

	# ── Turret behind marine (defensive position) ──
	_place_prop("gun_turret", Vector3(-9, 0, 0), 3.0, ZERGLING_POS, 0.0, metal)

	# ── Sandbags on zergling approach side ──
	_place_prop("sandbags", Vector3(8, 0, -4), 2.0, Vector3.INF, -0.3, dirt)
	_place_prop("sandbag_group", Vector3(9, 0, 1), 2.0, Vector3.INF, PI, dirt)


# ── Combatants ───────────────────────────────────────────

func _spawn_combatants() -> void:
	# Clear combatant nodes (keep environment in $Models)
	if marine_wrapper and is_instance_valid(marine_wrapper):
		marine_wrapper.queue_free()
	if zergling_wrapper and is_instance_valid(zergling_wrapper):
		zergling_wrapper.queue_free()
	if rifle_wrapper and is_instance_valid(rifle_wrapper):
		rifle_wrapper.queue_free()
	if muzzle_flash and is_instance_valid(muzzle_flash):
		muzzle_flash.queue_free()

	# ── Marine ──
	var marine_scene := _load_model(MARINE_MODEL)
	if marine_scene:
		marine_wrapper = Node3D.new()
		marine_wrapper.name = "MarineWrapper"
		marine_wrapper.position = MARINE_POS
		$Models.add_child(marine_wrapper)

		marine_node = marine_scene.instantiate()
		marine_node.rotation.x = -PI * 0.5
		var s := _longest_dim(marine_node)
		if s > 0.01:
			marine_node.scale = Vector3.ONE * clampf(4.0 / s, 0.01, 20.0)
		marine_wrapper.add_child(marine_node)

		# Face zergling
		marine_wrapper.look_at(ZERGLING_POS, Vector3.UP)

	# ── Rifle (separate wrapper so it can aim independently) ──
	var rifle_scene := _load_model(RIFLE_MODEL)
	if rifle_scene:
		rifle_wrapper = Node3D.new()
		rifle_wrapper.name = "RifleWrapper"
		# Position at marine's chest/arm area (world space)
		rifle_wrapper.position = MARINE_POS + Vector3(0.8, 1.5, 0.0)
		$Models.add_child(rifle_wrapper)

		var rifle_node_inner: Node3D = rifle_scene.instantiate()
		rifle_node_inner.rotation.x = -PI * 0.5  # stand upright
		var rs := _longest_dim(rifle_node_inner)
		if rs > 0.01:
			rifle_node_inner.scale = Vector3.ONE * clampf(2.5 / rs, 0.01, 20.0)
		rifle_wrapper.add_child(rifle_node_inner)

		# Aim rifle at zergling center mass
		rifle_wrapper.look_at(ZERGLING_POS + Vector3(0, 1.0, 0), Vector3.UP)

		# Tint rifle to match marine
		_tint_model(rifle_node_inner, Color(0.35, 0.38, 0.42))

	# ── Zergling ──
	var zergling_scene := _load_model(ZERGLING_MODEL)
	if zergling_scene:
		zergling_wrapper = Node3D.new()
		zergling_wrapper.name = "ZerglingWrapper"
		zergling_wrapper.position = ZERGLING_POS
		$Models.add_child(zergling_wrapper)

		zergling_node = zergling_scene.instantiate()
		zergling_node.rotation.x = -PI * 0.5
		var s := _longest_dim(zergling_node)
		if s > 0.01:
			zergling_node.scale = Vector3.ONE * clampf(3.5 / s, 0.01, 20.0)
		zergling_wrapper.add_child(zergling_node)

		# Face marine
		zergling_wrapper.look_at(MARINE_POS, Vector3.UP)

	# ── Muzzle flash at rifle tip ──
	muzzle_flash = OmniLight3D.new()
	muzzle_flash.name = "MuzzleFlash"
	muzzle_flash.light_color = Color(1.0, 0.8, 0.3)
	muzzle_flash.light_energy = 0.0
	muzzle_flash.omni_range = 8.0
	# Between marine and zergling, at rifle height
	muzzle_flash.position = Vector3(
		(MARINE_POS.x + ZERGLING_POS.x) * 0.3,
		1.8, 0.0)
	add_child(muzzle_flash)


# ── Audio ────────────────────────────────────────────────

func _play_sfx(key: String, pos: Vector3, volume_db: float = 0.0) -> void:
	if not SFX.has(key):
		return
	var stream = load(SFX[key])
	if not stream:
		return
	var player := AudioStreamPlayer3D.new()
	player.stream = stream
	player.position = pos
	player.volume_db = volume_db
	player.max_db = 6.0
	player.unit_size = 10.0
	player.max_distance = 50.0
	add_child(player)
	player.play()
	player.finished.connect(player.queue_free)


# ── Fire sequence ────────────────────────────────────────

func _fire_sequence() -> void:
	state = State.FIRING
	_refresh_info()

	_play_sfx("marine_bark", MARINE_POS, 3.0)

	await get_tree().create_timer(0.2).timeout
	_play_sfx("zerg_growl", ZERGLING_POS, 2.0)

	# Burst 1
	await get_tree().create_timer(0.4).timeout
	for i in range(3):
		_fire_one_shot(i)
		await get_tree().create_timer(0.18).timeout

	# Impact + pain
	await get_tree().create_timer(0.15).timeout
	_play_sfx("impact", ZERGLING_POS, 1.0)
	_play_sfx("zerg_pain", ZERGLING_POS, 4.0)

	if zergling_wrapper:
		var tw := create_tween()
		tw.tween_property(zergling_wrapper, "position:x", ZERGLING_POS.x + 0.5, 0.1)
		tw.tween_property(zergling_wrapper, "position:x", ZERGLING_POS.x + 0.2, 0.15)

	# Burst 2
	await get_tree().create_timer(0.5).timeout
	for i in range(3):
		_fire_one_shot(i)
		await get_tree().create_timer(0.15).timeout

	# Kill
	await get_tree().create_timer(0.2).timeout
	_play_sfx("impact_alt", ZERGLING_POS, 2.0)
	state = State.DYING
	_refresh_info()
	_zergling_death()


func _fire_one_shot(idx: int) -> void:
	var sfx_key := "rifle" if (idx % 2 == 0) else "rifle_alt"
	_play_sfx(sfx_key, MARINE_POS + Vector3(1.5, 1.8, 0.0), 2.0)

	muzzle_flash.light_energy = 8.0
	await get_tree().create_timer(0.05).timeout
	muzzle_flash.light_energy = 0.0

	if marine_wrapper:
		var tw := create_tween()
		tw.tween_property(marine_wrapper, "position:x", MARINE_POS.x - 0.15, 0.04)
		tw.tween_property(marine_wrapper, "position:x", MARINE_POS.x, 0.08)
	if rifle_wrapper:
		var tw2 := create_tween()
		var rx := rifle_wrapper.position.x
		tw2.tween_property(rifle_wrapper, "position:x", rx - 0.15, 0.04)
		tw2.tween_property(rifle_wrapper, "position:x", rx, 0.08)


func _zergling_death() -> void:
	_play_sfx("zerg_death", ZERGLING_POS, 5.0)

	if zergling_wrapper:
		var tw := create_tween()
		tw.set_parallel(true)
		tw.tween_property(zergling_wrapper, "position:x", ZERGLING_POS.x + 2.5, 0.8) \
			.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
		tw.tween_property(zergling_wrapper, "rotation:z", PI * 0.5, 0.6) \
			.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
		tw.tween_property(zergling_wrapper, "position:y", -0.5, 0.8) \
			.set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)

	await get_tree().create_timer(3.0).timeout
	state = State.DEAD
	_refresh_info()


# ── Reset ────────────────────────────────────────────────

func _reset_scene() -> void:
	state = State.IDLE
	_spawn_combatants()
	_refresh_info()


# ── Environment ──────────────────────────────────────────

func _setup_environment() -> void:
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.03, 0.04, 0.05)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.35, 0.38, 0.42)
	env.ambient_light_energy = 0.5
	env.glow_enabled = true
	env.glow_intensity = 0.4
	env.fog_enabled = true
	env.fog_light_color = Color(0.15, 0.12, 0.1)
	env.fog_density = 0.005
	we.environment = env
	add_child(we)


func _setup_lighting() -> void:
	# Key light — warm directional
	var key_light := DirectionalLight3D.new()
	key_light.light_color = Color(0.9, 0.85, 0.75)
	key_light.light_energy = 2.0
	key_light.rotation_degrees = Vector3(-50, -20, 0)
	key_light.shadow_enabled = true
	add_child(key_light)

	# Fill — cool from marine side
	var fill := OmniLight3D.new()
	fill.light_color = Color(0.4, 0.5, 0.7)
	fill.light_energy = 0.7
	fill.omni_range = 25.0
	fill.position = Vector3(-10, 8, 5)
	add_child(fill)

	# Accent — red-orange from zerg side (menace)
	var accent := OmniLight3D.new()
	accent.light_color = Color(0.8, 0.25, 0.1)
	accent.light_energy = 0.6
	accent.omni_range = 25.0
	accent.position = Vector3(12, 5, -5)
	add_child(accent)

	# Ground bounce
	var bounce := OmniLight3D.new()
	bounce.light_color = Color(0.3, 0.25, 0.2)
	bounce.light_energy = 0.3
	bounce.omni_range = 20.0
	bounce.position = Vector3(0, -1, 0)
	add_child(bounce)


# ── HUD ──────────────────────────────────────────────────

func _refresh_info() -> void:
	var state_str := ""
	match state:
		State.IDLE:   state_str = "READY — Press SPACE to fire"
		State.FIRING: state_str = "FIRING!"
		State.DYING:  state_str = "Target down..."
		State.DEAD:   state_str = "DEAD — Press R to reset"

	info_label.text = "\n".join([
		"StarCraft: Ghost — Marine vs Zergling",
		"Textured models + Xbox audio + environment props",
		"",
		state_str,
		"",
		"SPACE = fire    R = reset",
		"Arrows = camera    C = toggle rotation",
		"G = showcase    ESC = quit",
	])
