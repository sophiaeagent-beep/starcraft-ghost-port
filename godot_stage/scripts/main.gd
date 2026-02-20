extends Node3D

const MODEL_CATALOG_PATH := "res://data/model_catalog.json"
const AUDIO_CATALOG_PATH := "res://data/audio_catalog.json"
const SAFE_NO_ASSET_LOAD := true

@onready var model_root: Node3D = $ModelRoot
@onready var audio_player: AudioStreamPlayer = $AudioPlayer
@onready var info_label: Label = $HUD/InfoPanel/InfoLabel

var model_catalog: Array = []
var audio_catalog: Array = []
var model_index: int = 0
var audio_index: int = 0
var current_model: Node = null


func _ready() -> void:
	print("MAIN_READY: model/audio browser")
	if SAFE_NO_ASSET_LOAD:
		info_label.text = "\n".join([
			"Main Scene Safe Mode",
			"Asset loading is disabled to prevent crashes.",
			"",
			"Press L to return to Level1.",
		])
		return
	model_catalog = _read_json_array(MODEL_CATALOG_PATH)
	audio_catalog = _read_json_array(AUDIO_CATALOG_PATH)
	_spawn_model(0)
	_load_audio(0)
	_refresh_info()


func _unhandled_input(event: InputEvent) -> void:
	if SAFE_NO_ASSET_LOAD:
		if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_L:
			get_tree().change_scene_to_file("res://scenes/Level1.tscn")
		return
	if event.is_action_pressed("ui_right"):
		_spawn_model(1)
		_refresh_info()
	elif event.is_action_pressed("ui_left"):
		_spawn_model(-1)
		_refresh_info()
	elif event.is_action_pressed("ui_up"):
		_load_audio(1)
		_refresh_info()
	elif event.is_action_pressed("ui_down"):
		_load_audio(-1)
		_refresh_info()
	elif event.is_action_pressed("ui_accept"):
		_toggle_audio()
		_refresh_info()
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_L:
			get_tree().change_scene_to_file("res://scenes/Level1.tscn")


func _spawn_model(step: int) -> void:
	if SAFE_NO_ASSET_LOAD:
		return
	if model_catalog.is_empty():
		_clear_current_model()
		return

	model_index = wrapi(model_index + step, 0, model_catalog.size())
	_clear_current_model()

	var item: Dictionary = model_catalog[model_index]
	var resource_path := str(item.get("resource_path", ""))
	var packed := load(resource_path)
	if packed is PackedScene:
		current_model = (packed as PackedScene).instantiate()
		model_root.add_child(current_model)
	else:
		current_model = null


func _clear_current_model() -> void:
	if current_model != null and is_instance_valid(current_model):
		current_model.queue_free()
	current_model = null


func _load_audio(step: int) -> void:
	if SAFE_NO_ASSET_LOAD:
		audio_player.stop()
		audio_player.stream = null
		return
	if audio_catalog.is_empty():
		audio_player.stop()
		audio_player.stream = null
		return

	audio_index = wrapi(audio_index + step, 0, audio_catalog.size())
	var item: Dictionary = audio_catalog[audio_index]
	var resource_path := str(item.get("resource_path", ""))
	var stream := load(resource_path)
	if stream is AudioStream:
		audio_player.stream = stream
		audio_player.stop()


func _toggle_audio() -> void:
	if audio_player.stream == null:
		return
	if audio_player.playing:
		audio_player.stop()
	else:
		audio_player.play()


func _refresh_info() -> void:
	var model_text := "Model: none"
	if not model_catalog.is_empty():
		var m: Dictionary = model_catalog[model_index]
		model_text = "Model %d/%d: %s  [%s]" % [
			model_index + 1,
			model_catalog.size(),
			str(m.get("name", "unnamed")),
			str(m.get("mode", "unknown")),
		]

	var audio_text := "Audio: none"
	var play_text := "stopped"
	if audio_player.playing:
		play_text = "playing"
	if not audio_catalog.is_empty():
		var a: Dictionary = audio_catalog[audio_index]
		var cue := str(a.get("cue_name_guess", ""))
		if cue == "":
			cue = "(no cue)"
		audio_text = "Audio %d/%d: %s/%s %s (%s)" % [
			audio_index + 1,
			audio_catalog.size(),
			str(a.get("bank", "")),
			str(a.get("stream_index", "")),
			cue,
			play_text,
		]

	info_label.text = "\n".join([
		"Ghost Model/Audio Browser",
		model_text,
		audio_text,
		"",
		"Controls:",
		"Left/Right = previous/next model",
		"Up/Down = previous/next audio stream",
		"Enter = play/stop audio",
		"L = open Level1 assembler scene",
	])


func _read_json_array(path: String) -> Array:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var parsed = JSON.parse_string(f.get_as_text())
	if parsed is Array:
		return parsed
	return []
