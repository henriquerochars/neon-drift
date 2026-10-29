class_name TrackSegment
extends Resource
## One road piece in the classic enter/hold/leave form. Lengths are in segments
## (Balance segment_length world units each). curve: +right/-left per segment; hill: total
## height change in world units over the piece.

@export var enter: int = 20
@export var hold: int = 20
@export var leave: int = 20
@export var curve: float = 0.0
@export var hill: float = 0.0
## Scenery density multiplier for this piece (0 = none).
@export var scenery: float = 1.0


func total() -> int:
	return enter + hold + leave
