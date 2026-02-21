extends Node3D
## Collectible pickup item for StarCraft: Ghost port.
##
## Uses Area3D to detect player proximity. When collected,
## applies effect (heal, add ammo, etc.) and removes itself.

enum PickupType { HEALTH, AMMO_RIFLE, AMMO_SNIPER, AMMO_GRENADE, ARMOR, SPIDER_MINE }

@export var pickup_type: PickupType = PickupType.HEALTH
@export var pickup_name: String = "pickup"
@export var amount: float = 25.0  # Health/armor amount or ammo count
@export var model_path: String = ""  # glTF path set by level loader

## Visual
var mesh_instance: MeshInstance3D = null
var label: Label3D = null
var bob_offset: float = 0.0
var initial_y: float = 0.0
var spin_speed: float = 1.5
var collected: bool = false

## Pickup definitions
const PICKUP_DATA := {
	"powhealth": { "type": 0, "amount": 25.0, "color": Color(0.1, 1.0, 0.2) },        # HEALTH
	"powhealth_large": { "type": 0, "amount": 50.0, "color": Color(0.1, 1.0, 0.2) },
	"ge_footlocker_grn_health": { "type": 0, "amount": 40.0, "color": Color(0.1, 1.0, 0.2) },
	"powgauss_2x": { "type": 1, "amount": 30.0, "color": Color(1.0, 0.9, 0.3) },       # AMMO_RIFLE
	"ge_footlocker_grn_gauss": { "type": 1, "amount": 60.0, "color": Color(1.0, 0.9, 0.3) },
	"powgrenade": { "type": 3, "amount": 3.0, "color": Color(0.9, 0.5, 0.1) },          # AMMO_GRENADE
	"ge_footlocker_grn_spider": { "type": 5, "amount": 2.0, "color": Color(0.7, 0.2, 0.8) }, # SPIDER_MINE
	"powsniper": { "type": 2, "amount": 5.0, "color": Color(0.3, 0.5, 1.0) },           # AMMO_SNIPER
}


func _ready() -> void:
	initial_y = position.y
	_auto_configure()
	_setup_visuals()
	_setup_trigger()


func _auto_configure() -> void:
	## Configure pickup type/amount from entity name.
	## Sort keys longest-first so "powhealth_large" matches before "powhealth".
	var lower := pickup_name.to_lower()
	var keys := PICKUP_DATA.keys()
	keys.sort_custom(func(a: String, b: String) -> bool: return a.length() > b.length())
	for key in keys:
		if key in lower:
			var data: Dictionary = PICKUP_DATA[key]
			pickup_type = data["type"] as PickupType
			amount = data["amount"]
			return


func _setup_visuals() -> void:
	# Determine color for this pickup type (used by ring + label + fallback box)
	var color: Color
	match pickup_type:
		PickupType.HEALTH:
			color = Color(0.1, 1.0, 0.2, 0.9)
		PickupType.AMMO_RIFLE, PickupType.AMMO_SNIPER:
			color = Color(1.0, 0.9, 0.3, 0.9)
		PickupType.AMMO_GRENADE:
			color = Color(0.9, 0.5, 0.1, 0.9)
		PickupType.ARMOR:
			color = Color(0.3, 0.5, 1.0, 0.9)
		PickupType.SPIDER_MINE:
			color = Color(0.7, 0.2, 0.8, 0.9)
		_:
			color = Color(0.5, 1.0, 0.5, 0.9)

	# Try loading a glTF model if model_path was set by the level loader
	var model_loaded := false
	if model_path != "":
		var scene = load(model_path)
		if scene is PackedScene:
			var model := (scene as PackedScene).instantiate()
			if model is Node3D:
				model.name = "PickupModel"
				model.position.y = 0.5
				add_child(model)
				mesh_instance = null
				model_loaded = true

	if not model_loaded:
		# Fallback: colored box
		mesh_instance = MeshInstance3D.new()
		var box := BoxMesh.new()

		var size: Vector3
		match pickup_type:
			PickupType.HEALTH:
				size = Vector3(0.4, 0.4, 0.4)
			PickupType.AMMO_RIFLE, PickupType.AMMO_SNIPER:
				size = Vector3(0.5, 0.3, 0.3)
			PickupType.AMMO_GRENADE:
				size = Vector3(0.3, 0.3, 0.3)
			PickupType.ARMOR:
				size = Vector3(0.5, 0.4, 0.5)
			PickupType.SPIDER_MINE:
				size = Vector3(0.35, 0.25, 0.35)
			_:
				size = Vector3(0.4, 0.4, 0.4)

		box.size = size
		mesh_instance.mesh = box

		var mat := StandardMaterial3D.new()
		mat.albedo_color = color
		mat.emission_enabled = true
		mat.emission = color * 0.5
		mat.emission_energy_multiplier = 1.5
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mesh_instance.material_override = mat
		mesh_instance.position.y = 0.5
		add_child(mesh_instance)

	# Glow ring on ground (always shown — indicates pickupable item)
	var ring := MeshInstance3D.new()
	var ring_mesh := TorusMesh.new()
	ring_mesh.inner_radius = 0.3
	ring_mesh.outer_radius = 0.5
	ring.mesh = ring_mesh
	var ring_mat := StandardMaterial3D.new()
	ring_mat.albedo_color = Color(color.r, color.g, color.b, 0.3)
	ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ring.material_override = ring_mat
	ring.rotation_degrees.x = 90
	ring.position.y = 0.05
	add_child(ring)

	# Label
	label = Label3D.new()
	label.text = _get_display_name()
	label.position = Vector3(0, 1.2, 0)
	label.pixel_size = 0.008
	label.font_size = 22
	label.modulate = color
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	add_child(label)


