class_name AiRoster
extends RefCounted
## Fills a RaceConfig with AI rivals: 80s racer nicknames, cars spread over the catalog,
## skills spread over SKILL_MIN..SKILL_MAX and varied paint, all drawn from the race seed.

const NICKNAMES: Array[String] = [
	"MAVERICK",
	"RAZOR",
	"NEON KID",
	"VIPER",
	"BLAZE",
	"TURBO JOE",
	"NIGHTHAWK",
	"CHROME",
	"ICEMAN",
	"JET",
	"ROXY",
	"VOLT",
	"SLICK",
	"PHOENIX",
	"DUKE",
	"STINGER",
]
const SKILL_MIN: float = 0.4
const SKILL_MAX: float = 0.9


## Appends `count` AI participants with ids starting at `first_id`.
static func fill(config: RaceConfig, count: int, seed: int, first_id: int) -> void:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = seed
	var names: Array[String] = NICKNAMES.duplicate()
	var cars: Array[CarDef] = Catalog.cars()
	var car_offset: int = rng.randi_range(0, maxi(cars.size() - 1, 0))
	for index: int in range(count):
		var name_index: int = rng.randi_range(0, names.size() - 1)
		var display_name: String = names[name_index]
		names.remove_at(name_index)
		var car: CarDef = cars[(car_offset + index) % cars.size()]
		var paint: int = rng.randi_range(0, Constants.PAINT_COUNT - 1)
		var participant: RaceConfig.Participant = config.add_participant(
			first_id + index, display_name, car.id, RaceConfig.KIND_AI, paint
		)
		var spread: float = float(index) / float(maxi(count - 1, 1))
		participant.skill = lerpf(SKILL_MIN, SKILL_MAX, spread)
