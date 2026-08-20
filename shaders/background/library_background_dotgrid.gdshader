shader_type canvas_item;

// Dot Grid Effect - Grid of dots modulated by evolving soft noise

uniform float time_scale : hint_range(0.0, 2.0, 0.05) = 1.0;
uniform float dot_spacing : hint_range(5.0, 100.0, 1.0) = 30.0;
uniform float dot_size : hint_range(0.02, 0.3, 0.005) = 0.15;
uniform float noise_scale : hint_range(0.1, 5.0, 0.1) = 1.0;
uniform float size_modulation : hint_range(0.0, 1.0, 0.05) = 0.35;
uniform float opacity_modulation : hint_range(0.0, 1.0, 0.05) = 0.9;
uniform vec4 color_a : source_color = vec4(1.0, 0.082, 0.621, 1.0);
uniform vec4 color_b : source_color = vec4(1.0, 0.152, 0.009, 1.0);

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = hash(mod(i, 289.0));
	float b = hash(mod(i + vec2(1.0, 0.0), 289.0));
	float c = hash(mod(i + vec2(0.0, 1.0), 289.0));
	float d = hash(mod(i + vec2(1.0, 1.0), 289.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

void fragment() {
	vec2 res = 1.0 / SCREEN_PIXEL_SIZE;
	vec2 st = FRAGCOORD.xy / res;
	st.x *= res.x / res.y;
	float t = TIME * time_scale;

	vec2 grid = st * dot_spacing;
	vec2 cell_id = floor(grid);
	vec2 cell = fract(grid) - 0.5;

	float n = value_noise(cell_id * 0.15 * noise_scale + vec2(t * 0.15, t * 0.1));

	float radius = dot_size * mix(1.0, 0.3 + 0.7 * n, size_modulation);
	float d = length(cell);
	float aa = fwidth(d) * 1.5;
	float dot_mask = 1.0 - smoothstep(radius - aa, radius + aa, d);

	float alpha = mix(1.0, smoothstep(0.15, 0.85, n), opacity_modulation);

	float mix_t = st.x / (res.x / res.y);
	vec3 dot_color = mix(color_a.rgb, color_b.rgb, mix_t);
	float dot_alpha = mix(color_a.a, color_b.a, mix_t);

	// Transparent between dots so layers beneath show through
	COLOR = vec4(dot_color, dot_alpha * dot_mask * alpha);
}