func _get_display_name() -> String:
	match pickup_type:
		PickupType.HEALTH: return "+%d HP" % int(amount)
		PickupType.AMMO_RIFLE: return "+%d Rifle" % int(amount)
		PickupType.AMMO_SNIPER: return "+%d Sniper" % int(amount)
		PickupType.AMMO_GRENADE: return "+%d Grenade" % int(amount)
		PickupType.ARMOR: return "+%d Armor" % int(amount)
		PickupType.SPIDER_MINE: return "+%d Spider Mine" % int(amount)
	return pickup_name


func _setup_trigger() -> void:
	var area := Area3D.new()
	area.name = "PickupZone"

	var col := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 1.5
	col.shape = sphere
	area.add_child(col)
	add_child(area)

	area.body_entered.connect(_on_body_entered)


func _on_body_entered(body: Node3D) -> void:
	if collected:
		return
	# Only collect if player
	if not (body is CharacterBody3D):
		return
	if not body.has_method("heal"):
		return  # Not the player (enemies also have CharacterBody3D)

	_apply_effect(body)
	_collect()


func _apply_effect(player: Node3D) -> void:
	match pickup_type:
		PickupType.HEALTH:
			if player.has_method("heal"):
				player.heal(amount)
				print("[Pickup] +%d HP" % int(amount))
		PickupType.AMMO_RIFLE:
			if player.has_method("add_ammo"):
				player.add_ammo("rifle", int(amount))
				print("[Pickup] +%d Rifle ammo" % int(amount))
		PickupType.AMMO_SNIPER:
			if player.has_method("add_ammo"):
				player.add_ammo("sniper", int(amount))
				print("[Pickup] +%d Sniper ammo" % int(amount))
		PickupType.AMMO_GRENADE:
			print("[Pickup] +%d Grenades (not yet implemented)" % int(amount))
		PickupType.ARMOR:
			if player.has_method("add_armor"):
				player.add_armor(amount)
				print("[Pickup] +%d Armor" % int(amount))
		PickupType.SPIDER_MINE:
			print("[Pickup] +%d Spider Mines (not yet implemented)" % int(amount))


func _collect() -> void:
	collected = true
	# Quick scale-down + fade animation
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(self, "scale", Vector3.ZERO, 0.3).set_ease(Tween.EASE_IN)
	if mesh_instance and mesh_instance.material_override:
		tween.tween_property(mesh_instance.material_override, "albedo_color:a", 0.0, 0.3)
	tween.set_parallel(false)
	tween.tween_callback(queue_free)


func _process(delta: float) -> void:
	if collected:
		return
	# Bob up and down + spin
	bob_offset += delta * 2.0
	var bob_y := 0.5 + sin(bob_offset) * 0.15
	if mesh_instance:
		mesh_instance.position.y = bob_y
		mesh_instance.rotation.y += delta * spin_speed
	else:
		# Animate the glTF model node instead
		var model := get_node_or_null("PickupModel")
		if model:
			model.position.y = bob_y
			model.rotation.y += delta * spin_speed
