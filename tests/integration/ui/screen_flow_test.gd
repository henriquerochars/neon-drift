extends GdUnitTestSuite
## Walks the whole screen flow through the screens' public methods and button signals:
## title -> menu -> options -> menu -> garage -> menu -> car select -> track select -> race.
## Profile and settings are written to test paths only.

const APP_SCENE: String = "res://src/ui/app/app.tscn"
const PROFILE_PATH: String = "user://test-ui-flow-profile.json"
const SETTINGS_PATH: String = "user://test-ui-flow-settings.cfg"
const MUSIC_VOLUME: float = 0.35
const ENGINE_PRICE: int = 400

var _app: App
var _saved_music: float = 0.0
var _saved_name: String = ""
var _launched: Array[RaceConfig] = []


func before_test() -> void:
	PlayerProfile.reset()
	GameSettings.apply_to_window = false
	_saved_music = GameSettings.music_volume
	_saved_name = GameSettings.player_name
	UiPaths.profile_path = PROFILE_PATH
	UiPaths.settings_path = SETTINGS_PATH
	_launched = []
	var scene: PackedScene = load(APP_SCENE) as PackedScene
	_app = auto_free(scene.instantiate()) as App
	add_child(_app)
	await await_idle_frame()
	_app.launcher.launch_requested.connect(_on_launch_requested)


func after_test() -> void:
	AudioDirector.stop_all()
	PlayerProfile.reset()
	GameSettings.music_volume = _saved_music
	GameSettings.player_name = _saved_name
	UiPaths.reset()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PROFILE_PATH))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SETTINGS_PATH))


func test_title_to_menu_options_garage_select_and_race() -> void:
	var router: ScreenRouter = _app.router
	assert_str(String(router.current_name)).is_equal(String(ScreenRouter.SCREEN_TITLE))
	var title: TitleScreen = router.current as TitleScreen
	assert_object(title).is_not_null()
	title.start_button.pressed.emit()
	await await_idle_frame()
	assert_str(String(router.current_name)).is_equal(String(ScreenRouter.SCREEN_MENU))

	# Options: changing the music volume updates GameSettings and saves to the test path.
	var menu: MenuScreen = router.current as MenuScreen
	menu.options_button.pressed.emit()
	await await_idle_frame()
	var options: OptionsScreen = router.current as OptionsScreen
	assert_object(options).is_not_null()
	options.music_slider.value = MUSIC_VOLUME
	assert_float(GameSettings.music_volume).is_equal_approx(MUSIC_VOLUME, 0.001)
	assert_bool(FileAccess.file_exists(SETTINGS_PATH)).is_true()
	var saved: ConfigFile = ConfigFile.new()
	assert_int(saved.load(SETTINGS_PATH)).is_equal(OK)
	assert_float(float(saved.get_value(GameSettings.SECTION, "music_volume", 0.0))).is_equal_approx(
		MUSIC_VOLUME, 0.001
	)
	assert_bool(FileAccess.file_exists(GameSettings.PATH)).is_false()
	options.back_button.pressed.emit()
	await await_idle_frame()
	assert_str(String(router.current_name)).is_equal(String(ScreenRouter.SCREEN_MENU))

	# Garage: buying engine tier 1 installs it, costs money; the paint row cycles.
	menu = router.current as MenuScreen
	menu.garage_button.pressed.emit()
	await await_idle_frame()
	var garage: GarageScreen = router.current as GarageScreen
	assert_object(garage).is_not_null()
	var car_id: StringName = garage.current_car().id
	var money_before: int = PlayerProfile.money
	var engine_row: GarageRow = garage.slot_rows[&"engine"]
	engine_row.action_button.pressed.emit()
	assert_int(PlayerProfile.tier_of(car_id, &"engine")).is_equal(1)
	assert_int(PlayerProfile.money).is_equal(money_before - ENGINE_PRICE)
	var paint_before: int = PlayerProfile.paint_of(car_id)
	garage.paint_row.action_button.pressed.emit()
	assert_int(PlayerProfile.paint_of(car_id)).is_equal((paint_before + 1) % Constants.PAINT_COUNT)
	garage.back_button.pressed.emit()
	await await_idle_frame()
	assert_str(String(router.current_name)).is_equal(String(ScreenRouter.SCREEN_MENU))
	assert_bool(FileAccess.file_exists(PROFILE_PATH)).is_true()

	# Solo: car select -> track select -> race launcher with 8 participants, one local.
	menu = router.current as MenuScreen
	menu.solo_button.pressed.emit()
	await await_idle_frame()
	var select: SelectScreen = router.current as SelectScreen
	assert_object(select).is_not_null()
	assert_str(String(select.page)).is_equal(String(SelectScreen.PAGE_CAR))
	select.next_button.pressed.emit()
	assert_int(select.car_index).is_equal(1)
	select.confirm_button.pressed.emit()
	assert_str(String(select.page)).is_equal(String(SelectScreen.PAGE_TRACK))
	assert_str(String(PlayerProfile.selected_car)).is_equal(String(Catalog.cars()[1].id))
	select.next_button.pressed.emit()
	var track_id: StringName = select.current_track().id
	select.confirm_button.pressed.emit()
	await await_idle_frame()
	assert_int(_launched.size()).is_equal(1)
	var config: RaceConfig = _launched[0]
	assert_str(String(config.track_id)).is_equal(String(track_id))
	assert_int(config.participants.size()).is_equal(Constants.MAX_PLAYERS)
	var locals: int = 0
	for participant: RaceConfig.Participant in config.participants:
		if participant.kind == RaceConfig.KIND_LOCAL:
			locals += 1
			assert_str(String(participant.car_id)).is_equal(String(PlayerProfile.selected_car))
	assert_int(locals).is_equal(1)
	assert_bool(config.online).is_false()
	assert_str(String(router.current_name)).is_equal(String(ScreenRouter.SCREEN_RACE))
	var host: RaceHost = router.current as RaceHost
	assert_object(host).is_not_null()
	if not RaceLauncher.scene_exists():
		assert_bool(host.is_placeholder_visible()).is_true()
	host.return_to_menu()
	await await_idle_frame()
	assert_str(String(router.current_name)).is_equal(String(ScreenRouter.SCREEN_MENU))


