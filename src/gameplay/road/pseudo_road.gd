class_name PseudoRoad
extends Node2D
## Classic segment-projection road (ADR 0001). Every refresh() projects `draw_distance`
## segments ahead of the camera, draws grass/rumble/road/lane quads near to far with hill
## clipping, a parallax background strip, flat shadows, and hands cars, roadside scenery and
## VFX billboards to a SpriteLayer sorted by depth. All road geometry comes from Balance;
## the remaining numbers are rendering constants.


class Projected:
	extends RefCounted
	var index: int = 0
	var x1: float = 0.0
	var y1: float = 0.0
	var w1: float = 0.0
	var scale1: float = 0.0
	var x2: float = 0.0
	var y2: float = 0.0
	var w2: float = 0.0
	var scale2: float = 0.0
	var clip: float = 0.0
	var fog: float = 1.0
	var drawn: bool = false


class Shadow:
	extends RefCounted
	var center: Vector2 = Vector2.ZERO
	var width: float = 0.0


const HALF_WIDTH: float = float(Constants.VIEWPORT_WIDTH) / 2.0
const HALF_HEIGHT: float = float(Constants.VIEWPORT_HEIGHT) / 2.0
## Segments sharing one rumble/lane colour before it alternates.
const RUMBLE_SEGMENTS: int = 3
const LANES: int = 3
const RUMBLE_WIDTH_RATIO: float = 1.0 / 8.0
const LANE_WIDTH_RATIO: float = 1.0 / 32.0
const FOG_DENSITY: float = 5.0
const MIN_QUAD_HEIGHT: float = 0.5
const MIN_QUAD_WIDTH: float = 0.3
## World units covered by one sprite pixel: a 68 px car at the player's depth is ~64 px wide.
const SPRITE_WORLD_UNITS_PER_PIXEL: float = 5.9
const SHADOW_COLOR: Color = Color(0.0, 0.0, 0.0, 0.35)
const SHADOW_WIDTH_RATIO: float = 0.9
const SHADOW_HEIGHT_RATIO: float = 0.22
const SHADOW_POINTS: int = 10
const SHADOW_MIN_WIDTH: float = 2.0
## Background pixels per second per unit of (curve * speed ratio).
const BACKGROUND_PARALLAX: float = 12.0
const BACKGROUND_SLOPE_PIXELS: float = 60.0
const BACKGROUND_MAX_SHIFT: float = 14.0
## z_index slots per segment: scenery, car, vfx.
const DEPTH_SLOTS: int = 4
const DEPTH_CAR: int = 1
const DEPTH_VFX: int = 2

var camera_z: float = 0.0
## Lateral camera position in road half widths (follows the local car).
var camera_x: float = 0.0
var camera_altitude: float = 0.0
var background_offset: float = 0.0
var track_model: TrackModel
var track_def: TrackDef

## Cars closer to the camera than this (world units) are not drawn: they sit between the camera
## and the focused car and would cover the screen. The race sets it from the player offset.
var near_cull: float = 0.0
var _segment_length: float = 1.0
var _road_half_width: float = 1.0
var _camera_height: float = 1.0
var _camera_depth: float = 1.0
var _draw_distance: int = 0
var _segments: Array[Projected] = []
var _cars: Array[RoadSprite] = []
var _placements: Array[SpriteLayer.Placement] = []
var _shadows: Array[Shadow] = []
var _scenery_by_segment: Dictionary = {}
var _sprite_layer: SpriteLayer


func _init() -> void:
	_sprite_layer = SpriteLayer.new()
	add_child(_sprite_layer)
	_load_balance()


func setup(model: TrackModel, definition: TrackDef) -> void:
	track_model = model
	track_def = definition
	_load_balance()
	_scenery_by_segment = {}
	for item: TrackModel.SceneryItem in model.scenery:
		var list: Array = _scenery_by_segment.get(item.segment, [])
		list.append(item)
		_scenery_by_segment[item.segment] = list
	_segments = []
	for n: int in range(_draw_distance):
		_segments.append(Projected.new())


func set_cars(entries: Array[RoadSprite]) -> void:
	_cars = entries


## Advances the background parallax for one tick of driving.
func scroll_background(curve: float, speed_ratio: float, delta: float) -> void:
	background_offset += curve * speed_ratio * BACKGROUND_PARALLAX * delta


## Projects, places sprites and schedules a redraw. Call once per physics tick.
func refresh() -> void:
	if track_model == null or track_model.segment_count == 0:
		return
	_project_segments()
	_place_sprites()
	_sprite_layer.render(_placements)
	queue_redraw()


