class_name PaintShift
extends RefCounted
## Builds and updates the hue-shift ShaderMaterial that tints a car sprite with a paint colour.

const SHADER: Shader = preload("res://src/ui/garage/paint_shift.gdshader")
const MIN_COMPONENT: float = 0.01


static func material_for(base: Color, target: Color) -> ShaderMaterial:
	var material: ShaderMaterial = ShaderMaterial.new()
	material.shader = SHADER
	apply(material, base, target)
	return material


static func apply(material: ShaderMaterial, base: Color, target: Color) -> void:
	if material == null:
		return
	material.set_shader_parameter(&"base_hue", base.h)
	material.set_shader_parameter(&"hue_shift", target.h - base.h)
	material.set_shader_parameter(&"sat_scale", target.s / maxf(base.s, MIN_COMPONENT))
	material.set_shader_parameter(&"val_scale", target.v / maxf(base.v, MIN_COMPONENT))


static func paint_color(paint: int) -> Color:
	return Constants.PAINTS[posmod(paint, Constants.PAINT_COUNT)]
