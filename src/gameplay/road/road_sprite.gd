class_name RoadSprite
extends RefCounted
## One billboard the pseudo-3D road draws: a car, a roadside object or a VFX frame.
## z and x are track coordinates (world units along the track, lateral in road half widths).
## Sub-sprites in `vfx` are anchored at the parent's base: their x is a lateral offset in road
## half widths and their altitude a vertical offset in world units; their z is ignored.
## `offset_pixels` and `pivot_y` place a sub-sprite in the parent's source pixels, so effects
## stay glued to the same spot of the car at every distance.

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
## Transparent source rows under the visible body: the sprite is drawn this much lower so the
## body, not the texture edge, sits on its shadow.
var ground_pixels: float = 0.0
## Sub-sprites only: fraction of the height placed at the anchor (1 = bottom edge, 0 = top edge).
var pivot_y: float = 1.0
## Sub-sprites only: offset from the parent's base in the parent's source pixels (+y is down).
var offset_pixels: Vector2 = Vector2.ZERO
var vfx: Array[RoadSprite] = []
