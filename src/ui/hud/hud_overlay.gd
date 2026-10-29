class_name HudOverlay
extends CanvasLayer
## Race HUD. Reads the race each frame through the documented contract (state_of, place_of,
## lap_of, race_time, standings, local_id) and reacts to RaceBus signals for the countdown,
## lap, crush, landing and finish flashes. bind() a race (or any object with those methods).

const SPEED_TO_KMH: float = 40.0
const FLASH_SECONDS: float = 1.0
const GO_TEXT: String = "GO!"
const LAP_FORMAT: String = "LAP %d"
const LAP_COUNTER_FORMAT: String = "LAP %d/%d"
const SPEED_FORMAT: String = "%03d"
const CRUSHED_TEXT: String = "CRUSHED!"
const HARD_LANDING_TEXT: String = "HARD LANDING"
const FINISH_FORMAT: String = "FINISH! %s"
const FLASH_COLOR: Color = Color("#ff5fb4")
const GO_COLOR: Color = Color("#3bd36a")
const WARNING_COLOR: Color = Color("#e23a3a")
const FINISH_COLOR: Color = Color("#f2b134")
const NITRO_COLOR: Color = Color("#3ad1e2")
const THRUSTER_COLOR: Color = Color("#f2b134")
const INTEGRITY_COLOR: Color = Color("#3bd36a")
const INTEGRITY_LOW_COLOR: Color = Color("#e23a3a")
const INTEGRITY_LOW: float = 0.3
const METHOD_STATE: StringName = &"state_of"
const METHOD_STATS: StringName = &"stats_of"
const METHOD_PLACE: StringName = &"place_of"
const METHOD_LAP: StringName = &"lap_of"
const METHOD_LOCAL: StringName = &"local_id"
const METHOD_STANDINGS: StringName = &"standings"
const PROPERTY_TIME: StringName = &"race_time"
const PROPERTY_TRACK: StringName = &"track_model"
const PROPERTY_CONFIG: StringName = &"config"

var race: Object
var local_id: int = Constants.INVALID_ID
var laps: int = 1
var track_length: float = 0.0

var _flash_timer: Timer

@onready var speed_label: Label = %SpeedLabel
@onready var lap_label: Label = %LapLabel
@onready var time_label: Label = %TimeLabel
@onready var place_label: Label = %PlaceLabel
@onready var nitro_bar: MeterBar = %NitroBar
@onready var thruster_bar: MeterBar = %ThrusterBar
@onready var integrity_bar: MeterBar = %IntegrityBar
@onready var flash_label: Label = %FlashLabel
@onready var finish_label: Label = %FinishLabel
@onready var strip: ProgressStrip = %Strip


func _ready() -> void:
	flash_label.visible = false
	finish_label.visible = false
	nitro_bar.fill_color = NITRO_COLOR
	thruster_bar.fill_color = THRUSTER_COLOR
	integrity_bar.fill_color = INTEGRITY_COLOR
	_flash_timer = Timer.new()
	_flash_timer.one_shot = true
	_flash_timer.wait_time = FLASH_SECONDS
	_flash_timer.timeout.connect(func() -> void: flash_label.visible = false)
	add_child(_flash_timer)
	RaceBus.countdown_tick.connect(_on_countdown_tick)
	RaceBus.race_started.connect(_on_race_started)
	RaceBus.lap_completed.connect(_on_lap_completed)
	RaceBus.car_crushed.connect(_on_car_crushed)
	RaceBus.car_landed.connect(_on_car_landed)
	RaceBus.car_finished.connect(_on_car_finished)
	set_process(false)


func _process(_delta: float) -> void:
	refresh()


## Binds the race (RaceScene or a test double with the contract methods) and starts polling.
func bind(target: Object) -> void:
	race = target
	local_id = int(race.call(METHOD_LOCAL)) if race.has_method(METHOD_LOCAL) else local_id
	var config: RaceConfig = race.get(PROPERTY_CONFIG) as RaceConfig
	laps = maxi(config.laps, 1) if config != null else 1
	var model: TrackModel = race.get(PROPERTY_TRACK) as TrackModel
	track_length = model.length if model != null else 0.0
	set_process(true)
	refresh()


