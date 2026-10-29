class_name RaceScene
extends Node2D
## The playable race (docs/ARCHITECTURE.md "Race scene contract"). Runs CarSim for every
## participant at the physics tick, resolves contacts when it is the authority, ranks cars
## by progress, emits every RaceBus race signal and drives the PseudoRoad from the local car.
## The HUD lives in src/ui and reads this scene; tools drive it through step_tick().
##
## Online notes for RaceSync: the authority applies contact results to every non-remote car
## directly and emits penalty_decided for each affected id (relay it to the owning peer only,
## not back to the host's own car). apply_penalty on a client emits car_bumped / scenery_hit
## for that id; car_crushed(attacker, victim) on clients is the host's broadcast.
## force_phase(PHASE_COUNTDOWN, t) takes the seconds left; other phases take the race clock.

signal local_state_updated(id: int, packed: PackedFloat32Array)
signal penalty_decided(id: int, kind: StringName, data: Dictionary)

const COUNTDOWN_SECONDS: float = 3.0
## Seconds the race keeps running after the local car finishes.
const RACE_END_GRACE: float = 5.0
const GRID_SPACING_CAR_LENGTHS: float = 1.2
const GRID_LANE: float = 0.5
## Cars start behind the line: the first crossing starts lap 0, not lap 1.
const START_LAP: int = -1
## The camera sits this many (camera_height * camera_depth) behind the local car, which puts
## the car's base a few pixels above the bottom edge.
const PLAYER_Z_OFFSET_RATIO: float = 1.15
## Share of the local car's altitude the camera follows on a jump.
const CAMERA_ALTITUDE_FOLLOW: float = 0.35
const SHAKE_CRUSH: float = 3.0
const SHAKE_BUMP: float = 1.5
const SHAKE_SCENERY: float = 2.0
const SHAKE_DECAY: float = 8.0
const SHAKE_FREQUENCY: float = 40.0
const SHAKE_FREQUENCY_RATIO: float = 0.7
const AI_SEED_STRIDE: int = 100

var phase: StringName = Constants.PHASE_WAITING
var race_time: float = 0.0
var track_model: TrackModel
var track_def: TrackDef
var config: RaceConfig
## True offline and on the host; clients only apply penalties they receive.
var authority: bool = true
var paused: bool = false
var participants: Array[RaceParticipant] = []

var _confirmed: Dictionary = {}
var _by_id: Dictionary = {}
var _local: RaceParticipant
var _countdown_left: float = 0.0
var _last_countdown_value: int = 0
var _standings: Array[int] = []
var _next_place: int = 1
var _end_countdown: float = -1.0
var _contacts: RaceContacts = RaceContacts.new()
var _vfx: RaceVfx = RaceVfx.new()
var _results: Array[Dictionary] = []
var _metrics: Dictionary = {"crushes": 0, "bumps": 0, "scenery_hits": 0}
var _states: Array[CarState] = []
var _shake: float = 0.0
var _shake_time: float = 0.0
var _last_delta: float = 0.0
var _player_z_offset: float = 0.0

@onready var _road: PseudoRoad = %Road


func _physics_process(delta: float) -> void:
	if paused or phase == Constants.PHASE_WAITING:
		return
	step_tick(delta)
	refresh_view()


func _process(delta: float) -> void:
	if _road == null or _shake <= 0.0:
		return
	_shake_time += delta
	_road.position = (
		Vector2(
			sin(_shake_time * SHAKE_FREQUENCY) * _shake,
			cos(_shake_time * SHAKE_FREQUENCY * SHAKE_FREQUENCY_RATIO) * _shake
		)
		. round()
	)
	_shake = move_toward(_shake, 0.0, SHAKE_DECAY * delta)
	if _shake <= 0.0:
		_road.position = Vector2.ZERO


