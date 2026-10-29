extends GdUnitTestSuite
## PseudoRoad projection: nearby points land inside the 320x180 viewport, farther points
## shrink, and a refresh with cars and scenery produces sprites without errors.


func _road() -> PseudoRoad:
	var road: PseudoRoad = auto_free(PseudoRoad.new())
	var track: TrackDef = Catalog.track(&"coast")
	road.setup(TrackModel.new(track), track)
	return road


func test_point_one_segment_ahead_projects_inside_the_viewport() -> void:
	var road: PseudoRoad = _road()
	road.camera_z = 0.0
	var segment: float = Balance.value(&"segment_length")
	var eye_level: Vector3 = road.project_point(0.0, Balance.value(&"camera_height"), segment)
	assert_float(eye_level.x).is_between(0.0, float(Constants.VIEWPORT_WIDTH))
	assert_float(eye_level.y).is_between(0.0, float(Constants.VIEWPORT_HEIGHT))
	assert_float(eye_level.z).is_greater(0.0)
	var road_point: Vector3 = road.project_point(0.0, 0.0, segment * 5.0)
	assert_float(road_point.x).is_equal_approx(float(Constants.VIEWPORT_WIDTH) / 2.0, 0.01)
	assert_float(road_point.y).is_between(
		float(Constants.VIEWPORT_HEIGHT) / 2.0, float(Constants.VIEWPORT_HEIGHT)
	)


func test_farther_points_have_smaller_scale_and_rise_to_the_horizon() -> void:
	var road: PseudoRoad = _road()
	var segment: float = Balance.value(&"segment_length")
	var near: Vector3 = road.project_point(0.0, 0.0, segment * 5.0)
	var mid: Vector3 = road.project_point(0.0, 0.0, segment * 20.0)
	var far: Vector3 = road.project_point(0.0, 0.0, segment * 100.0)
	assert_float(mid.z).is_less(near.z)
	assert_float(far.z).is_less(mid.z)
	assert_float(mid.y).is_less(near.y)
	assert_float(far.y).is_less(mid.y)
	assert_float(far.y).is_greater(float(Constants.VIEWPORT_HEIGHT) / 2.0 - 1.0)
	assert_float(road.project_point(0.0, 0.0, -segment).z).is_equal(0.0)


func test_refresh_places_cars_and_scenery_sprites() -> void:
	var road: PseudoRoad = _road()
	add_child(road)
	road.camera_z = 0.0
	var car: RoadSprite = RoadSprite.new()
	car.texture = CarSprites.new(Catalog.car(&"vortex")).rear_texture(0.0)
	car.z = Balance.value(&"segment_length") * 6.0
	var cars: Array[RoadSprite] = [car]
	road.set_cars(cars)
	road.refresh()
	var layer: SpriteLayer = road.get_child(0)
	var visible: int = 0
	for child: Node in layer.get_children():
		if (child as Sprite2D).visible:
			visible += 1
	assert_int(visible).is_greater(1)
	remove_child(road)


func test_car_sits_on_its_shadow_and_nitro_flames_hang_from_the_bumper() -> void:
	var road: PseudoRoad = _road()
	add_child(road)
	road.camera_z = 0.0
	var vfx: RaceVfx = RaceVfx.new()
	vfx.load_all()
	var car: RoadSprite = RoadSprite.new()
	car.texture = CarSprites.new(Catalog.car(&"vortex")).rear_texture(0.0)
	car.z = Balance.value(&"segment_length") * 6.0
	car.ground_pixels = CarSprites.GROUND_PIXELS
	car.vfx = vfx.sprites_for(0, true)
	assert_int(car.vfx.size()).is_equal(RaceVfx.EXHAUST_OFFSETS.size())
	var cars: Array[RoadSprite] = [car]
	road.set_cars(cars)
	road.refresh()
	var body: Sprite2D = null
	var flames: Array[Sprite2D] = []
	var layer: SpriteLayer = road.get_child(0)
	for child: Node in layer.get_children():
		var sprite: Sprite2D = child as Sprite2D
		if not sprite.visible:
			continue
		if sprite.texture == car.texture:
			body = sprite
		elif sprite.texture is AtlasTexture:
			flames.append(sprite)
	assert_object(body).is_not_null()
	assert_int(flames.size()).is_equal(2)
	var body_rect: Rect2 = Rect2(body.position, body.texture.get_size() * body.scale)
	for flame: Sprite2D in flames:
		var flame_rect: Rect2 = Rect2(flame.position, flame.texture.get_size() * flame.scale)
		# The flame starts on the rear bumper and trails below the car, toward the camera.
		assert_float(flame_rect.position.y).is_greater(
			body_rect.position.y + body_rect.size.y / 2.0
		)
		assert_float(flame_rect.end.y).is_greater(body_rect.end.y)
	remove_child(road)


func test_cars_between_the_camera_and_the_player_are_not_drawn() -> void:
	var road: PseudoRoad = _road()
	add_child(road)
	road.camera_z = 0.0
	road.near_cull = Balance.value(&"segment_length") * 4.0
	var near: RoadSprite = RoadSprite.new()
	near.texture = CarSprites.new(Catalog.car(&"bruiser")).rear_texture(0.0)
	near.z = Balance.value(&"segment_length")
	var cars: Array[RoadSprite] = [near]
	road.set_cars(cars)
	road.refresh()
	var layer: SpriteLayer = road.get_child(0)
	for child: Node in layer.get_children():
		var sprite: Sprite2D = child as Sprite2D
		assert_bool(sprite.visible and sprite.texture == near.texture).is_false()
	remove_child(road)
