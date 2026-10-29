extends GdUnitTestSuite
## AudioDirector: every manifest entry loads as an AudioStream, loop flags match the committed
## .import files, unknown SFX names are harmless and RaceBus signals reach the players.

const MANIFEST_PATH: String = "res://audio/manifest.json"
const RESOURCE_PREFIX: String = "res://"
const IMPORT_SUFFIX: String = ".import"
const PARAMS_SECTION: String = "params"
const LOOP_KEY: String = "loop"
const ROLE_MUSIC: String = "music"
const MIN_SFX_COUNT: int = 19
const MIN_MUSIC_COUNT: int = 4
const UNKNOWN_NAME: StringName = &"does_not_exist"
const PITCH_EPSILON: float = 0.001
const SETTLE_SECONDS: float = 0.2


func after_test() -> void:
	AudioDirector.stop_all()
	AudioDirector.set_local_id(Constants.INVALID_ID)


## Let the mixer thread drop its playbacks so no stream is reported in use at exit.
func after() -> void:
	AudioDirector.stop_all()
	await get_tree().create_timer(SETTLE_SECONDS).timeout


func _manifest_entries() -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST_PATH))
	assert_bool(parsed is Dictionary).is_true()
	var manifest: Dictionary = parsed
	var files: Variant = manifest.get("files", [])
	assert_bool(files is Array).is_true()
	for item: Variant in files:
		if item is Dictionary:
			entries.append(item)
	return entries


func test_every_manifest_entry_loads_as_audio_stream() -> void:
	var music_count: int = 0
	var sfx_count: int = 0
	for entry: Dictionary in _manifest_entries():
		var path: String = RESOURCE_PREFIX + str(entry.get("path"))
		var stream_name: StringName = StringName(str(entry.get("name")))
		assert_bool(ResourceLoader.exists(path)).override_failure_message(path).is_true()
		var stream: AudioStream = ResourceLoader.load(path) as AudioStream
		assert_object(stream).override_failure_message(path).is_not_null()
		assert_bool(AudioDirector.has_stream(stream_name)).override_failure_message(path).is_true()
		assert_float(stream.get_length()).is_greater(0.0)
		if str(entry.get("role")) == ROLE_MUSIC:
			music_count += 1
		else:
			sfx_count += 1
	assert_int(music_count).is_greater_equal(MIN_MUSIC_COUNT)
	assert_int(sfx_count).is_greater_equal(MIN_SFX_COUNT)


func test_loop_flags_match_import_files() -> void:
	for entry: Dictionary in _manifest_entries():
		var path: String = RESOURCE_PREFIX + str(entry.get("path"))
		var expected: bool = bool(entry.get("loop", false))
		var config: ConfigFile = ConfigFile.new()
		assert_int(config.load(path + IMPORT_SUFFIX)).override_failure_message(path).is_equal(OK)
		var imported: bool = bool(config.get_value(PARAMS_SECTION, LOOP_KEY, false))
		assert_bool(imported).override_failure_message(path).is_equal(expected)
		var stream: AudioStreamOggVorbis = ResourceLoader.load(path) as AudioStreamOggVorbis
		assert_object(stream).override_failure_message(path).is_not_null()
		assert_bool(stream.loop).override_failure_message(path).is_equal(expected)
		if str(entry.get("role")) == ROLE_MUSIC and expected:
			assert_bool(bool(config.get_value(PARAMS_SECTION, LOOP_KEY, false))).is_true()


func test_unknown_sfx_does_not_crash() -> void:
	var before: StringName = AudioDirector.last_sfx()
	AudioDirector.play_sfx(UNKNOWN_NAME)
	AudioDirector.play_sfx(UNKNOWN_NAME)
	assert_bool(AudioDirector.has_stream(UNKNOWN_NAME)).is_false()
	assert_str(String(AudioDirector.last_sfx())).is_equal(String(before))


func test_nitro_signal_plays_a_pool_player() -> void:
	RaceBus.nitro_activated.emit(0)
	assert_str(String(AudioDirector.last_sfx())).is_equal("nitro_ignite")
	var expected: AudioStream = AudioDirector.stream_of(&"nitro_ignite")
	var found: bool = false
	for player: AudioStreamPlayer in AudioDirector.sfx_players():
		if player.stream == expected:
			found = true
	assert_bool(found).is_true()


