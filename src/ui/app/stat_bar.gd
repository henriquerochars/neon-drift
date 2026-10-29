class_name StatBar
extends Control
## Five-segment rank bar: the car's base rank in cyan, the installed parts' bonus in pink.

const SEGMENTS: int = 5
const SEGMENT_WIDTH: int = 7
const SEGMENT_GAP: int = 1
const BAR_HEIGHT: int = 5
const BASE_COLOR: Color = Color("#3ad1e2")
const BONUS_COLOR: Color = Color("#ff5fb4")
const EMPTY_COLOR: Color = Color("#2a2340")

var base_rank: float = 0.0
var bonus_rank: float = 0.0


func _ready() -> void:
	custom_minimum_size = Vector2(
		SEGMENTS * (SEGMENT_WIDTH + SEGMENT_GAP) - SEGMENT_GAP, BAR_HEIGHT
	)


func _draw() -> void:
	for index: int in range(SEGMENTS):
		var x: float = float(index * (SEGMENT_WIDTH + SEGMENT_GAP))
		draw_rect(Rect2(x, 0.0, SEGMENT_WIDTH, BAR_HEIGHT), EMPTY_COLOR)
		_draw_fill(x, index, base_rank, BASE_COLOR)
		_draw_fill(x, index, base_rank + bonus_rank, BONUS_COLOR, base_rank)


func set_ranks(base: float, bonus: float) -> void:
	base_rank = clampf(base, 0.0, SEGMENTS)
	bonus_rank = clampf(bonus, 0.0, SEGMENTS - base_rank)
	queue_redraw()


func _draw_fill(x: float, index: int, rank: float, color: Color, from_rank: float = 0.0) -> void:
	var start: float = clampf(from_rank - index, 0.0, 1.0)
	var stop: float = clampf(rank - index, 0.0, 1.0)
	if stop <= start:
		return
	var left: float = x + roundf(start * SEGMENT_WIDTH)
	var width: float = roundf(stop * SEGMENT_WIDTH) - roundf(start * SEGMENT_WIDTH)
	if width <= 0.0:
		return
	draw_rect(Rect2(left, 0.0, width, BAR_HEIGHT), color)
