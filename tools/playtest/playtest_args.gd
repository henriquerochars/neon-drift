class_name PlaytestArgs
extends RefCounted
## Shared helpers for the playtest tools: --key=value parsing and all-AI race configs.


## Parses ["--track=coast", "--flag"] into {"track": "coast", "flag": true}.
static func parse(args: PackedStringArray) -> Dictionary:
	var result: Dictionary = {}
	for arg: String in args:
		if not arg.begins_with("--"):
			continue
		var body: String = arg.substr(2)
		var split: int = body.find("=")
		if split < 0:
			result[body] = true
		else:
			result[body.substr(0, split)] = body.substr(split + 1)
	return result


## A race config with `cars` AI participants cycling the catalog cars, skills spread linearly.
static func ai_config(
	track: TrackDef, race_seed: int, cars: int, skill_min: float, skill_max: float
) -> RaceConfig:
	var config: RaceConfig = RaceConfig.new()
	config.track_id = track.id
	config.laps = track.laps
	config.seed = race_seed
	var catalog_cars: Array[CarDef] = Catalog.cars()
	for index: int in range(cars):
		var car: CarDef = catalog_cars[index % catalog_cars.size()]
		var participant: RaceConfig.Participant = config.add_participant(
			index, "AI %d" % index, car.id, RaceConfig.KIND_AI, index
		)
		participant.skill = lerpf(skill_min, skill_max, float(index) / float(maxi(cars - 1, 1)))
	return config
