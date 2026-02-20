extends CharacterBody3D
## Third-person player controller with weapon system for StarCraft: Ghost port.
##
## WASD movement, mouse look (third-person orbit camera),
## sprint, jump, gravity, flashlight, and shooting.

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

## Audio paths
const AUDIO_DIR := "res://assets/audio/"
const WEAPON_FIRE_SOUND := "res://assets/audio/weapons/1_2_1_0012_bullet_turret_fire01.wav"

## Weapon definitions
const WEAPONS := {
	"rifle": {
		"name": "C-10 Canister Rifle",
		"damage": 25.0,
		"fire_rate": 0.15,    # seconds between shots
		"range": 200.0,
		"ammo_max": 30,
		"reload_time": 1.8,
		"spread": 0.02,       # radians
		"auto_fire": true,
	},
	"pistol": {
		"name": "Ghost Pistol",
		"damage": 35.0,
		"fire_rate": 0.4,
		"range": 150.0,
		"ammo_max": 12,
		"reload_time": 1.2,
		"spread": 0.01,
		"auto_fire": false,
	},
	"sniper": {
		"name": "Sniper Mode",
		"damage": 150.0,
		"fire_rate": 1.5,
		"range": 500.0,
		"ammo_max": 5,
		"reload_time": 2.5,
		"spread": 0.001,
		"auto_fire": false,
	},
}

@onready var camera_pivot: Node3D = $CameraPivot
@onready var camera: Camera3D = $CameraPivot/Camera3D
@onready var model_root: Node3D = $ModelRoot
@onready var flashlight: SpotLight3D = $CameraPivot/Camera3D/Flashlight

# Player stats
var health: float = 100.0
var max_health: float = 100.0
var armor: float = 50.0
var max_armor: float = 50.0
var is_dead: bool = false

# Weapon state
var current_weapon: String = "rifle"
var ammo: Dictionary = { "rifle": 30, "pistol": 12, "sniper": 5 }
var ammo_reserve: Dictionary = { "rifle": 120, "pistol": 48, "sniper": 15 }
var fire_timer: float = 0.0
var reload_timer: float = 0.0
var is_reloading: bool = false
var kills: int = 0

# Camera
var pitch: float = -0.2
var yaw: float = 0.0
var mouse_captured: bool = true

# Muzzle flash
var muzzle_flash: MeshInstance3D = null
var muzzle_timer: float = 0.0

# Hit marker
var hit_marker_timer: float = 0.0

# Damage feedback
var damage_flash_timer: float = 0.0

# Audio
var fire_audio: AudioStreamPlayer3D = null

# HUD references (created dynamically)
var hud: CanvasLayer = null
var crosshair: Control = null
var health_label: Label = null
var ammo_label: Label = null
var weapon_label: Label = null
var kill_label: Label = null
var hit_marker: Control = null
var damage_overlay: ColorRect = null
var reload_label: Label = null


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_load_player_model()
	_create_muzzle_flash()
	_create_audio()
	_create_hud()


func _load_player_model() -> void:
	var packed = load(PLAYER_MODEL)
	if packed is PackedScene:
		var inst := (packed as PackedScene).instantiate()
		if inst != null:
			model_root.add_child(inst)
			inst.scale = Vector3.ONE * 0.02
			return
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


func _create_muzzle_flash() -> void:
	muzzle_flash = MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.15
	sphere.height = 0.3
	muzzle_flash.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.8, 0.2, 0.9)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.6, 0.1)
	mat.emission_energy_multiplier = 5.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	muzzle_flash.material_override = mat
	muzzle_flash.visible = false
	# Position at approximate weapon muzzle
	muzzle_flash.position = Vector3(0.3, 1.2, -1.0)
	model_root.add_child(muzzle_flash)


func _create_audio() -> void:
	fire_audio = AudioStreamPlayer3D.new()
	fire_audio.name = "FireAudio"
	fire_audio.max_db = 6.0
	fire_audio.unit_size = 15.0
	var stream = load(WEAPON_FIRE_SOUND)
	if stream is AudioStream:
		fire_audio.stream = stream
	add_child(fire_audio)


