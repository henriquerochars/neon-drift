extends Node
## Autoload: the player's garage. Money, selected car, paint, installed parts and integrity
## per car. Persisted as JSON in user://profile.json.

signal changed

const PATH: String = "user://profile.json"
const STARTING_MONEY: int = 1500
const DEFAULT_CAR: StringName = &"vortex"
const FULL_INTEGRITY: float = 100.0
const VERSION: int = 1

var money: int = STARTING_MONEY
var selected_car: StringName = DEFAULT_CAR
var races: int = 0
var wins: int = 0
## car id -> paint index
var paints: Dictionary = {}
## car id -> { slot: tier }
var parts: Dictionary = {}
## car id -> integrity percentage 0..100
var integrity: Dictionary = {}


func _ready() -> void:
	load_profile()


func load_profile(path: String = PATH) -> bool:
	if not FileAccess.file_exists(path):
		return false
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return false
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		return false
	var data: Dictionary = parsed
	money = int(data.get("money", STARTING_MONEY))
	selected_car = StringName(str(data.get("selected_car", DEFAULT_CAR)))
	races = int(data.get("races", 0))
	wins = int(data.get("wins", 0))
	paints = _int_dictionary(data.get("paints", {}))
	integrity = _float_dictionary(data.get("integrity", {}))
	parts = {}
	var raw_parts: Variant = data.get("parts", {})
	if raw_parts is Dictionary:
		for car: Variant in (raw_parts as Dictionary).keys():
			parts[StringName(str(car))] = _int_dictionary((raw_parts as Dictionary)[car])
	changed.emit()
	return true


func save_profile(path: String = PATH) -> Error:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(to_dictionary(), "\t"))
	return OK


func to_dictionary() -> Dictionary:
	var serial_parts: Dictionary = {}
	for car: Variant in parts.keys():
		var slots: Dictionary = {}
		for slot: Variant in (parts[car] as Dictionary).keys():
			slots[str(slot)] = (parts[car] as Dictionary)[slot]
		serial_parts[str(car)] = slots
	var serial_paints: Dictionary = {}
	for car: Variant in paints.keys():
		serial_paints[str(car)] = paints[car]
	var serial_integrity: Dictionary = {}
	for car: Variant in integrity.keys():
		serial_integrity[str(car)] = integrity[car]
	return {
		"version": VERSION,
		"money": money,
		"selected_car": str(selected_car),
		"races": races,
		"wins": wins,
		"paints": serial_paints,
		"parts": serial_parts,
		"integrity": serial_integrity,
	}


func reset() -> void:
	money = STARTING_MONEY
	selected_car = DEFAULT_CAR
	races = 0
	wins = 0
	paints = {}
	parts = {}
	integrity = {}
	changed.emit()


func paint_of(car_id: StringName) -> int:
	return int(paints.get(car_id, 0))


func set_paint(car_id: StringName, paint: int) -> void:
	paints[car_id] = posmod(paint, Constants.PAINT_COUNT)
	changed.emit()


func tier_of(car_id: StringName, slot: StringName) -> int:
	var slots: Dictionary = parts.get(car_id, {})
	return int(slots.get(slot, 0))


func integrity_of(car_id: StringName) -> float:
	return float(integrity.get(car_id, FULL_INTEGRITY))


func set_integrity(car_id: StringName, value: float) -> void:
	integrity[car_id] = clampf(value, 0.0, FULL_INTEGRITY)
	changed.emit()


func add_money(amount: int) -> void:
	money = maxi(0, money + amount)
	changed.emit()


## Installs a part when affordable and strictly better than the installed tier.
func buy_part(car_id: StringName, slot: StringName, tier: int, price: int) -> bool:
	if price > money or tier <= tier_of(car_id, slot):
		return false
	money -= price
	var slots: Dictionary = parts.get(car_id, {})
	slots[slot] = tier
	parts[car_id] = slots
	changed.emit()
	return true


func repair(car_id: StringName, price: int) -> bool:
	if price > money or integrity_of(car_id) >= FULL_INTEGRITY:
		return false
	money -= price
	integrity[car_id] = FULL_INTEGRITY
	changed.emit()
	return true


func record_result(place: int, earnings: int) -> void:
	races += 1
	if place == 1:
		wins += 1
	add_money(earnings)


func _int_dictionary(raw: Variant) -> Dictionary:
	var result: Dictionary = {}
	if raw is Dictionary:
		for key: Variant in (raw as Dictionary).keys():
			result[StringName(str(key))] = int((raw as Dictionary)[key])
	return result


func _float_dictionary(raw: Variant) -> Dictionary:
	var result: Dictionary = {}
	if raw is Dictionary:
		for key: Variant in (raw as Dictionary).keys():
			result[StringName(str(key))] = float((raw as Dictionary)[key])
	return result
