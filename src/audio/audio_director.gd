extends Node
## Autoload AudioDirector: plays the generated soundtrack and SFX listed in audio/manifest.json
## in response to RaceBus signals. Music crossfades between two players on the Music bus; SFX
## one-shots share a pool on the SFX bus; the engine, nitro and offroad loops have their own
## players. A missing stream warns once and is otherwise silent.
##
## Other lanes call: play_music(track.music) (or set_race_music) when a race starts,
## set_engine(speed_ratio, nitro) every physics tick, set_offroad(active) and set_local_id(id).

const MANIFEST_PATH: String = "res://audio/manifest.json"
const RESOURCE_PREFIX: String = "res://"
const KEY_FILES: String = "files"
const KEY_NAME: String = "name"
const KEY_PATH: String = "path"
const KEY_LOOP: String = "loop"
const SFX_POOL_SIZE: int = 8
const MUSIC_PLAYER_COUNT: int = 2
const CROSSFADE_SECONDS: float = 0.6
const SILENT_LINEAR: float = 0.001
const FULL_LINEAR: float = 1.0
const ENGINE_PITCH_MIN: float = 0.6
const ENGINE_PITCH_MAX: float = 1.8
const MUSIC_MENU: StringName = &"menu_theme"
const MUSIC_RESULTS: StringName = &"results_jingle"
const SFX_ENGINE: StringName = &"engine_loop"
const SFX_NITRO_LOOP: StringName = &"nitro_loop"
const SFX_OFFROAD: StringName = &"offroad_loop"
const SFX_NITRO_IGNITE: StringName = &"nitro_ignite"
const SFX_THRUSTER: StringName = &"thruster_jump"
const SFX_LANDING: StringName = &"landing"
const SFX_HARD_LANDING: StringName = &"hard_landing"
const SFX_CRUSH: StringName = &"crush"
const SFX_BUMP: StringName = &"bump"
const SFX_SCENERY: StringName = &"scenery_hit"
const SFX_COUNTDOWN: StringName = &"countdown_beep"
const SFX_GO: StringName = &"go"
const SFX_LAP: StringName = &"lap"
const SFX_FINISH: StringName = &"finish"
const SFX_MENU_MOVE: StringName = &"menu_move"
const SFX_MENU_CONFIRM: StringName = &"menu_confirm"
const SFX_MENU_CANCEL: StringName = &"menu_cancel"
const SFX_BUY: StringName = &"buy"
const MENU_SCREENS: Array[StringName] = [
	&"title",
	&"menu",
	&"garage",
	&"options",
	&"select",
	&"lobby",
]

var _streams: Dictionary = {}
var _warned: Dictionary = {}
var _music_players: Array[AudioStreamPlayer] = []
var _music_index: int = 0
var _music_tween: Tween = null
var _current_music: StringName = &""
var _race_music: StringName = &""
var _sfx_pool: Array[AudioStreamPlayer] = []
var _sfx_next: int = 0
var _last_sfx: StringName = &""
var _engine_player: AudioStreamPlayer = null
var _nitro_player: AudioStreamPlayer = null
var _offroad_player: AudioStreamPlayer = null
var _local_id: int = Constants.INVALID_ID


func _ready() -> void:
	load_manifest()
	_build_players()
	_connect_bus()


## Reloads the manifest and its streams. Entries whose file fails to load are skipped.
func load_manifest(path: String = MANIFEST_PATH) -> void:
	_streams.clear()
	if not FileAccess.file_exists(path):
		push_warning("AudioDirector: manifest not found at %s" % path)
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary:
		push_warning("AudioDirector: manifest %s is not a JSON object" % path)
		return
	var manifest: Dictionary = parsed
	var files: Variant = manifest.get(KEY_FILES, [])
	if not files is Array:
		return
	for item: Variant in files:
		if item is Dictionary:
			_load_entry(item)


