class_name Balance
extends RefCounted
## Loads data/balance/physics.csv (key,value) once and maps 1-5 stat ranks to physical values.
## Static access only; call Balance.reload() in tests that write a different CSV.

const CSV_PATH: String = "res://data/balance/physics.csv"

static var _values: Dictionary = {}
static var _loaded: bool = false


static func reload(path: String = CSV_PATH) -> bool:
	_values = {}
	_loaded = false
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("Balance: cannot open %s" % path)
		return false
	var header: PackedStringArray = file.get_csv_line()
	if header.size() < 2:
		push_error("Balance: %s needs a key,value header" % path)
		return false
	while not file.eof_reached():
		var row: PackedStringArray = file.get_csv_line()
		if row.size() < 2 or row[0].strip_edges().is_empty():
			continue
		_values[StringName(row[0].strip_edges())] = row[1].strip_edges().to_float()
	_loaded = true
	return true


static func value(key: StringName) -> float:
	if not _loaded:
		reload()
	if not _values.has(key):
		push_error("Balance: unknown key %s" % key)
		return 0.0
	return float(_values[key])


static func has_key(key: StringName) -> bool:
	if not _loaded:
		reload()
	return _values.has(key)


static func keys() -> Array[StringName]:
	if not _loaded:
		reload()
	var result: Array[StringName] = []
	for key: Variant in _values.keys():
		result.append(key as StringName)
	result.sort()
	return result


## Linear map of a rank (rank_min..rank_bonus_cap) onto [min_key, max_key] defined for ranks 1..5.
static func ranked(rank: float, min_key: StringName, max_key: StringName) -> float:
	var low: float = value(&"rank_min")
	var high: float = value(&"rank_max")
	var capped: float = clampf(rank, low, value(&"rank_bonus_cap"))
	var t: float = (capped - low) / (high - low)
	return lerpf(value(min_key), value(max_key), t)


## Physical stats for a car definition plus installed part tiers (slot -> tier).
static func stats_for(car: CarDef, tiers: Dictionary, parts: Array[PartDef]) -> CarStats:
	var bonus: Dictionary = {}
	for part: PartDef in parts:
		if int(tiers.get(part.slot, 0)) == part.tier:
			bonus[part.slot] = float(bonus.get(part.slot, 0.0)) + part.rank_bonus
	var stats: CarStats = CarStats.new()
	stats.top_speed = ranked(
		car.top_speed_rank + float(bonus.get(&"engine", 0.0)), &"top_speed_min", &"top_speed_max"
	)
	stats.acceleration = ranked(
		car.acceleration_rank + float(bonus.get(&"turbo", 0.0)),
		&"acceleration_min",
		&"acceleration_max"
	)
	stats.handling = ranked(
		car.handling_rank + float(bonus.get(&"tires", 0.0)), &"handling_min", &"handling_max"
	)
	var nitro_rank: float = car.nitro_rank + float(bonus.get(&"nitro_tank", 0.0))
	stats.nitro_duration = ranked(nitro_rank, &"nitro_duration_min", &"nitro_duration_max")
	stats.nitro_refill = ranked(nitro_rank, &"nitro_refill_min", &"nitro_refill_max")
	var thruster_rank: float = car.thruster_rank + float(bonus.get(&"thrusters", 0.0))
	stats.jump_velocity = ranked(thruster_rank, &"jump_velocity_min", &"jump_velocity_max")
	stats.thruster_recharge = ranked(
		thruster_rank, &"thruster_recharge_min", &"thruster_recharge_max"
	)
	stats.max_integrity = ranked(
		car.armour_rank + float(bonus.get(&"armour", 0.0)),
		&"max_integrity_min",
		&"max_integrity_max"
	)
	return stats
