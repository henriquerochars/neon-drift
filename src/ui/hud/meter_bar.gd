class_name MeterBar
extends Control
## Pixel meter: 1px outline, dark track and a coloured fill for a 0..1 value.

const OUTLINE_COLOR: Color = Color("#e8e8f0")
const TRACK_COLOR: Color = Color("#0b0a1e")
const DEFAULT_FILL: Color = Color("#3ad1e2")
const DEFAULT_SIZE: Vector2 = Vector2(40, 5)
const OUTLINE: float = 1.0

var value: float = 1.0
var fill_color: Color = DEFAULT_FILL


func _ready() -> void:
	if custom_minimum_size == Vector2.ZERO:
		custom_minimum_size = DEFAULT_SIZE


func _draw() -> void:
	var box: Rect2 = Rect2(Vector2.ZERO, size)
	draw_rect(box, OUTLINE_COLOR)
	var inner: Rect2 = box.grow(-OUTLINE)
	draw_rect(inner, TRACK_COLOR)
	var width: float = floorf(inner.size.x * clampf(value, 0.0, 1.0))
	if width > 0.0:
		draw_rect(Rect2(inner.position, Vector2(width, inner.size.y)), fill_color)


func set_value(fraction: float, color: Color = Color(0, 0, 0, 0)) -> void:
	value = clampf(fraction, 0.0, 1.0)
	if color.a > 0.0:
		fill_color = color
	queue_redraw()