func unbind() -> void:
	race = null
	set_process(false)


## Pulls every value from the race and redraws the labels, meters and the progress strip.
func refresh() -> void:
	if race == null or not race.has_method(METHOD_STATE):
		return
	var state: CarState = race.call(METHOD_STATE, local_id) as CarState
	if state == null:
		return
	speed_label.text = SPEED_FORMAT % int(state.speed / SPEED_TO_KMH)
	lap_label.text = LAP_COUNTER_FORMAT % [mini(_lap_of(local_id), laps), laps]
	time_label.text = UiText.race_time(float(race.get(PROPERTY_TIME)))
	place_label.text = UiText.place(_place_of(local_id))
	nitro_bar.set_value(state.nitro)
	thruster_bar.set_value(state.thrusters)
	var integrity_fraction: float = state.integrity / _max_integrity(local_id)
	integrity_bar.set_value(
		integrity_fraction,
		INTEGRITY_LOW_COLOR if integrity_fraction <= INTEGRITY_LOW else INTEGRITY_COLOR
	)
	_refresh_strip()


func flash(text: String, color: Color = FLASH_COLOR) -> void:
	flash_label.text = text
	flash_label.add_theme_color_override(&"font_color", color)
	flash_label.visible = true
	_flash_timer.start()


func flash_text() -> String:
	return flash_label.text


func is_flash_visible() -> bool:
	return flash_label.visible


func show_finish(place: int) -> void:
	finish_label.text = FINISH_FORMAT % UiText.place(place)
	finish_label.visible = true


func is_finish_visible() -> bool:
	return finish_label.visible


func _refresh_strip() -> void:
	if not race.has_method(METHOD_STANDINGS):
		return
	var standings: Array[int] = []
	standings.assign(race.call(METHOD_STANDINGS))
	var fractions: Array[float] = []
	var local_index: int = -1
	for index: int in range(standings.size()):
		var id: int = standings[index]
		if id == local_id:
			local_index = index
		fractions.append(_progress_fraction(id))
	strip.set_progress(fractions, local_index)


func _progress_fraction(id: int) -> float:
	var state: CarState = race.call(METHOD_STATE, id) as CarState
	if state == null:
		return 0.0
	var total: float = track_length * laps
	if total <= 0.0:
		return clampf(float(_lap_of(id) - 1) / float(laps), 0.0, 1.0)
	return clampf(state.progress / total, 0.0, 1.0)


func _lap_of(id: int) -> int:
	return int(race.call(METHOD_LAP, id)) if race.has_method(METHOD_LAP) else 0


func _place_of(id: int) -> int:
	return int(race.call(METHOD_PLACE, id)) if race.has_method(METHOD_PLACE) else 1


func _max_integrity(id: int) -> float:
	if race.has_method(METHOD_STATS):
		var stats: CarStats = race.call(METHOD_STATS, id) as CarStats
		if stats != null and stats.max_integrity > 0.0:
			return stats.max_integrity
	return PlayerProfile.FULL_INTEGRITY


func _on_countdown_tick(value: int) -> void:
	flash(str(value))


func _on_race_started() -> void:
	flash(GO_TEXT, GO_COLOR)


func _on_lap_completed(participant_id: int, lap: int) -> void:
	if participant_id == local_id:
		flash(LAP_FORMAT % (lap + 1))


func _on_car_crushed(_attacker_id: int, victim_id: int) -> void:
	if victim_id == local_id:
		flash(CRUSHED_TEXT, WARNING_COLOR)


func _on_car_landed(participant_id: int, hard: bool) -> void:
	if participant_id == local_id and hard:
		flash(HARD_LANDING_TEXT, WARNING_COLOR)


func _on_car_finished(participant_id: int, place: int, _time: float) -> void:
	if participant_id == local_id:
		show_finish(place)