func start(race_config: RaceConfig) -> void:
	config = race_config
	track_def = Catalog.track(race_config.track_id)
	track_model = TrackModel.new(track_def)
	_contacts.setup(track_model)
	_vfx.load_all()
	_player_z_offset = (
		Balance.value(&"camera_height") * Balance.value(&"camera_depth") * PLAYER_Z_OFFSET_RATIO
	)
	participants = []
	_by_id = {}
	_confirmed = {}
	_states = []
	_local = null
	_results = []
	_standings = []
	_next_place = 1
	_end_countdown = -1.0
	race_time = 0.0
	_metrics = {"crushes": 0, "bumps": 0, "scenery_hits": 0}
	var spacing: float = Balance.value(&"car_length") * GRID_SPACING_CAR_LENGTHS
	for index: int in range(race_config.participants.size()):
		var participant: RaceParticipant = _build_participant(
			race_config.participants[index], index, spacing
		)
		participants.append(participant)
		_by_id[participant.id] = participant
		_states.append(participant.state)
		_standings.append(participant.id)
	if _road != null:
		_road.setup(track_model, track_def)
	_countdown_left = COUNTDOWN_SECONDS
	_last_countdown_value = 0
	# Grid order is the first ranking, so place_of() is 1-based during the countdown.
	_update_ranking()
	_set_phase(Constants.PHASE_COUNTDOWN)
	_tick_countdown(0.0)


## Advances the race by one physics tick. _physics_process calls it; tools and tests call it
## directly to run faster than real time.
func step_tick(delta: float) -> void:
	_last_delta = delta
	if phase == Constants.PHASE_COUNTDOWN:
		_tick_countdown(delta)
		return
	if phase != Constants.PHASE_RACING:
		return
	race_time += delta
	for participant: RaceParticipant in participants:
		_step_participant(participant, delta)
	_check_finishes()
	if authority:
		_resolve_contacts(delta)
	_emit_landings()
	_update_ranking()
	_vfx.update(delta)
	if _local != null:
		local_state_updated.emit(_local.id, _local.state.to_packed())
	_check_race_end(delta)


## Points the camera at the local car and hands every car to the road renderer.
func refresh_view() -> void:
	if _road == null or track_model == null or participants.is_empty():
		return
	var focus: RaceParticipant = _local if _local != null else participants[0]
	_road.camera_z = focus.state.z - _player_z_offset
	_road.camera_x = focus.state.x
	_road.camera_altitude = focus.state.altitude * CAMERA_ALTITUDE_FOLLOW
	_road.scroll_background(
		track_model.curve_at(focus.state.z),
		focus.state.speed / maxf(focus.stats.top_speed, 1.0),
		_last_delta
	)
	var entries: Array[RoadSprite] = []
	for participant: RaceParticipant in participants:
		var sprite: RoadSprite = RoadSprite.new()
		sprite.texture = participant.sprites.rear_texture(participant.state.steer_visual)
		sprite.z = participant.state.z
		sprite.x = participant.state.x
		sprite.altitude = participant.state.altitude
		sprite.material = participant.material
		sprite.vfx = _vfx.sprites_for(participant.id, participant.state.is_nitro_active())
		entries.append(sprite)
	_road.set_cars(entries)
	_road.refresh()


func state_of(participant_id: int) -> CarState:
	var participant: RaceParticipant = _by_id.get(participant_id)
	return participant.state if participant != null else null


func stats_of(participant_id: int) -> CarStats:
	var participant: RaceParticipant = _by_id.get(participant_id)
	return participant.stats if participant != null else null


func place_of(participant_id: int) -> int:
	var participant: RaceParticipant = _by_id.get(participant_id)
	return participant.place if participant != null else 0


## Current lap number shown to the player, 1..laps.
func lap_of(participant_id: int) -> int:
	var participant: RaceParticipant = _by_id.get(participant_id)
	if participant == null or config == null:
		return 0
	return clampi(maxi(participant.state.lap, 0) + 1, 1, maxi(config.laps, 1))


func local_id() -> int:
	return _local.id if _local != null else Constants.INVALID_ID


func standings() -> Array[int]:
	return _standings.duplicate()


## Results sorted by place; empty until the race finishes.
func results() -> Array[Dictionary]:
	return _results.duplicate()