## Screen position (x, y) and projection scale (z) of a world point for the current camera.
## Points at or behind the camera plane return scale 0.
func project_point(world_x: float, world_y: float, world_z: float) -> Vector3:
	var dz: float = world_z - camera_z
	if dz <= 0.0:
		return Vector3(-1.0, -1.0, 0.0)
	var camera_y: float = _camera_y()
	var camera_world_x: float = camera_x * _road_half_width
	return _project(world_x - camera_world_x, world_y - camera_y, dz)


func _load_balance() -> void:
	_segment_length = Balance.value(&"segment_length")
	_road_half_width = Balance.value(&"road_half_width")
	_camera_height = Balance.value(&"camera_height")
	_camera_depth = Balance.value(&"camera_depth")
	_draw_distance = int(Balance.value(&"draw_distance"))


func _camera_y() -> float:
	var road: float = track_model.height_at(camera_z) if track_model != null else 0.0
	return _camera_height + road + camera_altitude


func _project(cx: float, cy: float, dz: float) -> Vector3:
	var scale: float = _camera_depth / dz
	return Vector3(
		HALF_WIDTH + scale * cx * HALF_WIDTH, HALF_HEIGHT - scale * cy * HALF_HEIGHT, scale
	)


func _project_segments() -> void:
	var cam_z: float = track_model.wrap_z(camera_z)
	var base: int = track_model.segment_index(cam_z)
	var base_percent: float = (cam_z - float(base) * _segment_length) / _segment_length
	var cam_y: float = _camera_y()
	var cam_x: float = camera_x * _road_half_width
	var dx: float = -(track_model.curve_of_segment(base) * base_percent)
	var x: float = 0.0
	var max_y: float = float(Constants.VIEWPORT_HEIGHT)
	var count: int = track_model.segment_count
	for n: int in range(_draw_distance):
		var seg: Projected = _segments[n]
		var index: int = (base + n) % count
		var dz1: float = float(base + n) * _segment_length - cam_z
		var dz2: float = dz1 + _segment_length
		var p1: Vector3 = _project(
			x - cam_x, track_model.height_of_segment(index) - cam_y, maxf(dz1, 0.001)
		)
		var p2: Vector3 = _project(
			x + dx - cam_x, track_model.height_of_segment(index + 1) - cam_y, dz2
		)
		x += dx
		dx += track_model.curve_of_segment(index)
		seg.index = index
		seg.x1 = p1.x
		seg.y1 = p1.y
		seg.scale1 = p1.z
		seg.w1 = p1.z * _road_half_width * HALF_WIDTH
		seg.x2 = p2.x
		seg.y2 = p2.y
		seg.scale2 = p2.z
		seg.w2 = p2.z * _road_half_width * HALF_WIDTH
		seg.clip = max_y
		var t: float = float(n) / float(_draw_distance)
		seg.fog = exp(-t * t * FOG_DENSITY)
		seg.drawn = false
		if dz1 <= _camera_depth or seg.y2 >= max_y or seg.y2 >= seg.y1:
			continue
		seg.drawn = true
		max_y = seg.y1


func _place_sprites() -> void:
	_placements = []
	_shadows = []
	var base: int = track_model.segment_index(camera_z)
	var count: int = track_model.segment_count
	for n: int in range(_draw_distance):
		var seg: Projected = _segments[n]
		var items: Array = _scenery_by_segment.get(seg.index, [])
		for item: TrackModel.SceneryItem in items:
			_place_scenery(seg, n, item)
	for car: RoadSprite in _cars:
		if car.texture == null:
			continue
		if fposmod(car.z - camera_z, track_model.length) < near_cull:
			continue
		var index: int = track_model.segment_index(car.z)
		var n: int = posmod(index - base, count)
		if n >= _draw_distance:
			continue
		var percent: float = fmod(track_model.wrap_z(car.z), _segment_length) / _segment_length
		_place_car(_segments[n], n, car, percent)


func _place_scenery(seg: Projected, n: int, item: TrackModel.SceneryItem) -> void:
	var sprites: Array[Texture2D] = track_def.scenery_sprites
	if item.sprite_index < 0 or item.sprite_index >= sprites.size():
		return
	var texture: Texture2D = sprites[item.sprite_index]
	var size: Vector2 = texture.get_size() * SPRITE_WORLD_UNITS_PER_PIXEL * seg.scale1 * HALF_WIDTH
	var sx: float = seg.x1 + seg.scale1 * item.offset * _road_half_width * HALF_WIDTH
	var dest_x: float = sx - size.x if item.offset < 0.0 else sx
	var placement: SpriteLayer.Placement = _clip_placement(
		Rect2(dest_x, seg.y1 - size.y, size.x, size.y), seg.clip
	)
	if placement == null:
		return
	placement.texture = texture
	placement.depth = (_draw_distance - n) * DEPTH_SLOTS
	_placements.append(placement)


