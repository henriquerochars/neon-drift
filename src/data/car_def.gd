class_name CarDef
extends Resource
## One selectable car. Ranks are 1..5 and map to physics through Balance.stats_for().

const DIRECTIONS: Array[String] = [
	"north",
	"north-east",
	"east",
	"south-east",
	"south",
	"south-west",
	"west",
	"north-west",
]
const RANK_PROPERTIES: Dictionary = {
	&"engine": &"top_speed_rank",
	&"turbo": &"acceleration_rank",
	&"tires": &"handling_rank",
	&"nitro_tank": &"nitro_rank",
	&"thrusters": &"thruster_rank",
	&"armour": &"armour_rank",
}

@export var id: StringName = &""
@export var display_name: String = ""
@export_multiline var description: String = ""
## Folder with north.png, north-east.png ... (8 PixelLab rotations). North is the rear view.
@export_dir var sprite_dir: String = ""
@export var base_color: Color = Color.WHITE
@export_range(1, 5) var top_speed_rank: int = 3
@export_range(1, 5) var acceleration_rank: int = 3
@export_range(1, 5) var handling_rank: int = 3
@export_range(1, 5) var nitro_rank: int = 3
@export_range(1, 5) var thruster_rank: int = 3
@export_range(1, 5) var armour_rank: int = 3


func sprite_path(direction: String) -> String:
	return "%s/%s.png" % [sprite_dir, direction]


func rank_of(slot: StringName) -> int:
	if not RANK_PROPERTIES.has(slot):
		return 0
	return int(get(RANK_PROPERTIES[slot]))
