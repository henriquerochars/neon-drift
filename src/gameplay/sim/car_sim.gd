class_name CarSim
extends RefCounted
## Pure, deterministic car simulation. step() advances one CarState by delta and returns a
## bit mask of events for the race manager to broadcast. Contact rules between cars are the
## static resolve_* helpers. No nodes, no signals, no randomness.

const EVENT_NONE: int = 0
const EVENT_NITRO: int = 1
const EVENT_JUMP: int = 2
const EVENT_LANDED: int = 4
const EVENT_LAP: int = 8
const EVENT_OFFROAD_ENTER: int = 16
const EVENT_OFFROAD_EXIT: int = 32

const MIN_SPEED_FOR_STEER: float = 0.05
const FULL: float = 1.0


static func step(
	state: CarState, input: DriverInput, stats: CarStats, track: TrackModel, delta: float
) -> int:
	var events: int = EVENT_NONE
	if delta <= 0.0 or state.finished:
		_coast(state, track, delta)
		return events
	var top: float = effective_top_speed(state, stats)
	var stunned: bool = state.stun_time > 0.0
	state.stun_time = maxf(0.0, state.stun_time - delta)
	# Nitro.
	if input.nitro and not state.airborne and not stunned and not state.is_nitro_active():
		if state.nitro >= Balance.value(&"nitro_min_gauge"):
			state.nitro_time_left = stats.nitro_duration * state.nitro
			state.nitro = 0.0
			events |= EVENT_NITRO
	if state.is_nitro_active():
		state.nitro_time_left = maxf(0.0, state.nitro_time_left - delta)
	else:
		state.nitro = minf(FULL, state.nitro + stats.nitro_refill * delta)
	# Longitudinal.
	var throttle: float = 0.0 if stunned else clampf(input.throttle, 0.0, 1.0)
	var brake: float = clampf(input.brake, 0.0, 1.0)
	var accel: float = stats.acceleration
	if state.is_nitro_active():
		accel *= 1.0 + Balance.value(&"nitro_accel_bonus")
		throttle = maxf(throttle, FULL)
	if throttle > 0.0:
		state.speed += accel * throttle * delta
	elif brake > 0.0:
		state.speed -= Balance.value(&"brake_decel") * brake * delta
	else:
		state.speed -= Balance.value(&"coast_decel") * delta
	# Off-road.
	var offroad: bool = absf(state.x) > FULL and not state.airborne
	if offroad and state.speed > top * Balance.value(&"offroad_speed_ratio"):
		state.speed -= Balance.value(&"offroad_decel") * delta
	if offroad != state.offroad:
		events |= EVENT_OFFROAD_ENTER if offroad else EVENT_OFFROAD_EXIT
		state.offroad = offroad
	state.speed = clampf(state.speed, 0.0, top)
	# Jump and altitude.
	if input.jump and not state.airborne and not stunned and state.thrusters >= FULL:
		state.airborne = true
		state.vertical_speed = stats.jump_velocity
		state.thrusters = 0.0
		events |= EVENT_JUMP
	if state.airborne:
		state.vertical_speed -= Balance.value(&"gravity") * delta
		state.altitude += state.vertical_speed * delta
		if state.altitude <= 0.0:
			state.altitude = 0.0
			state.vertical_speed = 0.0
			state.airborne = false
			events |= EVENT_LANDED
	else:
		state.thrusters = minf(FULL, state.thrusters + stats.thruster_recharge * delta)
	# Lateral.
	var speed_ratio: float = state.speed / maxf(stats.top_speed, 1.0)
	var steer: float = clampf(input.steer, -1.0, 1.0)
	if speed_ratio > MIN_SPEED_FOR_STEER:
		var steer_power: float = stats.handling * speed_ratio
		if state.airborne:
			steer_power *= Balance.value(&"air_steer_ratio")
		state.x += steer * steer_power * delta
		var curve: float = track.curve_at(state.z) if track != null else 0.0
		state.x -= curve * Balance.value(&"centrifugal") * speed_ratio * speed_ratio * delta
	var limit: float = Balance.value(&"road_limit")
	state.x = clampf(state.x, -limit, limit)
	var visual_speed: float = Balance.value(&"steer_visual_speed")
	state.steer_visual = move_toward(state.steer_visual, steer, visual_speed * delta)
	# Forward.
	var before: float = state.z
	state.z += state.speed * delta
	if track != null and track.length > 0.0:
		if state.z >= track.length:
			state.z -= track.length
			state.lap += 1
			events |= EVENT_LAP
		elif state.z < 0.0:
			state.z += track.length
		state.progress = track.progress_of(state.z, state.lap)
	else:
		state.progress += state.z - before
	state.race_time += delta
	return events