func _place_car(seg: Projected, n: int, car: RoadSprite, percent: float) -> void:
	var scale: float = lerpf(seg.scale1, seg.scale2, percent)
	var sx: float = lerpf(seg.x1, seg.x2, percent) + scale * car.x * _road_half_width * HALF_WIDTH
	var sy: float = lerpf(seg.y1, seg.y2, percent)
	var lift: float = scale * car.altitude * HALF_HEIGHT
	var size: Vector2 = (
		car.texture.get_size()
		* SPRITE_WORLD_UNITS_PER_PIXEL
		* scale
		* HALF_WIDTH
		* car.scale_multiplier
	)
	if car.shadow and sy <= seg.clip:
		var shadow: Shadow = Shadow.new()
		shadow.center = Vector2(sx, sy)
		shadow.width = size.x * SHADOW_WIDTH_RATIO
		_shadows.append(shadow)
	var depth: int = (_draw_distance - n) * DEPTH_SLOTS + DEPTH_CAR
	var pixel: float = SPRITE_WORLD_UNITS_PER_PIXEL * scale * HALF_WIDTH * car.scale_multiplier
	var ground: float = car.ground_pixels * pixel
	var placement: SpriteLayer.Placement = _clip_placement(
		Rect2(sx - size.x / 2.0, sy - size.y - lift + ground, size.x, size.y), seg.clip
	)
	if placement != null:
		placement.texture = car.texture
		placement.material = car.material
		placement.flip_h = car.flip_h
		placement.modulate = car.modulate
		placement.depth = depth
		_placements.append(placement)
	for sub: RoadSprite in car.vfx:
		if sub.texture == null:
			continue
		var sub_size: Vector2 = (
			sub.texture.get_size()
			* SPRITE_WORLD_UNITS_PER_PIXEL
			* scale
			* HALF_WIDTH
			* sub.scale_multiplier
		)
		var sub_x: float = (
			sx + scale * sub.x * _road_half_width * HALF_WIDTH + sub.offset_pixels.x * pixel
		)
		var sub_y: float = (
			sy - lift - scale * sub.altitude * HALF_HEIGHT + sub.offset_pixels.y * pixel
		)
		var sub_placement: SpriteLayer.Placement = _clip_placement(
			Rect2(
				sub_x - sub_size.x / 2.0, sub_y - sub_size.y * sub.pivot_y, sub_size.x, sub_size.y
			),
			seg.clip
		)
		if sub_placement == null:
			continue
		sub_placement.texture = sub.texture
		sub_placement.flip_h = sub.flip_h
		sub_placement.modulate = sub.modulate
		sub_placement.depth = depth + DEPTH_VFX
		_placements.append(sub_placement)


## Cuts the bottom of a billboard hidden behind a nearer hill crest. Null when nothing remains.
func _clip_placement(rect: Rect2, clip_y: float) -> SpriteLayer.Placement:
	if rect.size.x < 1.0 or rect.size.y < 1.0:
		return null
	if rect.end.x < 0.0 or rect.position.x > float(Constants.VIEWPORT_WIDTH):
		return null
	var placement: SpriteLayer.Placement = SpriteLayer.Placement.new()
	placement.rect = rect
	if rect.end.y > clip_y:
		var visible: float = (clip_y - rect.position.y) / rect.size.y
		if visible <= 0.0:
			return null
		placement.visible_fraction = visible
		placement.rect.size.y = rect.size.y * visible
	return placement


func _draw() -> void:
	if track_def == null or track_model == null or track_model.segment_count == 0:
		return
	draw_rect(
		Rect2(0.0, 0.0, Constants.VIEWPORT_WIDTH, Constants.VIEWPORT_HEIGHT), track_def.sky_color
	)
	_draw_background()
	for seg: Projected in _segments:
		if seg.drawn:
			_draw_segment(seg)
	for shadow: Shadow in _shadows:
		_draw_shadow(shadow)


