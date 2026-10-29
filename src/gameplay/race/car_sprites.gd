class_name CarSprites
extends RefCounted
## Loads a CarDef's 8 PixelLab rotations (north = rear view) and picks the rear sprite for a
## steering value. Paint is a hue shift applied by paint.gdshader; one ShaderMaterial per
## (car, paint) pair is cached so the race and the garage share them.

const DIRECTION_REAR: String = "north"
const DIRECTION_REAR_RIGHT: String = "north-east"
const DIRECTION_REAR_LEFT: String = "north-west"
## |steer_visual| below this shows the straight rear view.
const STEER_DEADZONE: float = 0.3
## Transparent rows under the body of the PixelLab rear sprites (68 px canvas, body ends near
## row 55); RoadSprite.ground_pixels uses it so cars sit on their shadows.
const GROUND_PIXELS: float = 12.0
const PAINT_SHADER_PATH: String = "res://src/gameplay/race/paint.gdshader"
const BODY_SATURATION: float = 0.35
## Low-saturation bodies (navy, silver) still take paint: the threshold follows the base colour.
const BODY_SATURATION_RATIO: float = 0.6
const MAX_SCALE: float = 3.0

static var _materials: Dictionary = {}
static var _shader: Shader

var car: CarDef
var _textures: Dictionary = {}


func _init(definition: CarDef) -> void:
	car = definition
	if definition == null:
		return
	for direction: String in CarDef.DIRECTIONS:
		var path: String = definition.sprite_path(direction)
		if ResourceLoader.exists(path):
			_textures[direction] = load(path) as Texture2D


func texture_for(direction: String) -> Texture2D:
	return _textures.get(direction) as Texture2D


func rear_texture(steer_visual: float) -> Texture2D:
	if steer_visual > STEER_DEADZONE:
		return texture_for(DIRECTION_REAR_RIGHT)
	if steer_visual < -STEER_DEADZONE:
		return texture_for(DIRECTION_REAR_LEFT)
	return texture_for(DIRECTION_REAR)


## Paint material for this car; null for an unknown car.
func material_for(paint: int) -> ShaderMaterial:
	if car == null:
		return null
	return paint_material(car, paint)


## Cached ShaderMaterial shifting the car's base colour hue onto Constants.PAINTS[paint].
static func paint_material(definition: CarDef, paint: int) -> ShaderMaterial:
	var index: int = posmod(paint, Constants.PAINT_COUNT)
	var key: String = "%s:%d" % [definition.id, index]
	if _materials.has(key):
		return _materials[key] as ShaderMaterial
	if _shader == null:
		_shader = load(PAINT_SHADER_PATH) as Shader
	var target: Color = Constants.PAINTS[index]
	var base: Color = definition.base_color
	var material: ShaderMaterial = ShaderMaterial.new()
	material.shader = _shader
	material.set_shader_parameter(&"hue_shift", target.h - base.h)
	material.set_shader_parameter(
		&"saturation_scale", clampf(target.s / maxf(base.s, 0.01), 0.0, MAX_SCALE)
	)
	material.set_shader_parameter(
		&"value_scale", clampf(target.v / maxf(base.v, 0.01), 0.0, MAX_SCALE)
	)
	material.set_shader_parameter(
		&"min_saturation", minf(BODY_SATURATION, base.s * BODY_SATURATION_RATIO)
	)
	_materials[key] = material
	return material
