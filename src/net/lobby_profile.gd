class_name LobbyProfile
extends Resource
## What a player brings into a lobby: display name, car, paint, tuning tiers and integrity.
## Resources never cross the wire, so profiles travel as Dictionaries (to/from_dictionary).

const KEY_NAME: String = "name"
const KEY_CAR_ID: String = "car_id"
const KEY_PAINT: String = "paint"
const KEY_TIERS: String = "tiers"
const KEY_INTEGRITY: String = "integrity"
const DEFAULT_CAR: StringName = &"vortex"
const MIN_INTEGRITY: float = 0.0
const MAX_INTEGRITY: float = 100.0
const MIN_TIER: int = 0

var name: String = GameSettings.DEFAULT_NAME
var car_id: StringName = DEFAULT_CAR
var paint: int = 0
## slot -> tier, as stored in PlayerProfile.parts[car_id].
var tiers: Dictionary = {}
## Starting integrity 0..100 (PlayerProfile.integrity_of for the local player).
var integrity: float = MAX_INTEGRITY


static func make(
	player_name: String,
	player_car: StringName,
	player_paint: int,
	player_tiers: Dictionary,
	player_integrity: float
) -> LobbyProfile:
	var profile: LobbyProfile = LobbyProfile.new()
	profile.name = GameSettings.sanitize_name(player_name)
	profile.car_id = player_car
	profile.paint = clampi(player_paint, 0, Constants.PAINT_COUNT - 1)
	profile.tiers = sanitize_tiers(player_tiers)
	profile.integrity = clampf(player_integrity, MIN_INTEGRITY, MAX_INTEGRITY)
	return profile


## Builds a profile from untrusted wire data; every field is clamped or sanitised.
static func from_dictionary(data: Dictionary) -> LobbyProfile:
	return make(
		str(data.get(KEY_NAME, "")),
		StringName(str(data.get(KEY_CAR_ID, DEFAULT_CAR))),
		int(data.get(KEY_PAINT, 0)),
		_dictionary_or_empty(data.get(KEY_TIERS, {})),
		float(data.get(KEY_INTEGRITY, MAX_INTEGRITY))
	)


## Keeps only known slots with integer tiers inside [0, Constants.SLOT_TIERS].
static func sanitize_tiers(raw: Dictionary) -> Dictionary:
	var clean: Dictionary = {}
	for slot: StringName in Constants.SLOTS:
		if raw.has(slot):
			clean[slot] = clampi(int(raw[slot]), MIN_TIER, Constants.SLOT_TIERS)
		elif raw.has(String(slot)):
			clean[slot] = clampi(int(raw[String(slot)]), MIN_TIER, Constants.SLOT_TIERS)
	return clean


static func _dictionary_or_empty(value: Variant) -> Dictionary:
	if value is Dictionary:
		return value
	return {}


func to_dictionary() -> Dictionary:
	return {
		KEY_NAME: name,
		KEY_CAR_ID: car_id,
		KEY_PAINT: paint,
		KEY_TIERS: tiers.duplicate(),
		KEY_INTEGRITY: integrity,
	}
