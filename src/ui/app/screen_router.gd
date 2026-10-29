class_name ScreenRouter
extends Node
## Swaps screens under `container`, emits RaceBus.screen_changed and owns the FPS label.

const SCREEN_TITLE: StringName = &"title"
const SCREEN_MENU: StringName = &"menu"
const SCREEN_SELECT: StringName = &"select"
const SCREEN_GARAGE: StringName = &"garage"
const SCREEN_OPTIONS: StringName = &"options"
const SCREEN_LOBBY: StringName = &"lobby"
const SCREEN_RACE: StringName = &"race"
const SCREEN_RESULTS: StringName = &"results"
const SCENES: Dictionary = {
	SCREEN_TITLE: "res://src/ui/title/title_screen.tscn",
	SCREEN_MENU: "res://src/ui/menu/menu_screen.tscn",
	SCREEN_SELECT: "res://src/ui/select/select_screen.tscn",
	SCREEN_GARAGE: "res://src/ui/garage/garage_screen.tscn",
	SCREEN_OPTIONS: "res://src/ui/options/options_screen.tscn",
	SCREEN_LOBBY: "res://src/ui/lobby/lobby_screen.tscn",
	SCREEN_RACE: "res://src/ui/app/race_host.tscn",
	SCREEN_RESULTS: "res://src/ui/results/results_screen.tscn",
}
const FPS_FORMAT: String = "%d FPS"

@export var container: Control
@export var fps_label: Label
@export var launcher: RaceLauncher

var current_name: StringName = &""
var current: UiScreen


func _ready() -> void:
	GameSettings.changed.connect(_refresh_fps_visibility)
	_refresh_fps_visibility()


func _process(_delta: float) -> void:
	fps_label.text = FPS_FORMAT % Engine.get_frames_per_second()


## Replaces the current screen. Returns the new screen (null for an unknown name).
func go(screen: StringName, args: Dictionary = {}) -> UiScreen:
	if not SCENES.has(screen):
		push_error("ScreenRouter: unknown screen %s" % screen)
		return null
	if current != null:
		current.leave()
		container.remove_child(current)
		current.queue_free()
		current = null
	var scene: PackedScene = load(SCENES[screen]) as PackedScene
	var next: UiScreen = scene.instantiate() as UiScreen
	next.router = self
	container.add_child(next)
	current = next
	current_name = screen
	next.enter(args)
	RaceBus.screen_changed.emit(screen)
	return next


func _refresh_fps_visibility() -> void:
	if fps_label == null:
		return
	fps_label.visible = GameSettings.show_fps
	set_process(GameSettings.show_fps)
