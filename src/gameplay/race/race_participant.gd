class_name RaceParticipant
extends RefCounted
## One car in a RaceScene: its config entry, simulation state, stats, driver and sprites.

var id: int = 0
var definition: RaceConfig.Participant
var car: CarDef
var sprites: CarSprites
var state: CarState = CarState.new()
var stats: CarStats = CarStats.new()
var source: DriverInputSource
var material: ShaderMaterial
## 1-based; 0 until the race assigns one.
var place: int = 0
var offroad_ticks: int = 0
## Set by the physics step (or a remote update) on the tick the car touches the road.
var landed_this_tick: bool = false
var hard_landing: bool = false


func is_remote() -> bool:
	return definition != null and definition.kind == RaceConfig.KIND_REMOTE
