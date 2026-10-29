shader_type canvas_item;
// Hue shift of the car body: pixels close to base_hue (and saturated enough) are moved to the
// paint hue, with saturation and value scaled so near-white and near-black paints work too.

uniform float base_hue = 0.0;
uniform float hue_shift = 0.0;
uniform float sat_scale = 1.0;
uniform float val_scale = 1.0;
uniform float hue_tolerance = 0.12;
uniform float min_saturation = 0.3;

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
	vec4 col = texture(TEXTURE, UV);
	vec3 hsv = rgb_to_hsv(col.rgb);
	float distance_to_base = abs(hsv.x - base_hue);
	distance_to_base = min(distance_to_base, 1.0 - distance_to_base);
	if (hsv.y >= min_saturation && distance_to_base <= hue_tolerance) {
		hsv.x = fract(hsv.x + hue_shift);
		hsv.y = clamp(hsv.y * sat_scale, 0.0, 1.0);
		hsv.z = clamp(hsv.z * val_scale, 0.0, 1.0);
		col.rgb = hsv_to_rgb(hsv);
	}
	COLOR = col;
}
