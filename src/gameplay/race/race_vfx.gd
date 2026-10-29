class_name RaceVfx
extends RefCounted
## Sprite-strip VFX attached to cars: `art/vfx/<name>.png` + `<name>.json`
## ({"frame_width", "frame_height", "frames", "fps", "loop"}). Missing files are skipped.
## Produces RoadSprite sub-sprites anchored at the car's base.


class Anim:
	extends RefCounted
	var frames: Array[Texture2D] = []
	var fps: float = 12.0
	var loop: bool = false
	## Vertical pivot from the strip's JSON (0 = top edge); only the nitro flame uses it.
	var pivot_y: float = 1.0

	func duration() -> float:
		return float(frames.size()) / maxf(fps, 0.001)

	func frame_at(time: float) -> Texture2D:
		if frames.is_empty():
			return null
		var index: int = int(time * fps)
		if loop:
			index = posmod(index, frames.size())
		return frames[clampi(index, 0, frames.size() - 1)]


class Active:
	extends RefCounted
	var name: StringName = &""
	var participant_id: int = 0
	var time: float = 0.0


const VFX_DIR: String = "res://art/vfx"
const NITRO_FLAME: StringName = &"nitro_flame"
const THRUSTER_BURST: StringName = &"thruster_burst"
const LANDING_DUST: StringName = &"landing_dust"
const CRUSH_SPARKS: StringName = &"crush_sparks"
const BUMP_SPARKS: StringName = &"bump_sparks"
const NAMES: Array[StringName] = [
	NITRO_FLAME, THRUSTER_BURST, LANDING_DUST, CRUSH_SPARKS, BUMP_SPARKS
]
const DEFAULT_FPS: float = 12.0
## Nitro: two flames hang from the exhausts, in the car's source pixels from its base
## (rear sprites: body bottom at the base, bumper ~8 px up, pipes ~9 px either side of centre).
const EXHAUST_OFFSETS: Array[Vector2] = [Vector2(-9.0, -8.0), Vector2(9.0, -8.0)]
const NITRO_FLAME_SCALE: float = 0.45

var _anims: Dictionary = {}
var _active: Array[Active] = []
var _clock: float = 0.0


func load_all() -> void:
	_anims = {}
	for name: StringName in NAMES:
		var anim: Anim = _load_anim(name)
		if anim != null:
			_anims[name] = anim


func has(name: StringName) -> bool:
	return _anims.has(name)


## Starts a one-shot effect on a car; ignored for missing or looping animations.
func trigger(name: StringName, participant_id: int) -> void:
	if not _anims.has(name):
		return
	var active: Active = Active.new()
	active.name = name
	active.participant_id = participant_id
	_active.append(active)


func update(delta: float) -> void:
	_clock += delta
	var kept: Array[Active] = []
	for active: Active in _active:
		active.time += delta
		var anim: Anim = _anims[active.name]
		if anim.loop or active.time < anim.duration():
			kept.append(active)
	_active = kept


## Sub-sprites for one car this tick: the nitro flame while nitro is active plus one-shots.
func sprites_for(participant_id: int, nitro_active: bool) -> Array[RoadSprite]:
	var result: Array[RoadSprite] = []
	if nitro_active and _anims.has(NITRO_FLAME):
		var flame: Anim = _anims[NITRO_FLAME]
		for offset: Vector2 in EXHAUST_OFFSETS:
			var sprite: RoadSprite = _sprite(flame.frame_at(_clock))
			sprite.offset_pixels = offset
			sprite.pivot_y = flame.pivot_y
			sprite.scale_multiplier = NITRO_FLAME_SCALE
			result.append(sprite)
	for active: Active in _active:
		if active.participant_id != participant_id:
			continue
		result.append(_sprite((_anims[active.name] as Anim).frame_at(active.time)))
	return result


func _sprite(texture: Texture2D) -> RoadSprite:
	var sprite: RoadSprite = RoadSprite.new()
	sprite.texture = texture
	sprite.shadow = false
	return sprite


func _load_anim(name: StringName) -> Anim:
	var png: String = "%s/%s.png" % [VFX_DIR, name]
	var json: String = "%s/%s.json" % [VFX_DIR, name]
	if not FileAccess.file_exists(json):
		return null
	var texture: Texture2D = _load_texture(png)
	if texture == null:
		return null
	var file: FileAccess = FileAccess.open(json, FileAccess.READ)
	if file == null:
		return null
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		return null
	var data: Dictionary = parsed
	var frame_w: int = int(data.get("frame_width", texture.get_width()))
	var frame_h: int = int(data.get("frame_height", texture.get_height()))
	var count: int = int(data.get("frames", 1))
	if frame_w <= 0 or frame_h <= 0 or count <= 0:
		return null
	var anim: Anim = Anim.new()
	anim.fps = float(data.get("fps", DEFAULT_FPS))
	anim.loop = bool(data.get("loop", false))
	anim.pivot_y = float(data.get("pivot_y", 1.0)) if anim.loop else 1.0
	var columns: int = maxi(texture.get_width() / frame_w, 1)
	for index: int in range(count):
		var atlas: AtlasTexture = AtlasTexture.new()
		atlas.atlas = texture
		atlas.region = Rect2(
			float((index % columns) * frame_w), float((index / columns) * frame_h), frame_w, frame_h
		)
		anim.frames.append(atlas)
	return anim


func _load_texture(path: String) -> Texture2D:
	if ResourceLoader.exists(path):
		return load(path) as Texture2D
	if not FileAccess.file_exists(path):
		return null
	var image: Image = Image.load_from_file(path)
	if image == null:
		return null
	return ImageTexture.create_from_image(image)
