class_name RaceHost
extends UiScreen
## The race wrapper screen: hosts the RaceScene, the HUD overlay and the pause menu, polls the
## pause action (the only allowed Input access, through LocalDriverInputSource) and routes to
## the results screen on RaceBus.race_finished.

const PLACEHOLDER_SECONDS: float = 2.0
const PLACEHOLDER_TEXT: String = "RACE SCENE MISSING"
const STATE_METHOD: StringName = &"state_of"
const LOCAL_ID_METHOD: StringName = &"local_id"
const PAUSE_METHOD: StringName = &"pause"
const STATS_METHOD: StringName = &"stats_of"

var config: RaceConfig
var online: bool = false
var race: Node
var paused: bool = false

var _placeholder_timer: Timer

@onready var race_root: Node = %RaceRoot
@onready var hud: HudOverlay = %Hud
@onready var pause_menu: PauseMenu = %PauseMenu
@onready var placeholder: Label = %Placeholder


func _ready() -> void:
	super()
	placeholder.text = PLACEHOLDER_TEXT
	placeholder.visible = false
	pause_menu.resume_requested.connect(set_paused.bind(false))
	pause_menu.quit_requested.connect(quit_to_menu)
	set_process(false)


func _process(_delta: float) -> void:
	if LocalDriverInputSource.is_pause_pressed():
		toggle_pause()
	_update_engine_audio()


func enter(args: Dictionary) -> void:
	config = args.get("config") as RaceConfig
	online = bool(args.get("online", false))
	race = RaceLauncher.instantiate_race()
	if race == null or config == null:
		show_placeholder()
		return
	race_root.add_child(race)
	if online:
		LobbyAdapter.attach_sync(race)
		NetSession.disconnected.connect(_on_disconnected)
	RaceBus.race_finished.connect(_on_race_finished)
	var track: TrackDef = Catalog.track(config.track_id)
	if track != null:
		AudioDirector.set_race_music(track.music)
	RaceLauncher.start_race(race, config)
	AudioDirector.set_local_id(local_id())
	hud.bind(race)
	set_process(true)


func leave() -> void:
	set_process(false)
	if NetSession.disconnected.is_connected(_on_disconnected):
		NetSession.disconnected.disconnect(_on_disconnected)
	if RaceBus.race_finished.is_connected(_on_race_finished):
		RaceBus.race_finished.disconnect(_on_race_finished)
	AudioDirector.stop_all_loops()
	AudioDirector.set_local_id(Constants.INVALID_ID)


## Engine pitch follows the local car's speed; the nitro loop follows its nitro state.
func _update_engine_audio() -> void:
	if race == null or paused or not race.has_method(STATE_METHOD):
		return
	var id: int = local_id()
	var state: CarState = race.call(STATE_METHOD, id) as CarState
	if state == null:
		return
	var top_speed: float = 0.0
	if race.has_method(STATS_METHOD):
		var stats: CarStats = race.call(STATS_METHOD, id) as CarStats
		top_speed = stats.top_speed if stats != null else 0.0
	var ratio: float = state.speed / top_speed if top_speed > 0.0 else 0.0
	AudioDirector.set_engine(clampf(ratio, 0.0, 1.0), state.is_nitro_active())


## Shown when the race scene has not landed yet; returns to the menu after a short delay.
func show_placeholder() -> void:
	placeholder.visible = true
	_placeholder_timer = Timer.new()
	_placeholder_timer.one_shot = true
	_placeholder_timer.wait_time = PLACEHOLDER_SECONDS
	_placeholder_timer.timeout.connect(return_to_menu)
	add_child(_placeholder_timer)
	_placeholder_timer.start()


func is_placeholder_visible() -> bool:
	return placeholder.visible


func return_to_menu() -> void:
	go(ScreenRouter.SCREEN_MENU)


func set_paused(value: bool) -> void:
	if race == null:
		return
	paused = value and not online
	if race.has_method(PAUSE_METHOD):
		race.call(PAUSE_METHOD, paused)
	if value:
		pause_menu.open(online)
	else:
		pause_menu.close()


func quit_to_menu() -> void:
	if online:
		LobbyAdapter.leave()
	return_to_menu()


func local_integrity() -> float:
	if race == null or not race.has_method(STATE_METHOD):
		return PlayerProfile.FULL_INTEGRITY
	var state: CarState = race.call(STATE_METHOD, local_id()) as CarState
	return state.integrity if state != null else PlayerProfile.FULL_INTEGRITY


func local_id() -> int:
	if race != null and race.has_method(LOCAL_ID_METHOD):
		return int(race.call(LOCAL_ID_METHOD))
	var local: RaceConfig.Participant = config.local_participant() if config != null else null
	return local.id if local != null else RaceLauncher.LOCAL_ID


func _on_race_finished(results: Array[Dictionary]) -> void:
	set_process(false)
	go(
		ScreenRouter.SCREEN_RESULTS,
		{
			"results": results,
			"local_id": local_id(),
			"integrity": local_integrity(),
			"config": config,
			"online": online,
		}
	)


func toggle_pause() -> void:
	set_paused(not pause_menu.is_open)


func _on_disconnected() -> void:
	var reason: String = NetSession.last_reason
	set_process(false)
	go(ScreenRouter.SCREEN_LOBBY, {"reason": reason})
