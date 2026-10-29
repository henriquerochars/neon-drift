extends GdUnitTestSuite
## TrackModel acceptance: pieces expand to segments, curves ease, heights return home,
## scenery is deterministic per seed.


func test_coast_expands_to_its_pieces() -> void:
	var track: TrackDef = Catalog.track(&"coast")
	var model: TrackModel = TrackModel.new(track)
	assert_int(model.segment_count).is_equal(track.total_segments())
	assert_float(model.length).is_equal(
		float(model.segment_count) * Balance.value(&"segment_length")
	)


func test_curve_eases_in_and_out() -> void:
	var model: TrackModel = TrackModel.new(Catalog.track(&"coast"))
	var piece: TrackSegment = Catalog.track(&"coast").pieces[1]
	var start: int = Catalog.track(&"coast").pieces[0].total()
	assert_float(model.curve_of_segment(start)).is_equal(0.0)
	assert_float(model.curve_of_segment(start + piece.enter)).is_equal_approx(piece.curve, 0.001)
	assert_float(absf(model.curve_of_segment(start + piece.total() - 1))).is_less(absf(piece.curve))


func test_every_track_returns_to_its_start_height() -> void:
	for track: TrackDef in Catalog.tracks():
		var model: TrackModel = TrackModel.new(track)
		assert_float(model.height_at(model.length - 1.0)).is_equal_approx(0.0, 1.0)


func test_scenery_is_deterministic_for_the_seed() -> void:
	var a: TrackModel = TrackModel.new(Catalog.track(&"desert_night"))
	var b: TrackModel = TrackModel.new(Catalog.track(&"desert_night"))
	assert_int(a.scenery.size()).is_greater(10)
	assert_int(a.scenery.size()).is_equal(b.scenery.size())
	for index: int in range(a.scenery.size()):
		assert_int(a.scenery[index].segment).is_equal(b.scenery[index].segment)
		assert_float(a.scenery[index].offset).is_equal(b.scenery[index].offset)
		assert_bool(absf(a.scenery[index].offset) > 1.0).is_true()


func test_wrap_and_segment_index() -> void:
	var model: TrackModel = TrackModel.new(Catalog.track(&"coast"))
	assert_int(model.segment_index(-1.0)).is_equal(model.segment_count - 1)
	assert_int(model.segment_index(model.length + 1.0)).is_equal(0)