func has_stream(stream_name: StringName) -> bool:
	return _streams.has(stream_name)


func stream_of(stream_name: StringName) -> AudioStream:
	return _streams.get(stream_name, null) as AudioStream


func current_music() -> StringName:
	return _current_music


func last_sfx() -> StringName:
	return _last_sfx


func sfx_players() -> Array[AudioStreamPlayer]:
	return _sfx_pool


func loop_players() -> Array[AudioStreamPlayer]:
	return [_engine_player, _nitro_player, _offroad_player]


## The participant id whose lap, finish and offroad events are audible. INVALID_ID = everyone.
func set_local_id(participant_id: int) -> void:
	_local_id = participant_id


## Crossfades to a music stream. Any music other than the menu theme or the results jingle is
## remembered as the race music and resumed by race_started after the countdown silence.
func play_music(music_name: StringName) -> void:
	if music_name != MUSIC_MENU and music_name != MUSIC_RESULTS:
		_race_music = music_name
	if music_name == _current_music and _music_players[_music_index].playing:
		return
	var stream: AudioStream = _stream_for(music_name)
	if stream == null:
		return
	var outgoing: AudioStreamPlayer = _music_players[_music_index]
	_music_index = (_music_index + 1) % MUSIC_PLAYER_COUNT
	var incoming: AudioStreamPlayer = _music_players[_music_index]
	incoming.stream = stream
	_set_linear(SILENT_LINEAR, incoming)
	incoming.play()
	_current_music = music_name
	_crossfade(outgoing, incoming)


## Fades the current music out over the crossfade time.
func stop_music() -> void:
	_current_music = &""
	var outgoing: AudioStreamPlayer = _music_players[_music_index]
	if not outgoing.playing:
		return
	_kill_music_tween()
	_music_tween = create_tween()
	var from: float = db_to_linear(outgoing.volume_db)
	_music_tween.tween_method(_set_linear.bind(outgoing), from, SILENT_LINEAR, CROSSFADE_SECONDS)
	_music_tween.tween_callback(outgoing.stop)


## Names the music race_started will play (TrackDef.music: race_a / race_b).
func set_race_music(music_name: StringName) -> void:
	_race_music = music_name


func play_sfx(sfx_name: StringName, pitch: float = 1.0) -> void:
	var stream: AudioStream = _stream_for(sfx_name)
	if stream == null:
		return
	var player: AudioStreamPlayer = _free_sfx_player()
	player.stream = stream
	player.pitch_scale = pitch
	player.play()
	_last_sfx = sfx_name


## Call every physics tick while racing. speed_ratio in [0, 1] maps to the engine pitch range.
func set_engine(speed_ratio: float, nitro: bool) -> void:
	_run_loop(_engine_player, SFX_ENGINE, true)
	var ratio: float = clampf(speed_ratio, 0.0, 1.0)
	_engine_player.pitch_scale = lerpf(ENGINE_PITCH_MIN, ENGINE_PITCH_MAX, ratio)
	_run_loop(_nitro_player, SFX_NITRO_LOOP, nitro)


func set_offroad(active: bool) -> void:
	_run_loop(_offroad_player, SFX_OFFROAD, active)


func stop_all_loops() -> void:
	for player: AudioStreamPlayer in loop_players():
		player.stop()


## Releases every stream and player so the engine does not report resources still in use at
## exit: the dummy audio driver never mixes again after the tree closes, so playbacks must go now.
func _exit_tree() -> void:
	stop_all()
	var players: Array[AudioStreamPlayer] = []
	players.append_array(_music_players)
	players.append_array(_sfx_pool)
	players.append_array(loop_players())
	for player: AudioStreamPlayer in players:
		player.stream = null
		if player.get_parent() == self:
			remove_child(player)
		player.free()
	_music_players.clear()
	_sfx_pool.clear()
	_engine_player = null
	_nitro_player = null
	_offroad_player = null
	_streams.clear()


