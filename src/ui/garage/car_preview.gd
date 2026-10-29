class_name CarPreview
extends TextureRect
## Shows one of a car's 8 PixelLab rotations, optionally cycling them every ROTATE_INTERVAL
## seconds (south -> south-west -> west -> ... clockwise as seen from above), tinted with the
## paint hue-shift shader.

const ROTATE_INTERVAL: float = 0.35
## Display order of CarDef.DIRECTIONS for the turntable.
const TURNTABLE: Array[String] = [
	"south",
	"south-west",
	"west",
	"north-west",
	"north",
	"north-east",
	"east",
	"south-east",
]
const FRONT_INDEX: int = 0

var car: CarDef
var paint: int = 0
var direction_index: int = FRONT_INDEX
var rotating: bool = false:
	set(value):
		rotating = value
		if _timer != null:
			if rotating:
				_timer.start()
			else:
				_timer.stop()

var _timer: Timer
var _material: ShaderMaterial


func _ready() -> void:
	stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	_timer = Timer.new()
	_timer.wait_time = ROTATE_INTERVAL
	_timer.timeout.connect(step_direction)
	add_child(_timer)
	if rotating:
		_timer.start()


func set_car(definition: CarDef, paint_index: int) -> void:
	car = definition
	paint = paint_index
	direction_index = FRONT_INDEX
	_refresh_material()
	_refresh_texture()


func set_paint(paint_index: int) -> void:
	paint = paint_index
	_refresh_material()


func set_direction(index: int) -> void:
	direction_index = posmod(index, TURNTABLE.size())
	_refresh_texture()


func step_direction() -> void:
	set_direction(direction_index + 1)


func current_direction() -> String:
	return TURNTABLE[direction_index]


func _refresh_texture() -> void:
	if car == null:
		texture = null
		return
	var path: String = car.sprite_path(current_direction())
	texture = load(path) as Texture2D if ResourceLoader.exists(path) else null


func _refresh_material() -> void:
	if car == null:
		material = null
		return
	var target: Color = PaintShift.paint_color(paint)
	if _material == null:
		_material = PaintShift.material_for(car.base_color, target)
	else:
		PaintShift.apply(_material, car.base_color, target)
	material = _material
