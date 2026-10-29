shader_type canvas_item;
// Car paint: shifts the hue of saturated body pixels toward the chosen paint and keeps the
// dark outline and greys untouched. Works on gl_compatibility (no derivatives, no textures).

uniform float hue_shift : hint_range(-1.0, 1.0) = 0.0;
uniform float saturation_scale : hint_range(0.0, 2.0) = 1.0;
uniform float value_scale : hint_range(0.0, 2.0) = 1.0;
uniform float min_saturation : hint_range(0.0, 1.0) = 0.35;

vec3 rgb_to_hsv(vec3 c) {
	vec4 k = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
	vec4 p = mix(vec4(c.bg, k.wz), vec4(c.gb, k.xy), step(c.b, c.g));
	vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
	float d = q.x - min(q.w, q.y);
	float e = 1.0e-10;
	return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

vec3 hsv_to_rgb(vec3 c) {
	vec4 k = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
	vec3 p = abs(fract(c.xxx + k.xyz) * 6.0 - k.www);
	return c.z * mix(k.xxx, clamp(p - k.xxx, 0.0, 1.0), c.y);
}

void fragment() {
	vec4 texel = texture(TEXTURE, UV);
	vec3 hsv = rgb_to_hsv(texel.rgb);
	if (hsv.y > min_saturation) {
		hsv.x = fract(hsv.x + hue_shift);
		hsv.y = clamp(hsv.y * saturation_scale, 0.0, 1.0);
		hsv.z = clamp(hsv.z * value_scale, 0.0, 1.0);
		texel.rgb = hsv_to_rgb(hsv);
	}
	COLOR = texel * COLOR;
}
