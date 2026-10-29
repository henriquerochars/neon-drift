class_name RaceLauncher
extends Node
## The only place that builds a RaceConfig for a solo race and instantiates the race scene.
## The race lane delivers res://src/gameplay/race/race_scene.tscn; until it exists
## instantiate_race() returns null and RaceHost shows a placeholder.

signal launch_requested(config: RaceConfig)

const RACE_SCENE_PATH: String = "res://src/gameplay/race/race_scene.tscn"
const LOCAL_ID: int = 0
const AI_FIRST_ID: int = 1
const START_METHOD: StringName = &"start"

var router: ScreenRouter
var last_config: RaceConfig


static func scene_exists() -> bool:
	return ResourceLoader.exists(RACE_SCENE_PATH)


## Instantiates the race scene, or returns null when the race lane has not landed yet.
static func instantiate_race() -> Node:
	if not scene_exists():
		return null
	var scene: PackedScene = load(RACE_SCENE_PATH) as PackedScene
	if scene == null:
		return null
	return scene.instantiate()


## Calls RaceScene.start(config) through the documented contract.
static func start_race(race: Node, config: RaceConfig) -> void:
	if race != null and race.has_method(START_METHOD):
		race.call(START_METHOD, config)


## Solo race: the profile's car as the local player plus MAX_PLAYERS - 1 AI rivals.
static func build_solo_config(car_id: StringName, track_id: StringName, seed: int) -> RaceConfig:
	var config: RaceConfig = RaceConfig.new()
	config.track_id = track_id
	config.seed = seed
	config.online = false
	var track: TrackDef = Catalog.track(track_id)
	if track != null:
		config.laps = track.laps
	var local: RaceConfig.Participant = config.add_participant(
		LOCAL_ID,
		GameSettings.player_name,
		car_id,
		RaceConfig.KIND_LOCAL,
		PlayerProfile.paint_of(car_id)
	)
	local.tiers = (PlayerProfile.parts.get(car_id, {}) as Dictionary).duplicate()
	local.integrity = PlayerProfile.integrity_of(car_id)
	AiRoster.fill(config, Constants.MAX_PLAYERS - 1, seed, AI_FIRST_ID)
	return config


## Records the config, notifies listeners and routes to the race host screen.
func launch(config: RaceConfig) -> void:
	last_config = config
	launch_requested.emit(config)
	if router != null:
		router.go(ScreenRouter.SCREEN_RACE, {"config": config, "online": config.online})
