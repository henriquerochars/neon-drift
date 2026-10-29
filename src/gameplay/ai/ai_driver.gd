class_name AiDriver
extends DriverInputSource
## Deterministic rival driver. Steers toward a lane that moves to the inside of upcoming
## curves, counter-steers the centrifugal drift CarSim applies, keeps the car on the road,
## brakes when the next curves exceed what the car's handling can hold, fires nitro only
## when the whole burst fits the road ahead, jumps slower cars in its lane with full
## thrusters and otherwise changes lane around them. Same seed, same inputs.

## Segments averaged to pick the inside lane.
const LOOK_AHEAD_STEER: int = 10
## Segments scanned for the braking speed limit.
const LOOK_AHEAD_BRAKE: int = 30
## Fraction of the nitro burst distance a skill-0 driver bothers to check.
const NITRO_LOOK_AHEAD_MIN: float = 0.6
const INSIDE_LANE: float = 0.45
## Curve magnitude at which the driver hugs the inside completely.
const CURVE_FULL_INSIDE: float = 3.0
const MAX_TARGET: float = 0.75
const STEER_GAIN: float = 3.0
## Share of full steer reserved for holding the curve, by skill (cautious .. aggressive).
const GRIP_MARGIN_MIN: float = 0.7
const GRIP_MARGIN_MAX: float = 0.95
const BRAKE_GAIN: float = 4.0
const MIN_BRAKE: float = 0.2
const FULL_GAUGE: float = 0.999
const JUMP_RANGE_CAR_LENGTHS: float = 3.0
const AVOID_RANGE_CAR_LENGTHS: float = 4.0
const AVOID_GAP: float = 0.7
const LANE_CHOICES: Array[float] = [-0.5, -0.25, 0.0, 0.25, 0.5]
const MIN_SPEED_RATIO: float = 0.05
const CURVE_EPSILON: float = 0.001

var track: TrackModel
var skill: float = 0.5
var participant_id: int = 0
var state: CarState
var stats: CarStats

var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _others: Array[CarState] = []
var _preferred_lane: float = 0.0
var _centrifugal: float = 0.0
var _car_length: float = 1.0
var _lane_width: float = 0.5
var _nitro_speed_bonus: float = 0.0


func setup(model: TrackModel, skill_level: float, rng_seed: int, id: int) -> void:
	track = model
	skill = clampf(skill_level, 0.0, 1.0)
	participant_id = id
	_rng.seed = rng_seed
	_preferred_lane = LANE_CHOICES[_rng.randi_range(0, LANE_CHOICES.size() - 1)]
	_centrifugal = Balance.value(&"centrifugal")
	_car_length = Balance.value(&"car_length")
	_lane_width = Balance.value(&"car_half_width") * 2.0
	_nitro_speed_bonus = Balance.value(&"nitro_speed_bonus")


## The car this driver controls; the state is read every tick, never copied.
func bind(car_state: CarState, car_stats: CarStats) -> void:
	state = car_state
	stats = car_stats


## All car states in the race (the driver's own is skipped by identity).
func set_others(states: Array[CarState]) -> void:
	_others = states


func sample(_delta: float) -> DriverInput:
	input.reset()
	if state == null or stats == null or track == null or track.segment_count == 0:
		return input
	var segment: int = track.segment_index(state.z)
	var speed_ratio: float = state.speed / maxf(stats.top_speed, 1.0)
	var curve_now: float = track.curve_of_segment(segment)
	var curve_ahead: float = _mean_curve(segment, LOOK_AHEAD_STEER)
	var target: float = _preferred_lane
	if absf(curve_ahead) > CURVE_EPSILON:
		var inside: float = minf(1.0, absf(curve_ahead) / CURVE_FULL_INSIDE)
		target -= signf(curve_ahead) * INSIDE_LANE * inside
	target = _avoid_or_jump(target)
	target = clampf(target, -MAX_TARGET, MAX_TARGET)
	var counter: float = 0.0
	if speed_ratio > MIN_SPEED_RATIO:
		counter = curve_now * _centrifugal * speed_ratio / maxf(stats.handling, 0.01)
	input.steer = clampf((target - state.x) * STEER_GAIN + counter, -1.0, 1.0)
	var margin: float = lerpf(GRIP_MARGIN_MIN, GRIP_MARGIN_MAX, skill)
	var max_ratio: float = _max_speed_ratio(_max_abs_curve(segment, LOOK_AHEAD_BRAKE), margin)
	input.throttle = 1.0
	if speed_ratio > max_ratio:
		input.throttle = 0.0
		input.brake = clampf((speed_ratio - max_ratio) * BRAKE_GAIN, MIN_BRAKE, 1.0)
	input.nitro = _wants_nitro(segment, margin)
	return input


func _avoid_or_jump(target: float) -> float:
	var ahead: CarState = null
	var ahead_distance: float = _car_length * AVOID_RANGE_CAR_LENGTHS
	for other: CarState in _others:
		if other == state or other.finished:
			continue
		var dz: float = fposmod(other.z - state.z, track.length)
		if dz > 0.0 and dz < ahead_distance:
			ahead = other
			ahead_distance = dz
	if ahead == null or absf(ahead.x - state.x) >= _lane_width:
		return target
	var slower: bool = ahead.speed < state.speed
	var in_jump_range: bool = ahead_distance <= _car_length * JUMP_RANGE_CAR_LENGTHS
	if slower and in_jump_range and not state.airborne and state.thrusters >= FULL_GAUGE:
		input.jump = true
		return target
	var side: float = -1.0 if ahead.x >= 0.0 else 1.0
	if absf(ahead.x - state.x) > CURVE_EPSILON:
		side = -1.0 if ahead.x > state.x else 1.0
	return ahead.x + side * AVOID_GAP


func _max_speed_ratio(curve: float, margin: float) -> float:
	if curve < CURVE_EPSILON:
		return 1.0
	return minf(1.0, stats.handling * margin / (curve * _centrifugal))


func _wants_nitro(segment: int, margin: float) -> bool:
	if state.nitro < FULL_GAUGE or state.airborne or state.is_nitro_active():
		return false
	var burst_speed: float = stats.top_speed * (1.0 + _nitro_speed_bonus)
	var distance: float = burst_speed * stats.nitro_duration * state.nitro
	var checked: float = lerpf(NITRO_LOOK_AHEAD_MIN, 1.0, skill)
	var segments: int = int(distance * checked / track.segment_length)
	var allowed: float = stats.handling * margin / (_centrifugal * (1.0 + _nitro_speed_bonus))
	return _max_abs_curve(segment, segments) <= allowed


func _mean_curve(segment: int, count: int) -> float:
	var total: float = 0.0
	for offset: int in range(count):
		total += track.curve_of_segment(segment + offset)
	return total / float(maxi(count, 1))


func _max_abs_curve(segment: int, count: int) -> float:
	var worst: float = 0.0
	for offset: int in range(count):
		worst = maxf(worst, absf(track.curve_of_segment(segment + offset)))
	return worst