func _create_hud() -> void:
	hud = CanvasLayer.new()
	hud.name = "PlayerHUD"
	hud.layer = 10
	add_child(hud)

	# ── Crosshair ──
	crosshair = Control.new()
	crosshair.name = "Crosshair"
	crosshair.set_anchors_preset(Control.PRESET_CENTER)
	crosshair.custom_minimum_size = Vector2(40, 40)
	crosshair.position = Vector2(-20, -20)
	hud.add_child(crosshair)
	crosshair.draw.connect(_draw_crosshair)

	# ── Health bar (bottom left) ──
	health_label = Label.new()
	health_label.name = "HealthLabel"
	health_label.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	health_label.position = Vector2(20, -80)
	health_label.add_theme_font_size_override("font_size", 20)
	health_label.add_theme_color_override("font_color", Color(0.2, 1.0, 0.3))
	health_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	health_label.add_theme_constant_override("shadow_offset_x", 2)
	health_label.add_theme_constant_override("shadow_offset_y", 2)
	hud.add_child(health_label)

	# ── Ammo counter (bottom right) ──
	ammo_label = Label.new()
	ammo_label.name = "AmmoLabel"
	ammo_label.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	ammo_label.position = Vector2(-220, -80)
	ammo_label.add_theme_font_size_override("font_size", 24)
	ammo_label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.5))
	ammo_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	ammo_label.add_theme_constant_override("shadow_offset_x", 2)
	ammo_label.add_theme_constant_override("shadow_offset_y", 2)
	hud.add_child(ammo_label)

	# ── Weapon name (bottom right, above ammo) ──
	weapon_label = Label.new()
	weapon_label.name = "WeaponLabel"
	weapon_label.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	weapon_label.position = Vector2(-220, -110)
	weapon_label.add_theme_font_size_override("font_size", 14)
	weapon_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.8))
	weapon_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	weapon_label.add_theme_constant_override("shadow_offset_x", 1)
	weapon_label.add_theme_constant_override("shadow_offset_y", 1)
	hud.add_child(weapon_label)

	# ── Kill counter (top right) ──
	kill_label = Label.new()
	kill_label.name = "KillLabel"
	kill_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	kill_label.position = Vector2(-180, 20)
	kill_label.add_theme_font_size_override("font_size", 18)
	kill_label.add_theme_color_override("font_color", Color(1.0, 0.4, 0.3))
	kill_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	kill_label.add_theme_constant_override("shadow_offset_x", 2)
	kill_label.add_theme_constant_override("shadow_offset_y", 2)
	hud.add_child(kill_label)

	# ── Hit marker (center, flashes on hit) ──
	hit_marker = Control.new()
	hit_marker.name = "HitMarker"
	hit_marker.set_anchors_preset(Control.PRESET_CENTER)
	hit_marker.custom_minimum_size = Vector2(30, 30)
	hit_marker.position = Vector2(-15, -15)
	hit_marker.visible = false
	hud.add_child(hit_marker)
	hit_marker.draw.connect(_draw_hit_marker)

	# ── Reload indicator (center) ──
	reload_label = Label.new()
	reload_label.name = "ReloadLabel"
	reload_label.set_anchors_preset(Control.PRESET_CENTER)
	reload_label.position = Vector2(-60, 30)
	reload_label.add_theme_font_size_override("font_size", 18)
	reload_label.add_theme_color_override("font_color", Color(1.0, 1.0, 0.5))
	reload_label.visible = false
	hud.add_child(reload_label)

	# ── Damage overlay (full screen red flash) ──
	damage_overlay = ColorRect.new()
	damage_overlay.name = "DamageOverlay"
	damage_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	damage_overlay.color = Color(0.8, 0.0, 0.0, 0.0)
	damage_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(damage_overlay)

	_update_hud()


func _draw_crosshair() -> void:
	if crosshair == null:
		return
	var center := Vector2(20, 20)
	var gap := 4.0
	var length := 10.0
	var thickness := 2.0
	var color := Color(0.1, 1.0, 0.3, 0.8)

	if hit_marker_timer > 0:
		color = Color(1.0, 0.3, 0.1, 0.9)

	# Top
	crosshair.draw_rect(Rect2(center.x - thickness * 0.5, center.y - gap - length, thickness, length), color)
	# Bottom
	crosshair.draw_rect(Rect2(center.x - thickness * 0.5, center.y + gap, thickness, length), color)
	# Left
	crosshair.draw_rect(Rect2(center.x - gap - length, center.y - thickness * 0.5, length, thickness), color)
	# Right
	crosshair.draw_rect(Rect2(center.x + gap, center.y - thickness * 0.5, length, thickness), color)

	# Center dot
	crosshair.draw_circle(center, 1.5, color)


func _draw_hit_marker() -> void:
	if hit_marker == null:
		return
	var center := Vector2(15, 15)
	var size := 8.0
	var color := Color(1.0, 0.2, 0.1, 0.9)
	# X shape
	hit_marker.draw_line(center + Vector2(-size, -size), center + Vector2(-3, -3), color, 2.0)
	hit_marker.draw_line(center + Vector2(size, -size), center + Vector2(3, -3), color, 2.0)
	hit_marker.draw_line(center + Vector2(-size, size), center + Vector2(-3, 3), color, 2.0)
	hit_marker.draw_line(center + Vector2(size, size), center + Vector2(3, 3), color, 2.0)


