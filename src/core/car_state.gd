class_name CarState
extends RefCounted
## Complete simulation state of one car. Stepped by CarSim, replicated by RaceSync.

const FIELD_COUNT: int = 12

## Distance along the track in world units (wraps at TrackModel.length).
var z: float = 0.0
## Lateral position: -1..1 is the road, beyond is off-road, clamped to Balance road_limit.
var x: float = 0.0
var speed: float = 0.0
var altitude: float = 0.0
var vertical_speed: float = 0.0
var airborne: bool = false
## Nitro gauge 0..1.
var nitro: float = 1.0
var nitro_time_left: float = 0.0
## Thruster charge 0..1; a jump needs 1.
var thrusters: float = 1.0
var integrity: float = 100.0
var lap: int = 0
var finished: bool = false
var finish_time: float = 0.0
## Seconds since the race started (set by the race manager).
var race_time: float = 0.0
## Smoothed steer for sprite direction, -1..1.
var steer_visual: float = 0.0
## Remaining stun from a crush or bump; throttle is ignored while > 0.
var stun_time: float = 0.0
var offroad: bool = false
## Total distance driven, never wraps: z + lap * length. Used for ranking.
var progress: float = 0.0


func is_nitro_active() -> bool:
	return nitro_time_left > 0.0


func to_packed() -> PackedFloat32Array:
	var packed: PackedFloat32Array = PackedFloat32Array()
	packed.resize(FIELD_COUNT)
	packed[0] = z
	packed[1] = x
	packed[2] = speed
	packed[3] = altitude
	packed[4] = vertical_speed
	packed[5] = 1.0 if airborne else 0.0
	packed[6] = nitro
	packed[7] = nitro_time_left
	packed[8] = thrusters
	packed[9] = integrity
	packed[10] = float(lap)
	packed[11] = steer_visual
	return packed


func from_packed(packed: PackedFloat32Array) -> void:
	if packed.size() < FIELD_COUNT:
		return
	z = packed[0]
	x = packed[1]
	speed = packed[2]
	altitude = packed[3]
	vertical_speed = packed[4]
	airborne = packed[5] > 0.5
	nitro = packed[6]
	nitro_time_left = packed[7]
	thrusters = packed[8]
	integrity = packed[9]
	lap = int(packed[10])
	steer_visual = packed[11]


func duplicate_state() -> CarState:
	var copy: CarState = CarState.new()
	copy.from_packed(to_packed())
	copy.finished = finished
	copy.finish_time = finish_time
	copy.race_time = race_time
	copy.stun_time = stun_time
	copy.offroad = offroad
	copy.progress = progress
	return copy