func test_lobby_opens_a_room_preview_without_the_net_lane() -> void:
	var router: ScreenRouter = _app.router
	var lobby: LobbyScreen = router.go(ScreenRouter.SCREEN_LOBBY) as LobbyScreen
	await await_idle_frame()
	assert_bool(lobby.in_room()).is_false()
	lobby.host_button.pressed.emit()
	assert_bool(lobby.in_room()).is_true()
	lobby.toggle_ready()
	assert_bool(lobby.is_ready).is_true()
	lobby.step_car(1)
	assert_str(String(PlayerProfile.selected_car)).is_equal(String(lobby.current_car().id))
	lobby.leave_button.pressed.emit()
	assert_bool(lobby.in_room()).is_false()
	lobby.back_button.pressed.emit()
	await await_idle_frame()
	assert_str(String(router.current_name)).is_equal(String(ScreenRouter.SCREEN_MENU))


func test_online_race_config_marks_the_local_seat() -> void:
	var config: RaceConfig = LobbyAdapter.build_race_config(&"coast", 7)
	assert_bool(config.online).is_true()
	assert_int(config.laps).is_equal(Catalog.track(&"coast").laps)
	# The stub has no seats; the adapter returns an empty roster without errors.
	assert_int(config.participants.size()).is_equal(LobbyAdapter.participants_data().size())


func _on_launch_requested(config: RaceConfig) -> void:
	_launched.append(config)


func after() -> void:
	AudioDirector.stop_all()


func test_online_pause_toggles_and_disconnect_surfaces_reason() -> void:
	assert_int(NetSession.host(0, LobbyProfile.new())).is_equal(OK)
	var config: RaceConfig = LobbyAdapter.build_race_config(&"coast", 7)
	_app.launcher.launch(config)
	var host: RaceHost = _app.router.current as RaceHost
	host.toggle_pause()
	assert_bool(host.pause_menu.is_open).is_true()
	assert_bool(host.paused).is_false()
	host.toggle_pause()
	assert_bool(host.pause_menu.is_open).is_false()
	NetSession.leave()
	NetSession.last_reason = NetSessionService.REASON_HOST_LEFT
	NetSession.disconnected.emit()
	var lobby: LobbyScreen = _app.router.current as LobbyScreen
	assert_object(lobby).is_not_null()
	assert_bool(lobby.in_room()).is_false()
	assert_str(lobby.status_label.text).is_equal(NetSessionService.REASON_HOST_LEFT)
	assert_bool(NetSession.disconnected.is_connected(host._on_disconnected)).is_false()