## Contact counts and off-road ticks per participant, for playtest tooling.
func metrics() -> Dictionary:
	var offroad: Dictionary = {}
	var worst: int = 0
	for participant: RaceParticipant in participants:
		offroad[participant.id] = participant.offroad_ticks
		worst = maxi(worst, participant.offroad_ticks)
	var result: Dictionary = _metrics.duplicate()
	result["offroad_ticks"] = offroad
	result["max_offroad_ticks"] = worst
	return result


func set_local_input_source(source: DriverInputSource) -> void:
	if _local == null:
		return
	_local.source = source
	if source is AiDriver:
		(source as AiDriver).bind(_local.state, _local.stats)


func pause(is_paused: bool) -> void:
	paused = is_paused


func set_remote_state(participant_id: int, packed: PackedFloat32Array) -> void:
	var participant: RaceParticipant = _by_id.get(participant_id)
	if participant == null:
		return
	var state: CarState = participant.state
	var was_airborne: bool = state.airborne
	var confirmed_time: float = state.finish_time
	state.from_packed(packed)
	if _confirmed.has(participant_id):
		state.finished = true
		state.finish_time = confirmed_time
	state.progress = track_model.progress_of(state.z, state.lap)
	participant.landed_this_tick = was_airborne and not state.airborne
	var offroad: bool = absf(state.x) > 1.0 and not state.airborne
	if offroad != state.offroad:
		state.offroad = offroad
		RaceBus.offroad_changed.emit(participant_id, offroad)


func apply_penalty(participant_id: int, kind: StringName, data: Dictionary = {}) -> void:
	var participant: RaceParticipant = _by_id.get(participant_id)
	if participant == null or not RacePenalties.apply(participant.state, kind, data):
		return
	match kind:
		RacePenalties.KIND_BUMP:
			RaceBus.car_bumped.emit(participant_id)
			_vfx.trigger(RaceVfx.BUMP_SPARKS, participant_id)
			_shake_for(participant, SHAKE_BUMP)
		RacePenalties.KIND_SCENERY:
			RaceBus.scenery_hit.emit(participant_id)
			_shake_for(participant, SHAKE_SCENERY)
		RacePenalties.KIND_CRUSH_VICTIM:
			_vfx.trigger(RaceVfx.CRUSH_SPARKS, participant_id)
			_shake_for(participant, SHAKE_CRUSH)
		RacePenalties.KIND_CRUSH_ATTACKER:
			_shake_for(participant, SHAKE_CRUSH)


func set_authority(is_host: bool) -> void:
	authority = is_host


func force_phase(new_phase: StringName, time: float) -> void:
	if new_phase == Constants.PHASE_FINISHED:
		return
	if new_phase == phase:
		if new_phase == Constants.PHASE_COUNTDOWN:
			_countdown_left = time
		return
	if new_phase == Constants.PHASE_COUNTDOWN:
		if phase != Constants.PHASE_WAITING:
			return
		_countdown_left = time
		_last_countdown_value = 0
	else:
		race_time = time
	_set_phase(new_phase)
	if new_phase == Constants.PHASE_RACING:
		RaceBus.race_started.emit()


func force_results(entries: Array[Dictionary]) -> void:
	if phase == Constants.PHASE_FINISHED:
		return
	_results = entries.duplicate(true)
	_set_phase(Constants.PHASE_FINISHED)
	RaceBus.race_finished.emit(_results)


func force_finish(participant_id: int, place: int, time: float) -> void:
	var participant: RaceParticipant = _by_id.get(participant_id)
	if participant == null:
		return
	_finish(participant, place, time)