func test_signals_map_to_sfx_names() -> void:
	RaceBus.jump_started.emit(0)
	assert_str(String(AudioDirector.last_sfx())).is_equal("thruster_jump")
	RaceBus.car_landed.emit(0, true)
	assert_str(String(AudioDirector.last_sfx())).is_equal("hard_landing")
	RaceBus.car_landed.emit(0, false)
	assert_str(String(AudioDirector.last_sfx())).is_equal("landing")
	RaceBus.car_crushed.emit(0, 1)
	assert_str(String(AudioDirector.last_sfx())).is_equal("crush")
	RaceBus.car_bumped.emit(0)
	assert_str(String(AudioDirector.last_sfx())).is_equal("bump")
	RaceBus.scenery_hit.emit(0)
	assert_str(String(AudioDirector.last_sfx())).is_equal("scenery_hit")
	RaceBus.countdown_tick.emit(3)
	assert_str(String(AudioDirector.last_sfx())).is_equal("countdown_beep")
	RaceBus.ui_moved.emit()
	assert_str(String(AudioDirector.last_sfx())).is_equal("menu_move")
	RaceBus.ui_confirmed.emit()
	assert_str(String(AudioDirector.last_sfx())).is_equal("menu_confirm")
	RaceBus.ui_cancelled.emit()
	assert_str(String(AudioDirector.last_sfx())).is_equal("menu_cancel")
	RaceBus.purchase_made.emit(&"engine")
	assert_str(String(AudioDirector.last_sfx())).is_equal("buy")


func test_lap_and_finish_follow_the_local_id() -> void:
	AudioDirector.set_local_id(2)
	RaceBus.ui_moved.emit()
	RaceBus.lap_completed.emit(1, 1)
	assert_str(String(AudioDirector.last_sfx())).is_equal("menu_move")
	RaceBus.lap_completed.emit(2, 1)
	assert_str(String(AudioDirector.last_sfx())).is_equal("lap")
	RaceBus.car_finished.emit(1, 1, 60.0)
	assert_str(String(AudioDirector.last_sfx())).is_equal("lap")
	RaceBus.car_finished.emit(2, 2, 61.0)
	assert_str(String(AudioDirector.last_sfx())).is_equal("finish")


func test_music_follows_screens_and_race_phases() -> void:
	RaceBus.screen_changed.emit(&"title")
	assert_str(String(AudioDirector.current_music())).is_equal("menu_theme")
	AudioDirector.set_race_music(&"race_b")
	RaceBus.race_phase_changed.emit(Constants.PHASE_COUNTDOWN)
	assert_str(String(AudioDirector.current_music())).is_equal("")
	RaceBus.race_started.emit()
	assert_str(String(AudioDirector.last_sfx())).is_equal("go")
	assert_str(String(AudioDirector.current_music())).is_equal("race_b")
	AudioDirector.play_music(&"race_a")
	assert_str(String(AudioDirector.current_music())).is_equal("race_a")
	var results: Array[Dictionary] = []
	RaceBus.race_finished.emit(results)
	assert_str(String(AudioDirector.current_music())).is_equal("results_jingle")
	RaceBus.screen_changed.emit(&"menu")
	assert_str(String(AudioDirector.current_music())).is_equal("menu_theme")


func test_engine_and_offroad_loops() -> void:
	var loops: Array[AudioStreamPlayer] = AudioDirector.loop_players()
	AudioDirector.set_engine(0.0, false)
	assert_object(loops[0].stream).is_same(AudioDirector.stream_of(&"engine_loop"))
	assert_float(loops[0].pitch_scale).is_equal_approx(
		AudioDirector.ENGINE_PITCH_MIN, PITCH_EPSILON
	)
	assert_object(loops[1].stream).is_null()
	AudioDirector.set_engine(1.0, true)
	assert_float(loops[0].pitch_scale).is_equal_approx(
		AudioDirector.ENGINE_PITCH_MAX, PITCH_EPSILON
	)
	assert_object(loops[1].stream).is_same(AudioDirector.stream_of(&"nitro_loop"))
	AudioDirector.set_offroad(true)
	assert_object(loops[2].stream).is_same(AudioDirector.stream_of(&"offroad_loop"))
	AudioDirector.stop_all_loops()
	for player: AudioStreamPlayer in loops:
		assert_bool(player.playing).is_false()
