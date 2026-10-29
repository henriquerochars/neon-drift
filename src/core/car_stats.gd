class_name CarStats
extends RefCounted
## Physical values of one car after tuning. Built by Balance.stats_for(ranks).

var top_speed: float = 0.0
var acceleration: float = 0.0
var handling: float = 0.0
var nitro_duration: float = 0.0
var nitro_refill: float = 0.0
var jump_velocity: float = 0.0
var thruster_recharge: float = 0.0
var max_integrity: float = 0.0


func to_dictionary() -> Dictionary:
	return {
		"top_speed": top_speed,
		"acceleration": acceleration,
		"handling": handling,
		"nitro_duration": nitro_duration,
		"nitro_refill": nitro_refill,
		"jump_velocity": jump_velocity,
		"thruster_recharge": thruster_recharge,
		"max_integrity": max_integrity,
	}
