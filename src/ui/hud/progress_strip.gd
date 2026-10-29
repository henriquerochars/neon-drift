class_name ProgressStrip
extends Control
## Vertical track progress strip: one dot per participant, leader-first order comes from the
## race standings; the local car is drawn larger in cyan, rivals in pink. 0 = bottom, 1 = top.

const LINE_COLOR: Color = Color("#8d4fd6")
const LOCAL_COLOR: Color = Color("#3ad1e2")
const RIVAL_COLOR: Color = Color("#ff5fb4")
const FINISH_COLOR: Color = Color("#e8e8f0")
const DEFAULT_SIZE: Vector2 = Vector2(7, 100)
const DOT_SIZE: float = 3.0
const LOCAL_DOT_SIZE: float = 5.0
const FINISH_HEIGHT: float = 2.0

var fractions: Array[float] = []
var local_index: int = -1


func _ready() -> void:
	if custom_minimum_size == Vector2.ZERO:
		custom_minimum_size = DEFAULT_SIZE


func _draw() -> void:
	var center_x: float = floorf(size.x / 2.0)
	draw_rect(Rect2(center_x, 0.0, 1.0, size.y), LINE_COLOR)
	draw_rect(Rect2(0.0, 0.0, size.x, FINISH_HEIGHT), FINISH_COLOR)
	for index: int in range(fractions.size()):
		if index == local_index:
			continue
		_draw_dot(center_x, fractions[index], DOT_SIZE, RIVAL_COLOR)
	if local_index >= 0 and local_index < fractions.size():
		_draw_dot(center_x, fractions[local_index], LOCAL_DOT_SIZE, LOCAL_COLOR)


## `values` are 0..1 progress fractions; `local` is the index of the local car in `values`.
func set_progress(values: Array[float], local: int) -> void:
	fractions = values
	local_index = local
	queue_redraw()


func _draw_dot(center_x: float, fraction: float, dot: float, color: Color) -> void:
	var usable: float = size.y - dot
	var y: float = floorf(usable * (1.0 - clampf(fraction, 0.0, 1.0)))
	var half: float = floorf(dot / 2.0)
	draw_rect(Rect2(center_x - half, y, dot, dot), color)