func _unhandled_input(event: InputEvent) -> void:
	if is_dead:
		return

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
			elif key.keycode == KEY_G:
				flashlight.visible = not flashlight.visible
			elif key.keycode == KEY_R:
				_start_reload()
			elif key.keycode == KEY_1:
				_switch_weapon("rifle")
			elif key.keycode == KEY_2:
				_switch_weapon("pistol")
			elif key.keycode == KEY_3:
				_switch_weapon("sniper")

	# Mouse click to recapture
	if event is InputEventMouseButton and not mouse_captured:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			mouse_captured = true
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	# Single-fire weapons
	if event is InputEventMouseButton and mouse_captured:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			var wep: Dictionary = WEAPONS[current_weapon]
			if not wep.get("auto_fire", false):
				_fire()

	# Mouse wheel to cycle weapons
	if event is InputEventMouseButton and mouse_captured:
		var mb := event as InputEventMouseButton
		if mb.pressed:
			if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
				_cycle_weapon(-1)
			elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_cycle_weapon(1)


func _physics_process(delta: float) -> void:
	if is_dead:
		return

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
		var forward := Vector3(sin(yaw), 0, cos(yaw))
		var right := Vector3(cos(yaw), 0, -sin(yaw))
		var move_dir := (forward * -input_dir.y + right * input_dir.x).normalized()

		velocity.x = move_dir.x * speed
		velocity.z = move_dir.z * speed
		model_root.rotation.y = atan2(move_dir.x, move_dir.z)
	else:
		velocity.x = move_toward(velocity.x, 0, speed * delta * 10.0)
		velocity.z = move_toward(velocity.z, 0, speed * delta * 10.0)

	move_and_slide()

	# Update camera orbit
	camera_pivot.global_position = global_position + Vector3(0, CAMERA_HEIGHT, 0)
	camera_pivot.rotation = Vector3(pitch, yaw, 0)

	# Auto-fire for held mouse button
	var wep: Dictionary = WEAPONS[current_weapon]
	if wep.get("auto_fire", false) and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and mouse_captured:
		_fire()

	# Update timers
	fire_timer = maxf(fire_timer - delta, 0.0)

	if is_reloading:
		reload_timer -= delta
		if reload_timer <= 0.0:
			_finish_reload()

	# Muzzle flash fade
	if muzzle_timer > 0:
		muzzle_timer -= delta
		if muzzle_timer <= 0:
			muzzle_flash.visible = false

	# Hit marker fade
	if hit_marker_timer > 0:
		hit_marker_timer -= delta
		if hit_marker_timer <= 0:
			hit_marker.visible = false
			crosshair.queue_redraw()

	# Damage flash fade
	if damage_flash_timer > 0:
		damage_flash_timer -= delta
		damage_overlay.color.a = clampf(damage_flash_timer * 2.0, 0.0, 0.4)

	_update_hud()


func _fire() -> void:
	if is_reloading or fire_timer > 0 or is_dead:
		return

	var wep: Dictionary = WEAPONS[current_weapon]

	# Check ammo
	if ammo[current_weapon] <= 0:
		_start_reload()
		return

	ammo[current_weapon] -= 1
	fire_timer = wep["fire_rate"]

	# Muzzle flash
	muzzle_flash.visible = true
	muzzle_timer = 0.06

	# Fire sound
	if fire_audio and fire_audio.stream:
		fire_audio.pitch_scale = randf_range(0.9, 1.1)
		fire_audio.play()

	# Raycast from camera center
	var space_state := get_world_3d().direct_space_state
	var cam_center := camera.global_position
	var cam_forward := -camera.global_transform.basis.z

	# Add spread
	var spread: float = wep["spread"]
	var spread_offset := Vector3(
		randf_range(-spread, spread),
		randf_range(-spread, spread),
		0.0
	)
	var aim_dir := (cam_forward + camera.global_transform.basis * spread_offset).normalized()
	var ray_end: Vector3 = cam_center + aim_dir * float(wep["range"])

	var query := PhysicsRayQueryParameters3D.create(cam_center, ray_end)
	query.exclude = [get_rid()]
	query.collide_with_areas = false
	var result := space_state.intersect_ray(query)

	if result.size() > 0:
		var hit_collider = result["collider"]
		var hit_pos: Vector3 = result["position"]

		# Check if we hit an enemy
		if hit_collider is CharacterBody3D and hit_collider.has_method("take_damage"):
			hit_collider.take_damage(wep["damage"])
			_show_hit_marker()

			# Check if enemy died
			if hit_collider.get("health") != null and hit_collider.health <= 0:
				kills += 1

		# Spawn impact effect at hit position
		_spawn_impact(hit_pos, result.get("normal", Vector3.UP))

	# Auto-reload when empty
	if ammo[current_weapon] <= 0 and ammo_reserve[current_weapon] > 0:
		call_deferred("_start_reload")