func _build_participant(
	entry: RaceConfig.Participant, index: int, spacing: float
) -> RaceParticipant:
	var participant: RaceParticipant = RaceParticipant.new()
	participant.id = entry.id
	participant.definition = entry
	participant.car = Catalog.car(entry.car_id)
	participant.sprites = CarSprites.new(participant.car)
	participant.material = participant.sprites.material_for(entry.paint)
	participant.stats = Catalog.stats_for(entry.car_id, entry.tiers)
	var state: CarState = participant.state
	state.integrity = entry.integrity
	state.lap = START_LAP
	state.z = track_model.length - spacing * float(index + 1)
	state.x = -GRID_LANE if index % 2 == 0 else GRID_LANE
	state.progress = track_model.progress_of(state.z, state.lap)
	match entry.kind:
		RaceConfig.KIND_LOCAL:
			participant.source = LocalDriverInputSource.new()
			_local = participant
		RaceConfig.KIND_AI:
			var driver: AiDriver = AiDriver.new()
			driver.setup(track_model, entry.skill, config.seed * AI_SEED_STRIDE + index, entry.id)
			driver.bind(state, participant.stats)
			participant.source = driver
	return participant


func _set_phase(new_phase: StringName) -> void:
	phase = new_phase
	RaceBus.race_phase_changed.emit(new_phase)


func _tick_countdown(delta: float) -> void:
	_countdown_left -= delta
	if _countdown_left <= 0.0:
		_set_phase(Constants.PHASE_RACING)
		RaceBus.race_started.emit()
		return
	var value: int = ceili(_countdown_left)
	if value != _last_countdown_value:
		_last_countdown_value = value
		RaceBus.countdown_tick.emit(value)


func _step_participant(participant: RaceParticipant, delta: float) -> void:
	if participant.source == null:
		return
	if participant.source is AiDriver:
		(participant.source as AiDriver).set_others(_states)
	var input: DriverInput = participant.source.sample(delta)
	if participant.is_remote():
		return
	var state: CarState = participant.state
	var events: int = CarSim.step(state, input, participant.stats, track_model, delta)
	participant.landed_this_tick = events & CarSim.EVENT_LANDED != 0
	if events & CarSim.EVENT_NITRO != 0:
		RaceBus.nitro_activated.emit(participant.id)
	if events & CarSim.EVENT_JUMP != 0:
		RaceBus.jump_started.emit(participant.id)
		_vfx.trigger(RaceVfx.THRUSTER_BURST, participant.id)
	if events & CarSim.EVENT_LAP != 0 and state.lap >= 1:
		RaceBus.lap_completed.emit(participant.id, state.lap)
	if events & CarSim.EVENT_OFFROAD_ENTER != 0:
		RaceBus.offroad_changed.emit(participant.id, true)
	if events & CarSim.EVENT_OFFROAD_EXIT != 0:
		RaceBus.offroad_changed.emit(participant.id, false)
	if state.offroad:
		participant.offroad_ticks += 1


func _resolve_contacts(delta: float) -> void:
	for contact: RaceContacts.Contact in _contacts.detect(participants, delta):
		var first: RaceParticipant = _by_id[contact.a]
		var second: RaceParticipant = _by_id[contact.b]
		match contact.kind:
			RaceContacts.KIND_CRUSH:
				CarSim.resolve_crush(first.state, second.state)
				first.hard_landing = true
				_metrics["crushes"] = int(_metrics["crushes"]) + 1
				RaceBus.car_crushed.emit(first.id, second.id)
				penalty_decided.emit(second.id, RacePenalties.KIND_CRUSH_VICTIM, {})
				penalty_decided.emit(first.id, RacePenalties.KIND_CRUSH_ATTACKER, {})
				_vfx.trigger(RaceVfx.CRUSH_SPARKS, second.id)
				_shake_for(first, SHAKE_CRUSH)
				_shake_for(second, SHAKE_CRUSH)
			RaceContacts.KIND_BUMP:
				var before: Dictionary = {first.id: first.state.x, second.id: second.state.x}
				CarSim.resolve_bump(first.state, second.state)
				_metrics["bumps"] = int(_metrics["bumps"]) + 1
				for participant: RaceParticipant in [first, second]:
					RaceBus.car_bumped.emit(participant.id)
					penalty_decided.emit(
						participant.id,
						RacePenalties.KIND_BUMP,
						{
							"push": participant.state.x - float(before[participant.id]),
							"speed_ratio": Balance.value(&"bump_speed_ratio")
						}
					)
					_vfx.trigger(RaceVfx.BUMP_SPARKS, participant.id)
					_shake_for(participant, SHAKE_BUMP)
			RaceContacts.KIND_SCENERY:
				CarSim.resolve_scenery_hit(first.state)
				_metrics["scenery_hits"] = int(_metrics["scenery_hits"]) + 1
				RaceBus.scenery_hit.emit(first.id)
				penalty_decided.emit(first.id, RacePenalties.KIND_SCENERY, {})
				_shake_for(first, SHAKE_SCENERY)