## Top speed after nitro and damage.
static func effective_top_speed(state: CarState, stats: CarStats) -> float:
	var top: float = stats.top_speed
	if state.is_nitro_active():
		top *= 1.0 + Balance.value(&"nitro_speed_bonus")
	if state.integrity <= 0.0:
		top *= Balance.value(&"limp_speed_ratio")
	return top


## True when two cars overlap on the road (same lap not required: z wraps).
static func overlaps(a: CarState, b: CarState, track_length: float) -> bool:
	var dz: float = absf(a.z - b.z)
	if track_length > 0.0:
		dz = minf(dz, track_length - dz)
	if dz > Balance.value(&"car_length"):
		return false
	return absf(a.x - b.x) < Balance.value(&"car_half_width") * 2.0


## Side contact: both lose speed and are pushed apart. Returns true when applied.
static func resolve_bump(a: CarState, b: CarState) -> bool:
	if a.airborne or b.airborne:
		return false
	var push: float = Balance.value(&"bump_push")
	var ratio: float = Balance.value(&"bump_speed_ratio")
	var direction: float = 1.0 if a.x >= b.x else -1.0
	a.x += push * direction * 0.5
	b.x -= push * direction * 0.5
	a.speed *= ratio
	b.speed *= ratio
	var stun: float = Balance.value(&"bump_stun_time")
	a.stun_time = maxf(a.stun_time, stun)
	b.stun_time = maxf(b.stun_time, stun)
	return true


## A jumper landing on a victim: the victim is crushed, the jumper takes a hard landing.
static func resolve_crush(jumper: CarState, victim: CarState) -> void:
	victim.speed *= Balance.value(&"crush_victim_speed_ratio")
	victim.integrity = maxf(0.0, victim.integrity - Balance.value(&"crush_victim_damage"))
	victim.stun_time = maxf(victim.stun_time, Balance.value(&"crush_stun_time"))
	jumper.speed *= Balance.value(&"crush_attacker_speed_ratio")
	jumper.integrity = maxf(0.0, jumper.integrity - Balance.value(&"crush_attacker_damage"))
	jumper.stun_time = maxf(jumper.stun_time, Balance.value(&"landing_wobble_time"))


## Hitting a roadside object: strong slowdown and a push back toward the road.
static func resolve_scenery_hit(state: CarState) -> void:
	state.speed *= Balance.value(&"scenery_hit_speed_ratio")
	var push: float = Balance.value(&"scenery_push")
	state.x = move_toward(state.x, 0.0, push)
	state.stun_time = maxf(state.stun_time, Balance.value(&"bump_stun_time"))


## Drafting: a car close behind another on the same lane refills nitro faster.
static func is_drafting(follower: CarState, leader: CarState, track_length: float) -> bool:
	var dz: float = leader.z - follower.z
	if track_length > 0.0:
		dz = fposmod(dz, track_length)
	if dz <= 0.0 or dz > Balance.value(&"draft_distance"):
		return false
	return absf(leader.x - follower.x) < Balance.value(&"car_half_width") * 2.0


static func _coast(state: CarState, track: TrackModel, delta: float) -> void:
	if delta <= 0.0:
		return
	state.speed = maxf(0.0, state.speed - Balance.value(&"coast_decel") * delta)
	state.z += state.speed * delta
	if track != null and track.length > 0.0:
		state.z = fposmod(state.z, track.length)
	state.race_time += delta