## Backstop for deletion outside the usual scene-tree shutdown path.
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		stop_all()


## Stops playback and releases stream references immediately (also used by tests).
func stop_all() -> void:
	_kill_music_tween()
	_current_music = &""
	var players: Array[AudioStreamPlayer] = []
	players.append_array(_music_players)
	players.append_array(_sfx_pool)
	players.append_array(loop_players())
	for player: AudioStreamPlayer in players:
		if is_instance_valid(player):
			player.stop()
			player.stream = null


func _load_entry(entry: Dictionary) -> void:
	var stream_name: StringName = StringName(str(entry.get(KEY_NAME, "")))
	var relative: String = str(entry.get(KEY_PATH, ""))
	if stream_name.is_empty() or relative.is_empty():
		return
	var resource_path: String = RESOURCE_PREFIX + relative
	if not ResourceLoader.exists(resource_path):
		push_warning("AudioDirector: %s is missing (%s)" % [stream_name, resource_path])
		return
	var stream: AudioStream = ResourceLoader.load(resource_path) as AudioStream
	if stream == null:
		push_warning("AudioDirector: %s is not an AudioStream" % resource_path)
		return
	if stream is AudioStreamOggVorbis:
		var ogg: AudioStreamOggVorbis = stream
		ogg.loop = bool(entry.get(KEY_LOOP, false))
	_streams[stream_name] = stream


func _build_players() -> void:
	for i: int in MUSIC_PLAYER_COUNT:
		_music_players.append(_make_player(GameSettings.BUS_MUSIC))
	for i: int in SFX_POOL_SIZE:
		_sfx_pool.append(_make_player(GameSettings.BUS_SFX))
	_engine_player = _make_player(GameSettings.BUS_SFX)
	_nitro_player = _make_player(GameSettings.BUS_SFX)
	_offroad_player = _make_player(GameSettings.BUS_SFX)


func _make_player(bus: StringName) -> AudioStreamPlayer:
	var player: AudioStreamPlayer = AudioStreamPlayer.new()
	player.bus = bus
	add_child(player)
	return player


func _connect_bus() -> void:
	RaceBus.screen_changed.connect(_on_screen_changed)
	RaceBus.race_phase_changed.connect(_on_race_phase_changed)
	RaceBus.countdown_tick.connect(_on_countdown_tick)
	RaceBus.race_started.connect(_on_race_started)
	RaceBus.lap_completed.connect(_on_lap_completed)
	RaceBus.car_finished.connect(_on_car_finished)
	RaceBus.race_finished.connect(_on_race_finished)
	RaceBus.nitro_activated.connect(_on_nitro_activated)
	RaceBus.jump_started.connect(_on_jump_started)
	RaceBus.car_landed.connect(_on_car_landed)
	RaceBus.car_crushed.connect(_on_car_crushed)
	RaceBus.car_bumped.connect(_on_car_bumped)
	RaceBus.scenery_hit.connect(_on_scenery_hit)
	RaceBus.offroad_changed.connect(_on_offroad_changed)
	RaceBus.ui_moved.connect(_on_ui_moved)
	RaceBus.ui_confirmed.connect(_on_ui_confirmed)
	RaceBus.ui_cancelled.connect(_on_ui_cancelled)
	RaceBus.purchase_made.connect(_on_purchase_made)


func _stream_for(stream_name: StringName) -> AudioStream:
	var stream: AudioStream = stream_of(stream_name)
	if stream == null and not _warned.has(stream_name):
		_warned[stream_name] = true
		push_warning("AudioDirector: no stream named %s" % stream_name)
	return stream


func _free_sfx_player() -> AudioStreamPlayer:
	for i: int in SFX_POOL_SIZE:
		var candidate: AudioStreamPlayer = _sfx_pool[(_sfx_next + i) % SFX_POOL_SIZE]
		if not candidate.playing:
			_sfx_next = (_sfx_next + i + 1) % SFX_POOL_SIZE
			return candidate
	var player: AudioStreamPlayer = _sfx_pool[_sfx_next]
	_sfx_next = (_sfx_next + 1) % SFX_POOL_SIZE
	return player