func _emit_landings() -> void:
	for participant: RaceParticipant in participants:
		if not participant.landed_this_tick:
			continue
		RaceBus.car_landed.emit(participant.id, participant.hard_landing)
		_vfx.trigger(RaceVfx.LANDING_DUST, participant.id)
		participant.landed_this_tick = false
		participant.hard_landing = false


func _update_ranking() -> void:
	var order: Array[RaceParticipant] = participants.duplicate()
	order.sort_custom(_ranks_before)
	_standings = []
	var next_place: int = 1
	for participant: RaceParticipant in order:
		if not participant.state.finished:
			participant.place = next_place
		next_place = participant.place + 1
		_standings.append(participant.id)


static func _ranks_before(a: RaceParticipant, b: RaceParticipant) -> bool:
	if a.state.finished != b.state.finished:
		return a.state.finished
	if a.state.finished:
		return a.place < b.place
	return a.state.progress > b.state.progress


func _check_finishes() -> void:
	var crossed: Array[RaceParticipant] = []
	for participant: RaceParticipant in participants:
		if _confirmed.has(participant.id) or participant.state.lap < config.laps:
			continue
		crossed.append(participant)
	crossed.sort_custom(
		func(a: RaceParticipant, b: RaceParticipant) -> bool:
			var ta: float = _crossing_time(a)
			var tb: float = _crossing_time(b)
			return a.id < b.id if ta == tb else ta < tb
	)
	for participant: RaceParticipant in crossed:
		if authority:
			_finish(participant, _next_place, _crossing_time(participant))
		else:
			participant.state.finished = true


func _crossing_time(participant: RaceParticipant) -> float:
	var state: CarState = participant.state
	var past: float = state.progress - float(config.laps) * track_model.length
	var overshoot: float = past / state.speed if state.speed > 0.0 else 0.0
	return race_time - clampf(overshoot, 0.0, _last_delta)


func _finish(participant: RaceParticipant, place: int, time: float) -> void:
	var state: CarState = participant.state
	if _confirmed.has(participant.id):
		return
	state.finished = true
	_confirmed[participant.id] = true
	state.finish_time = time
	participant.place = place
	_next_place = maxi(_next_place, place + 1)
	RaceBus.car_finished.emit(participant.id, place, time)
	if participant == _local:
		_end_countdown = RACE_END_GRACE


func _check_race_end(delta: float) -> void:
	if not authority:
		return
	if _end_countdown >= 0.0:
		_end_countdown -= delta
		if _end_countdown <= 0.0:
			_end_race()
			return
	for participant: RaceParticipant in participants:
		if not participant.state.finished:
			return
	_end_race()


func _end_race() -> void:
	_update_ranking()
	_results = []
	for participant_id: int in _standings:
		var participant: RaceParticipant = _by_id[participant_id]
		var state: CarState = participant.state
		var prizes: Array[int] = track_def.prizes
		var place: int = participant.place
		(
			_results
			. append(
				{
					"id": participant.id,
					"name": participant.definition.display_name,
					"car_id": participant.definition.car_id,
					"place": place,
					"time": state.finish_time if state.finished else race_time,
					"earnings": prizes[place - 1] if place >= 1 and place <= prizes.size() else 0,
					"finished": state.finished,
				}
			)
		)
	_set_phase(Constants.PHASE_FINISHED)
	RaceBus.race_finished.emit(_results)


func _shake_for(participant: RaceParticipant, amount: float) -> void:
	if participant == _local:
		_shake = maxf(_shake, amount)
