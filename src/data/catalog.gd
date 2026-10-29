class_name Catalog
extends RefCounted
## Static access to data/catalog.tres.

const PATH: String = "res://data/catalog.tres"

static var _catalog: CatalogDef


static func get_catalog() -> CatalogDef:
	if _catalog == null:
		_catalog = load(PATH) as CatalogDef
	return _catalog


static func cars() -> Array[CarDef]:
	return get_catalog().cars


static func parts() -> Array[PartDef]:
	return get_catalog().parts


static func tracks() -> Array[TrackDef]:
	return get_catalog().tracks


static func car(id: StringName) -> CarDef:
	for item: CarDef in cars():
		if item.id == id:
			return item
	return null


static func track(id: StringName) -> TrackDef:
	for item: TrackDef in tracks():
		if item.id == id:
			return item
	return null


static func part(id: StringName) -> PartDef:
	for item: PartDef in parts():
		if item.id == id:
			return item
	return null


static func parts_for_slot(slot: StringName) -> Array[PartDef]:
	var result: Array[PartDef] = []
	for item: PartDef in parts():
		if item.slot == slot:
			result.append(item)
	result.sort_custom(func(a: PartDef, b: PartDef) -> bool: return a.tier < b.tier)
	return result


## Stats for a car with the tiers stored in a profile-like dictionary (slot -> tier).
static func stats_for(car_id: StringName, tiers: Dictionary) -> CarStats:
	var definition: CarDef = car(car_id)
	if definition == null:
		return CarStats.new()
	return Balance.stats_for(definition, tiers, parts())
