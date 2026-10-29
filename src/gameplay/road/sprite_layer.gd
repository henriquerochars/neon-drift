class_name SpriteLayer
extends Node2D
## Pool of Sprite2D nodes the road fills every frame with projected billboards, so each car
## can carry its own paint ShaderMaterial (a single _draw cannot switch materials per call).


class Placement:
	extends RefCounted
	var texture: Texture2D
	var material: Material
	var rect: Rect2 = Rect2()
	## Fraction of the source height kept (hill clipping cuts the bottom).
	var visible_fraction: float = 1.0
	var flip_h: bool = false
	var modulate: Color = Color.WHITE
	var depth: int = 0


var _pool: Array[Sprite2D] = []


func render(placements: Array[Placement]) -> void:
	while _pool.size() < placements.size():
		var sprite: Sprite2D = Sprite2D.new()
		sprite.centered = false
		add_child(sprite)
		_pool.append(sprite)
	for index: int in range(_pool.size()):
		var sprite: Sprite2D = _pool[index]
		if index >= placements.size():
			sprite.visible = false
			continue
		var placement: Placement = placements[index]
		var size: Vector2 = placement.texture.get_size()
		sprite.visible = true
		sprite.texture = placement.texture
		sprite.material = placement.material
		sprite.flip_h = placement.flip_h
		sprite.modulate = placement.modulate
		sprite.z_index = placement.depth
		sprite.region_enabled = placement.visible_fraction < 1.0
		if sprite.region_enabled:
			sprite.region_rect = Rect2(0.0, 0.0, size.x, size.y * placement.visible_fraction)
		sprite.position = placement.rect.position.round()
		sprite.scale = Vector2(placement.rect.size.x / size.x, placement.rect.size.y / size.y)
