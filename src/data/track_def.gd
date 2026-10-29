class_name TrackDef
extends Resource
## A race track: road pieces, colours, background and roadside scenery sprites.

@export var id: StringName = &""
@export var display_name: String = ""
@export_multiline var description: String = ""
@export var laps: int = 3
@export var background: Texture2D
@export var pieces: Array[TrackSegment] = []
@export var scenery_sprites: Array[Texture2D] = []
## Average scenery objects per 10 segments.
@export var scenery_density: float = 2.0
@export var seed: int = 1
@export var sky_color: Color = Color("#2a1a4a")
@export var fog_color: Color = Color("#2a1a4a")
@export var road_light: Color = Color("#6b6b7a")
@export var road_dark: Color = Color("#636372")
@export var grass_light: Color = Color("#3fae5a")
@export var grass_dark: Color = Color("#2f8a46")
@export var rumble_light: Color = Color("#f2f2f2")
@export var rumble_dark: Color = Color("#e23a3a")
@export var lane_color: Color = Color("#f2f2f2")
@export var music: StringName = &"race_a"
## Money for 1st..8th place.
@export var prizes: Array[int] = [1200, 800, 600, 450, 300, 200, 100, 50]


func total_segments() -> int:
	var total: int = 0
	for piece: TrackSegment in pieces:
		total += piece.total()
	return total
