class_name StatPanel
extends GridContainer
## Six labelled StatBars (speed, acceleration, handling, nitro, thrusters, armour) fed by
## Catalog.stats_for(car, tiers): the base rank comes from the CarDef, the part bonus is the
## difference between the tuned physical value mapped back onto the 1..5 rank scale.

const ROWS: Array[Dictionary] = [
	{"label": "SPD", "stat": &"top_speed", "lo": &"top_speed_min", "hi": &"top_speed_max"},
	{"label": "ACC", "stat": &"acceleration", "lo": &"acceleration_min", "hi": &"acceleration_max"},
	{"label": "HND", "stat": &"handling", "lo": &"handling_min", "hi": &"handling_max"},
	{
		"label": "NIT",
		"stat": &"nitro_duration",
		"lo": &"nitro_duration_min",
		"hi": &"nitro_duration_max"
	},
	{
		"label": "THR",
		"stat": &"jump_velocity",
		"lo": &"jump_velocity_min",
		"hi": &"jump_velocity_max"
	},
	{
		"label": "ARM",
		"stat": &"max_integrity",
		"lo": &"max_integrity_min",
		"hi": &"max_integrity_max"
	},
]
const LABEL_WIDTH: float = 22.0
const LABEL_COLOR: Color = Color("#e8e8f0")

var _bars: Array[StatBar] = []


func _ready() -> void:
	columns = 2
	add_theme_constant_override(&"h_separation", 3)
	add_theme_constant_override(&"v_separation", 0)
	for row: Dictionary in ROWS:
		var label: Label = Label.new()
		label.text = str(row["label"])
		label.custom_minimum_size = Vector2(LABEL_WIDTH, 0.0)
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		label.add_theme_color_override(&"font_color", LABEL_COLOR)
		add_child(label)
		var bar: StatBar = StatBar.new()
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		add_child(bar)
		_bars.append(bar)


func refresh(car: CarDef, tiers: Dictionary) -> void:
	if car == null:
		return
	var stats: Dictionary = Catalog.stats_for(car.id, tiers).to_dictionary()
	for index: int in range(ROWS.size()):
		var row: Dictionary = ROWS[index]
		var slot: StringName = Constants.SLOTS[index]
		var base: float = float(car.rank_of(slot))
		var total: float = _rank_of_value(float(stats[row["stat"]]), row["lo"], row["hi"])
		_bars[index].set_ranks(base, maxf(total - base, 0.0))


func _rank_of_value(value: float, lo_key: StringName, hi_key: StringName) -> float:
	var lo: float = Balance.value(lo_key)
	var hi: float = Balance.value(hi_key)
	var rank_min: float = Balance.value(&"rank_min")
	var rank_max: float = Balance.value(&"rank_max")
	if hi <= lo:
		return rank_min
	return lerpf(rank_min, rank_max, (value - lo) / (hi - lo))