func _run_loop(player: AudioStreamPlayer, stream_name: StringName, active: bool) -> void:
	if not active:
		if player.playing:
			player.stop()
		return
	if player.playing:
		return
	var stream: AudioStream = _stream_for(stream_name)
	if stream == null:
		return
	player.stream = stream
	player.play()


func _crossfade(outgoing: AudioStreamPlayer, incoming: AudioStreamPlayer) -> void:
	_kill_music_tween()
	_music_tween = create_tween().set_parallel(true)
	_music_tween.tween_method(
		_set_linear.bind(incoming), SILENT_LINEAR, FULL_LINEAR, CROSSFADE_SECONDS
	)
	if outgoing.playing:
		var from: float = db_to_linear(outgoing.volume_db)
		_music_tween.tween_method(
			_set_linear.bind(outgoing), from, SILENT_LINEAR, CROSSFADE_SECONDS
		)
		_music_tween.chain().tween_callback(outgoing.stop)


func _kill_music_tween() -> void:
	if _music_tween != null and _music_tween.is_valid():
		_music_tween.kill()
	_music_tween = null


func _set_linear(value: float, player: AudioStreamPlayer) -> void:
	player.volume_db = linear_to_db(maxf(value, SILENT_LINEAR))


func _is_audible(participant_id: int) -> bool:
	return _local_id == Constants.INVALID_ID or participant_id == _local_id


func _on_screen_changed(screen: StringName) -> void:
	if not MENU_SCREENS.has(screen):
		return
	stop_all_loops()
	_race_music = &""
	play_music(MUSIC_MENU)


func _on_race_phase_changed(phase: StringName) -> void:
	if phase == Constants.PHASE_COUNTDOWN:
		stop_music()


func _on_countdown_tick(_value: int) -> void:
	play_sfx(SFX_COUNTDOWN)


func _on_race_started() -> void:
	play_sfx(SFX_GO)
	if not _race_music.is_empty():
		play_music(_race_music)


func _on_lap_completed(participant_id: int, _lap: int) -> void:
	if _is_audible(participant_id):
		play_sfx(SFX_LAP)


func _on_car_finished(participant_id: int, _place: int, _time: float) -> void:
	if _is_audible(participant_id):
		play_sfx(SFX_FINISH)


func _on_race_finished(_results: Array[Dictionary]) -> void:
	stop_all_loops()
	play_music(MUSIC_RESULTS)


func _on_nitro_activated(_participant_id: int) -> void:
	play_sfx(SFX_NITRO_IGNITE)


func _on_jump_started(_participant_id: int) -> void:
	play_sfx(SFX_THRUSTER)


func _on_car_landed(_participant_id: int, hard: bool) -> void:
	play_sfx(SFX_HARD_LANDING if hard else SFX_LANDING)


func _on_car_crushed(_attacker_id: int, _victim_id: int) -> void:
	play_sfx(SFX_CRUSH)


func _on_car_bumped(_participant_id: int) -> void:
	play_sfx(SFX_BUMP)


func _on_scenery_hit(_participant_id: int) -> void:
	play_sfx(SFX_SCENERY)


func _on_offroad_changed(participant_id: int, offroad: bool) -> void:
	if _local_id != Constants.INVALID_ID and participant_id == _local_id:
		set_offroad(offroad)


func _on_ui_moved() -> void:
	play_sfx(SFX_MENU_MOVE)


func _on_ui_confirmed() -> void:
	play_sfx(SFX_MENU_CONFIRM)


func _on_ui_cancelled() -> void:
	play_sfx(SFX_MENU_CANCEL)


func _on_purchase_made(_part_id: StringName) -> void:
	play_sfx(SFX_BUY)
