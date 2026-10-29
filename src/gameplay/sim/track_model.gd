class_name TrackModel
extends RefCounted
## Expanded, query-ready form of a TrackDef: per-segment curve and road height, scenery
## placement and total length. Pure data; built once per race. Deterministic from the
## track seed so every peer and every test sees the same road.


class SceneryItem:
	extends RefCounted
	var segment: int = 0
	## Lateral offset in road half-widths: negative = left side, magnitude > 1 is beside the road.
	var offset: float = 0.0
	var sprite_index: int = 0


var definition: TrackDef
var segment_length: float = 0.0
var segment_count: int = 0
var length: float = 0.0
var curves: PackedFloat32Array = PackedFloat32Array()
## Road height at the START of each segment, world units.
var heights: PackedFloat32Array = PackedFloat32Array()
var scenery_density: PackedFloat32Array = PackedFloat32Array()
var scenery: Array[SceneryItem] = []


func _init(track: TrackDef = null) -> void:
	segment_length = Balance.value(&"segment_length")
	if track != null:
		build(track)


func build(track: TrackDef) -> void:
	definition = track
	curves = PackedFloat32Array()
	heights = PackedFloat32Array()
	scenery_density = PackedFloat32Array()
	var height: float = 0.0
	for piece: TrackSegment in track.pieces:
		var start_height: float = height
		var total: int = piece.total()
		for index: int in range(total):
			var curve: float = (
				_ease_piece(index, piece.enter, piece.hold, piece.leave) * piece.curve
			)
			var t: float = float(index) / float(maxi(total, 1))
			height = start_height + piece.hill * _ease_in_out(t)
			curves.append(curve)
			heights.append(height)
			scenery_density.append(piece.scenery)
		height = start_height + piece.hill
	segment_count = curves.size()
	length = float(segment_count) * segment_length
	_place_scenery(track)


func segment_index(z: float) -> int:
	if segment_count == 0:
		return 0
	return posmod(int(floor(wrap_z(z) / segment_length)), segment_count)


func wrap_z(z: float) -> float:
	if length <= 0.0:
		return 0.0
	return fposmod(z, length)


func curve_at(z: float) -> float:
	if segment_count == 0:
		return 0.0
	return curves[segment_index(z)]


func height_at(z: float) -> float:
	if segment_count == 0:
		return 0.0
	var index: int = segment_index(z)
	var next: int = (index + 1) % segment_count
	var t: float = fmod(wrap_z(z), segment_length) / segment_length
	return lerpf(heights[index], heights[next], t)


func curve_of_segment(index: int) -> float:
	return curves[posmod(index, segment_count)] if segment_count > 0 else 0.0


func height_of_segment(index: int) -> float:
	return heights[posmod(index, segment_count)] if segment_count > 0 else 0.0


## Scenery on one segment (small arrays; segments hold 0-2 items).
func scenery_on(index: int) -> Array[SceneryItem]:
	var result: Array[SceneryItem] = []
	var wrapped: int = posmod(index, maxi(segment_count, 1))
	for item: SceneryItem in scenery:
		if item.segment == wrapped:
			result.append(item)
	return result


## Progress in laps + fraction, for ranking: lap * length + z.
func progress_of(z: float, lap: int) -> float:
	return float(lap) * length + wrap_z(z)


func _place_scenery(track: TrackDef) -> void:
	scenery = []
	if track.scenery_sprites.is_empty() or segment_count == 0:
		return
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = track.seed
	var per_segment: float = track.scenery_density / 10.0
	for index: int in range(segment_count):
		var chance: float = per_segment * scenery_density[index]
		if rng.randf() >= chance:
			continue
		var item: SceneryItem = SceneryItem.new()
		item.segment = index
		var side: float = -1.0 if rng.randf() < 0.5 else 1.0
		item.offset = side * rng.randf_range(1.3, 2.4)
		item.sprite_index = rng.randi_range(0, track.scenery_sprites.size() - 1)
		scenery.append(item)


static func _ease_piece(index: int, enter: int, hold: int, leave: int) -> float:
	if index < enter:
		return _ease_in(float(index) / float(maxi(enter, 1)))
	if index < enter + hold:
		return 1.0
	return _ease_out(float(index - enter - hold) / float(maxi(leave, 1)))


static func _ease_in(t: float) -> float:
	return t * t


static func _ease_out(t: float) -> float:
	return 1.0 - (1.0 - t) * (1.0 - t)


static func _ease_in_out(t: float) -> float:
	return 0.5 - 0.5 * cos(t * PI)
