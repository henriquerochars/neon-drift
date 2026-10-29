extends GdUnitTestSuite
## Content acceptance: 5 cars with sprites, 18 parts over 6 slots, 3 tracks, balance keys.


func test_five_cars_with_eight_rotations_each() -> void:
	var cars: Array[CarDef] = Catalog.cars()
	assert_int(cars.size()).is_equal(5)
	var ids: Array[StringName] = []
	for car: CarDef in cars:
		assert_bool(ids.has(car.id)).is_false()
		ids.append(car.id)
		for direction: String in CarDef.DIRECTIONS:
			assert_bool(ResourceLoader.exists(car.sprite_path(direction))).is_true()
		for slot: StringName in Constants.SLOTS:
			assert_int(car.rank_of(slot)).is_between(1, 5)


func test_parts_cover_every_slot_with_three_tiers() -> void:
	for slot: StringName in Constants.SLOTS:
		var parts: Array[PartDef] = Catalog.parts_for_slot(slot)
		assert_int(parts.size()).is_equal(Constants.SLOT_TIERS)
		for index: int in range(parts.size()):
			assert_int(parts[index].tier).is_equal(index + 1)
			assert_int(parts[index].price).is_greater(0)


func test_three_tracks_with_background_and_scenery() -> void:
	var tracks: Array[TrackDef] = Catalog.tracks()
	assert_int(tracks.size()).is_equal(3)
	for track: TrackDef in tracks:
		assert_object(track.background).is_not_null()
		assert_int(track.scenery_sprites.size()).is_greater(0)
		assert_int(track.total_segments()).is_greater(100)
		assert_int(track.prizes.size()).is_equal(Constants.MAX_PLAYERS)


func test_parts_improve_stats() -> void:
	var base: CarStats = Catalog.stats_for(&"vortex", {})
	var tuned: CarStats = Catalog.stats_for(&"vortex", {&"engine": 3, &"tires": 1})
	assert_float(tuned.top_speed).is_greater(base.top_speed)
	assert_float(tuned.handling).is_greater(base.handling)
	assert_float(tuned.acceleration).is_equal(base.acceleration)


func test_balance_has_the_physics_keys() -> void:
	for key: StringName in [&"segment_length", &"gravity", &"nitro_speed_bonus", &"car_length"]:
		assert_bool(Balance.has_key(key)).is_true()
		assert_float(Balance.value(key)).is_greater(0.0)
