shader_type canvas_item;

// Horizon3D Effect - Rounded plates on a rotating tilted sphere
// Inspired by the Nintendo 3DS HOME menu background

uniform float time_scale : hint_range(0.0, 2.0, 0.05) = 0.1;
uniform float rotation_speed : hint_range(0.0, 2.0, 0.05) = 0.35;
uniform float axis_tilt : hint_range(0.0, 1.4, 0.05) = 0.0;
uniform float diagonal_ratio : hint_range(0.0, 1.0, 0.05) = 0.4;
uniform float curvature : hint_range(0.2, 1.2, 0.05) = 0.25;
uniform float rows_visible : hint_range(1.5, 10.0, 0.5) = 4.0;
uniform float tile_scale : hint_range(0.5, 1.5, 0.05) = 0.8;
uniform float corner_radius : hint_range(0.0, 0.5, 0.01) = 0.18;
uniform float tile_opacity : hint_range(0.0, 1.0, 0.05) = 0.45;
uniform float border_opacity : hint_range(0.0, 1.0, 0.05) = 0.25;
uniform float parallax_factor : hint_range(0.1, 1.0, 0.05) = 0.15;
uniform float back_layer_dim : hint_range(0.0, 1.0, 0.05) = 0.1;
uniform vec4 tile_color_top : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform vec4 tile_color_bottom : source_color = vec4(0.88, 0.88, 0.93, 1.0);
uniform vec4 bg_color_top : source_color = vec4(0.93, 0.93, 0.96, 1.0);
uniform vec4 bg_color_bottom : source_color = vec4(0.8, 0.8, 0.87, 1.0);

const float BORDER_W = 0.035;

float sd_round_box(vec2 p, vec2 b, float r) {
	vec2 q = abs(p) - b + r;
	return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - r;
}

vec3 rot_y(vec3 v, float a) {
	float c = cos(a);
	float s = sin(a);
	return vec3(c * v.x + s * v.z, v.y, -s * v.x + c * v.z);
}

vec3 rot_x(vec3 v, float a) {
	float c = cos(a);
	float s = sin(a);
	return vec3(v.x, c * v.y - s * v.z, s * v.y + c * v.z);
}

vec4 tile_layer(vec2 frag, vec2 res, float s, float ang, float pitch_scale, float stagger, float dim) {
	vec2 pc = (frag - res * 0.5) / s;
	vec3 d = normalize(vec3(pc * curvature * pitch_scale, 1.0));
	vec3 d0 = rot_x(rot_y(d, -ang), -axis_tilt);

	float lon = atan(d0.x, d0.z);
	float lat = asin(clamp(d0.y, -1.0, 1.0)) + ang * diagonal_ratio;

	float cols = round(TAU / (curvature * pitch_scale));
	vec2 grid = vec2(lon, lat) / TAU * cols + stagger;
	vec2 l = fract(grid) - 0.5;

	float shade = mix(0.75, 1.0, d.z) * dim;

	float half_base = 0.5 * tile_scale;
	float r = corner_radius * half_base;
	float dist = sd_round_box(l, vec2(half_base) - r, r);
	float aa = fwidth(dist) * 1.5 + 1e-4;

	float fill = 1.0 - smoothstep(-aa, aa, dist);
	float border = (1.0 - smoothstep(-BORDER_W - aa, -BORDER_W + aa, dist)) * fill;

	float gy = clamp(l.y / half_base * 0.5 + 0.5, 0.0, 1.0);
	vec3 tile_col = mix(tile_color_bottom.rgb, tile_color_top.rgb, gy) * shade;

	float a_tile = max(fill * tile_opacity, border * border_opacity) * dim;
	vec3 c_tile = mix(tile_col, vec3(shade), border * border_opacity);

	return vec4(c_tile, a_tile);
}

void fragment() {
	vec2 res = 1.0 / SCREEN_PIXEL_SIZE;
	float s = res.y / rows_visible;
	float ang = TIME * time_scale * rotation_speed * 0.6;

	vec3 col = mix(bg_color_bottom.rgb, bg_color_top.rgb, FRAGCOORD.y / res.y);

	vec4 back = tile_layer(FRAGCOORD.xy, res, s, ang * parallax_factor + 1.5, 0.9, 0.5, back_layer_dim);
	col = mix(col, back.rgb, back.a);

	vec4 front = tile_layer(FRAGCOORD.xy, res, s, ang, 1.0, 0.0, 1.0);
	col = mix(col, front.rgb, front.a);

	COLOR = vec4(col, 1.0);
}
