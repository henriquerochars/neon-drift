class_name RacePenalties
extends RefCounted
## Single-car halves of the CarSim contact rules, for penalties decided by the race authority
## and applied on the peer that owns the car (RaceScene.apply_penalty).

const KIND_CRUSH_VICTIM: StringName = &"crush_victim"
const KIND_CRUSH_ATTACKER: StringName = &"crush_attacker"
const KIND_BUMP: StringName = &"bump"
const KIND_SCENERY: StringName = &"scenery"
const KINDS: Array[StringName] = [KIND_CRUSH_VICTIM, KIND_CRUSH_ATTACKER, KIND_BUMP, KIND_SCENERY]


## Applies one penalty kind to a state; returns false for an unknown kind.
static func apply(state: CarState, kind: StringName, data: Dictionary = {}) -> bool:
	match kind:
		KIND_CRUSH_VICTIM:
			state.speed *= Balance.value(&"crush_victim_speed_ratio")
			state.integrity = maxf(0.0, state.integrity - Balance.value(&"crush_victim_damage"))
			state.stun_time = maxf(state.stun_time, Balance.value(&"crush_stun_time"))
		KIND_CRUSH_ATTACKER:
			state.speed *= Balance.value(&"crush_attacker_speed_ratio")
			state.integrity = maxf(0.0, state.integrity - Balance.value(&"crush_attacker_damage"))
			state.stun_time = maxf(state.stun_time, Balance.value(&"landing_wobble_time"))
		KIND_BUMP:
			state.x += float(data.get("push", 0.0))
			state.speed *= float(data.get("speed_ratio", Balance.value(&"bump_speed_ratio")))
			state.stun_time = maxf(state.stun_time, Balance.value(&"bump_stun_time"))
		KIND_SCENERY:
			CarSim.resolve_scenery_hit(state)
		_:
			return false
	return true
