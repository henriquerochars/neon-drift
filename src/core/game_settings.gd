extends Node
## Autoload: player options persisted in user://settings.cfg and applied to the engine.

signal changed

const PATH: String = "user://settings.cfg"
const SECTION: String = "options"
const BUS_MASTER: StringName = &"Master"
const BUS_MUSIC: StringName = &"Music"
const BUS_SFX: StringName = &"SFX"
const MIN_SCALE: int = 1
const MAX_SCALE: int = 6
const SILENT_DB: float = -80.0
const DEFAULT_NAME: String = "RACER"
const MAX_NAME_LENGTH: int = 10

var master_volume: float = 0.8
var music_volume: float = 0.7
var sfx_volume: float = 0.9
var fullscreen: bool = false
var vsync: bool = true
var show_fps: bool = false
var window_scale: int = 4
var player_name: String = DEFAULT_NAME
## Tests set this to skip touching the window.
var apply_to_window: bool = true


func _ready() -> void:
	load_settings()
	apply()


func load_settings(path: String = PATH) -> void:
	var config: ConfigFile = ConfigFile.new()
	if config.load(path) != OK:
		return
	master_volume = float(config.get_value(SECTION, "master_volume", master_volume))
	music_volume = float(config.get_value(SECTION, "music_volume", music_volume))
	sfx_volume = float(config.get_value(SECTION, "sfx_volume", sfx_volume))
	fullscreen = bool(config.get_value(SECTION, "fullscreen", fullscreen))
	vsync = bool(config.get_value(SECTION, "vsync", vsync))
	show_fps = bool(config.get_value(SECTION, "show_fps", show_fps))
	window_scale = clampi(
		int(config.get_value(SECTION, "window_scale", window_scale)), MIN_SCALE, MAX_SCALE
	)
	player_name = sanitize_name(str(config.get_value(SECTION, "player_name", player_name)))


func save_settings(path: String = PATH) -> Error:
	var config: ConfigFile = ConfigFile.new()
	config.set_value(SECTION, "master_volume", master_volume)
	config.set_value(SECTION, "music_volume", music_volume)
	config.set_value(SECTION, "sfx_volume", sfx_volume)
	config.set_value(SECTION, "fullscreen", fullscreen)
	config.set_value(SECTION, "vsync", vsync)
	config.set_value(SECTION, "show_fps", show_fps)
	config.set_value(SECTION, "window_scale", window_scale)
	config.set_value(SECTION, "player_name", player_name)
	return config.save(path)


func apply() -> void:
	_apply_bus(BUS_MASTER, master_volume)
	_apply_bus(BUS_MUSIC, music_volume)
	_apply_bus(BUS_SFX, sfx_volume)
	if apply_to_window and DisplayServer.get_name() != "headless":
		var window: Window = get_window()
		if fullscreen:
			window.mode = Window.MODE_FULLSCREEN
		else:
			window.mode = Window.MODE_WINDOWED
			window.size = (
				Vector2i(Constants.VIEWPORT_WIDTH, Constants.VIEWPORT_HEIGHT) * window_scale
			)
		DisplayServer.window_set_vsync_mode(
			DisplayServer.VSYNC_ENABLED if vsync else DisplayServer.VSYNC_DISABLED
		)
	changed.emit()


static func sanitize_name(raw: String) -> String:
	var text: String = raw.strip_edges().to_upper().substr(0, MAX_NAME_LENGTH)
	return text if not text.is_empty() else DEFAULT_NAME


func _apply_bus(bus: StringName, volume: float) -> void:
	var index: int = AudioServer.get_bus_index(bus)
	if index < 0:
		return
	var db: float = SILENT_DB if volume <= 0.0 else linear_to_db(clampf(volume, 0.0, 1.0))
	AudioServer.set_bus_volume_db(index, db)