func _draw_background() -> void:
	var base: int = track_model.segment_index(camera_z)
	var slope: float = (
		(track_model.height_of_segment(base + 1) - track_model.height_of_segment(base))
		/ _segment_length
	)
	var shift: float = clampf(
		slope * BACKGROUND_SLOPE_PIXELS, -BACKGROUND_MAX_SHIFT, BACKGROUND_MAX_SHIFT
	)
	var bottom: float = round(HALF_HEIGHT + shift)
	draw_rect(
		Rect2(
			0.0, bottom - 1.0, Constants.VIEWPORT_WIDTH, Constants.VIEWPORT_HEIGHT - bottom + 1.0
		),
		track_def.fog_color
	)
	var texture: Texture2D = track_def.background
	if texture == null:
		return
	var size: Vector2 = texture.get_size()
	var top: float = bottom - size.y
	var ox: float = fposmod(background_offset, size.x)
	draw_texture_rect_region(
		texture, Rect2(0.0, top, size.x - ox, size.y), Rect2(ox, 0.0, size.x - ox, size.y)
	)
	if ox > 0.0:
		draw_texture_rect_region(
			texture, Rect2(size.x - ox, top, ox, size.y), Rect2(0.0, 0.0, ox, size.y)
		)


func _draw_segment(seg: Projected) -> void:
	var light: bool = (seg.index / RUMBLE_SEGMENTS) % 2 == 0
	var fog: float = 1.0 - seg.fog
	var grass: Color = (track_def.grass_light if light else track_def.grass_dark).lerp(
		track_def.fog_color, fog
	)
	var road: Color = (track_def.road_light if light else track_def.road_dark).lerp(
		track_def.fog_color, fog
	)
	var rumble: Color = (track_def.rumble_light if light else track_def.rumble_dark).lerp(
		track_def.fog_color, fog
	)
	var height: float = seg.y1 - seg.y2
	if height < MIN_QUAD_HEIGHT:
		return
	draw_rect(Rect2(0.0, seg.y2, Constants.VIEWPORT_WIDTH, height), grass)
	var r1: float = seg.w1 * RUMBLE_WIDTH_RATIO
	var r2: float = seg.w2 * RUMBLE_WIDTH_RATIO
	_draw_quad(
		seg.x1 - seg.w1 - r1, seg.x1 - seg.w1, seg.x2 - seg.w2 - r2, seg.x2 - seg.w2, seg, rumble
	)
	_draw_quad(
		seg.x1 + seg.w1, seg.x1 + seg.w1 + r1, seg.x2 + seg.w2, seg.x2 + seg.w2 + r2, seg, rumble
	)
	_draw_quad(seg.x1 - seg.w1, seg.x1 + seg.w1, seg.x2 - seg.w2, seg.x2 + seg.w2, seg, road)
	if not light:
		return
	var lane: Color = track_def.lane_color.lerp(track_def.fog_color, fog)
	var l1: float = seg.w1 * LANE_WIDTH_RATIO
	var l2: float = seg.w2 * LANE_WIDTH_RATIO
	var step1: float = seg.w1 * 2.0 / float(LANES)
	var step2: float = seg.w2 * 2.0 / float(LANES)
	for index: int in range(1, LANES):
		var cx1: float = seg.x1 - seg.w1 + step1 * float(index)
		var cx2: float = seg.x2 - seg.w2 + step2 * float(index)
		_draw_quad(cx1 - l1 / 2.0, cx1 + l1 / 2.0, cx2 - l2 / 2.0, cx2 + l2 / 2.0, seg, lane)


## Trapezoid between the near edge (left1..right1 at y1) and the far edge (left2..right2 at y2).
func _draw_quad(
	left1: float, right1: float, left2: float, right2: float, seg: Projected, color: Color
) -> void:
	if right1 - left1 < MIN_QUAD_WIDTH and right2 - left2 < MIN_QUAD_WIDTH:
		return
	var points: PackedVector2Array = PackedVector2Array(
		[
			Vector2(left1, seg.y1),
			Vector2(right1, seg.y1),
			Vector2(right2, seg.y2),
			Vector2(left2, seg.y2),
		]
	)
	var colors: PackedColorArray = PackedColorArray([color, color, color, color])
	draw_primitive(points, colors, PackedVector2Array())


func _draw_shadow(shadow: Shadow) -> void:
	if shadow.width < SHADOW_MIN_WIDTH:
		return
	var points: PackedVector2Array = PackedVector2Array()
	var half_w: float = shadow.width / 2.0
	var half_h: float = maxf(shadow.width * SHADOW_HEIGHT_RATIO / 2.0, 1.0)
	for index: int in range(SHADOW_POINTS):
		var angle: float = TAU * float(index) / float(SHADOW_POINTS)
		points.append(shadow.center + Vector2(cos(angle) * half_w, sin(angle) * half_h))
	draw_colored_polygon(points, SHADOW_COLOR)
