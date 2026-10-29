class_name RoadSprite
extends RefCounted
## One billboard the pseudo-3D road draws: a car, a roadside object or a VFX frame.
## z and x are track coordinates (world units along the track, lateral in road half widths).
## Sub-sprites in `vfx` are anchored at the parent's base: their x is a lateral offset in road
## half widths and their altitude a vertical offset in world units; their z is ignored.

var texture: Texture2D
var z: float = 0.0
var x: float = 0.0
## World units above the road; lifts the sprite while its shadow stays on the road.
var altitude: float = 0.0
var flip_h: bool = false
var modulate: Color = Color.WHITE
var scale_multiplier: float = 1.0
## Optional paint material (CarSprites.material_for); null draws the texture as is.
var material: Material
var shadow: bool = true
var vfx: Array[RoadSprite] = []