func _show_hit_marker() -> void:
	hit_marker.visible = true
	hit_marker_timer = 0.2
	crosshair.queue_redraw()


func _spawn_impact(pos: Vector3, normal: Vector3) -> void:
	## Spawn a quick impact flash at the hit point.
	var impact := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.08
	sphere.height = 0.16
	impact.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.7, 0.2, 0.8)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.5, 0.1)
	mat.emission_energy_multiplier = 3.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	impact.material_override = mat
	impact.global_position = pos
	get_tree().root.add_child(impact)

	# Fade out and remove
	var tween := impact.create_tween()
	tween.tween_property(mat, "albedo_color:a", 0.0, 0.3)
	tween.tween_callback(impact.queue_free)


func _start_reload() -> void:
	if is_reloading:
		return
	var wep: Dictionary = WEAPONS[current_weapon]
	if ammo[current_weapon] >= wep["ammo_max"]:
		return
	if ammo_reserve[current_weapon] <= 0:
		return

	is_reloading = true
	reload_timer = wep["reload_time"]
	if reload_label:
		reload_label.visible = true
		reload_label.text = "RELOADING..."


func _finish_reload() -> void:
	is_reloading = false
	var wep: Dictionary = WEAPONS[current_weapon]
	var needed: int = wep["ammo_max"] - ammo[current_weapon]
	var available: int = mini(needed, ammo_reserve[current_weapon])
	ammo[current_weapon] += available
	ammo_reserve[current_weapon] -= available
	if reload_label:
		reload_label.visible = false


func _switch_weapon(weapon_name: String) -> void:
	if weapon_name == current_weapon:
		return
	if not WEAPONS.has(weapon_name):
		return
	current_weapon = weapon_name
	is_reloading = false
	if reload_label:
		reload_label.visible = false


func _cycle_weapon(direction: int) -> void:
	var weapon_names := WEAPONS.keys()
	var idx := weapon_names.find(current_weapon)
	idx = wrapi(idx + direction, 0, weapon_names.size())
	_switch_weapon(weapon_names[idx])


func take_damage(amount: float) -> void:
	if is_dead:
		return
	# Armor absorbs 60% of damage
	if armor > 0:
		var armor_absorb := amount * 0.6
		var actual_armor_dmg := minf(armor_absorb, armor)
		armor -= actual_armor_dmg
		amount -= actual_armor_dmg

	health -= amount
	damage_flash_timer = 0.3

	if health <= 0:
		health = 0
		_die()


func _die() -> void:
	is_dead = true
	velocity = Vector3.ZERO
	# Death overlay
	if damage_overlay:
		damage_overlay.color = Color(0.5, 0.0, 0.0, 0.6)
	if reload_label:
		reload_label.visible = true
		reload_label.text = "YOU DIED — Press R to restart"
	print("Player died! Kills: %d" % kills)


func heal(amount: float) -> void:
	health = minf(health + amount, max_health)


func add_armor(amount: float) -> void:
	armor = minf(armor + amount, max_armor)


func add_ammo(weapon: String, amount: int) -> void:
	if ammo_reserve.has(weapon):
		ammo_reserve[weapon] += amount


func _update_hud() -> void:
	if health_label:
		health_label.text = "HP: %d / %d\nArmor: %d" % [int(health), int(max_health), int(armor)]
		if health < 30:
			health_label.add_theme_color_override("font_color", Color(1.0, 0.2, 0.2))
		elif health < 60:
			health_label.add_theme_color_override("font_color", Color(1.0, 0.8, 0.2))
		else:
			health_label.add_theme_color_override("font_color", Color(0.2, 1.0, 0.3))

	if ammo_label:
		ammo_label.text = "%d / %d" % [ammo[current_weapon], ammo_reserve[current_weapon]]
		if ammo[current_weapon] <= 0:
			ammo_label.add_theme_color_override("font_color", Color(1.0, 0.2, 0.2))
		else:
			ammo_label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.5))

	if weapon_label:
		var wep: Dictionary = WEAPONS[current_weapon]
		weapon_label.text = wep["name"]

	if kill_label:
		kill_label.text = "KILLS: %d" % kills

	if is_reloading and reload_label:
		var wep: Dictionary = WEAPONS[current_weapon]
		var progress: float = 1.0 - (reload_timer / float(wep["reload_time"]))
		reload_label.text = "RELOADING... %d%%" % int(progress * 100)
