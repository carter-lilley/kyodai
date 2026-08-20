shader_type canvas_item;

// Isolines Effect - Topographic contour lines
// Port of shadertoy.com/view/wt3fWX

uniform float time_scale : hint_range(0.0, 2.0, 0.05) = 1.0;
uniform float zoom : hint_range(0.05, 1.0, 0.01) = 0.3;
uniform float line_width : hint_range(0.1, 2.0, 0.05) = 0.6;
uniform float lighting_strength : hint_range(0.0, 1.0, 0.05) = 0.35;
uniform vec4 line_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);

float smootherstep_g(float t) {
	return t * t * (3.0 - 2.0 * t);
}

vec3 rand_grad(vec3 cell) {
	vec3 p = mod(cell, 289.0);
	vec3 h = vec3(
		dot(p, vec3(127.1, 311.7, 74.7)),
		dot(p, vec3(269.5, 183.3, 246.1)),
		dot(p, vec3(113.5, 271.9, 124.6))
	);
	vec3 v = -1.0 + 2.0 * fract(sin(h) * 43758.5453123);
	return normalize(v + 1e-5);
}

float perlin_noise(vec3 P, float square_size) {
	vec3 p = P / square_size;
	vec3 i = floor(p);
	vec3 r = fract(p);

	float f000 = dot(r - vec3(0.0, 0.0, 0.0), rand_grad(i + vec3(0.0, 0.0, 0.0)));
	float f001 = dot(r - vec3(1.0, 0.0, 0.0), rand_grad(i + vec3(1.0, 0.0, 0.0)));
	float f010 = dot(r - vec3(0.0, 1.0, 0.0), rand_grad(i + vec3(0.0, 1.0, 0.0)));
	float f011 = dot(r - vec3(1.0, 1.0, 0.0), rand_grad(i + vec3(1.0, 1.0, 0.0)));
	float f100 = dot(r - vec3(0.0, 0.0, 1.0), rand_grad(i + vec3(0.0, 0.0, 1.0)));
	float f101 = dot(r - vec3(1.0, 0.0, 1.0), rand_grad(i + vec3(1.0, 0.0, 1.0)));
	float f110 = dot(r - vec3(0.0, 1.0, 1.0), rand_grad(i + vec3(0.0, 1.0, 1.0)));
	float f111 = dot(r - vec3(1.0, 1.0, 1.0), rand_grad(i + vec3(1.0, 1.0, 1.0)));
	float f00 = f000 + (f001 - f000) * smootherstep_g(r.x);
	float f01 = f010 + (f011 - f010) * smootherstep_g(r.x);
	float f10 = f100 + (f101 - f100) * smootherstep_g(r.x);
	float f11 = f110 + (f111 - f110) * smootherstep_g(r.x);
	float f0 = f00 + (f01 - f00) * smootherstep_g(r.y);
	float f1 = f10 + (f11 - f10) * smootherstep_g(r.y);
	return f0 + (f1 - f0) * smootherstep_g(r.z) + 0.5;
}

float bell(float x, float s) {
	return exp2(-x * x * s);
}

void fragment() {
	vec2 res = 1.0 / SCREEN_PIXEL_SIZE;
	float square_size = min(res.x, res.y) * zoom;
	float t = TIME * time_scale;
	vec3 p = vec3(FRAGCOORD.xy, 0.02 * t * square_size);
	float f = perlin_noise(p, square_size);

	vec2 dF = vec2(dFdx(f), dFdy(f));
	float s = 0.72134752 / max(dot(dF, dF) * line_width * line_width, 1e-6);

	float c = 0.0;
	c += 0.2 * bell(f - 0.1, s);
	c += 0.4 * bell(f - 0.2, s);
	c += 0.5 * bell(f - 0.3, s);
	c += 0.6 * bell(f - 0.4, s);
	c += 0.8 * bell(f - 0.5, s);
	c += 0.6 * bell(f - 0.6, s);
	c += 0.5 * bell(f - 0.7, s);
	c += 0.4 * bell(f - 0.8, s);
	c += 0.2 * bell(f - 0.9, s);

	vec3 q = vec3(FRAGCOORD.xy, t * square_size * 0.2 + 100.0);
	float I = (perlin_noise(q, square_size) + 0.2) * 0.7;
	float light = (I * I) * (I * I);
	c *= mix(1.0, light, lighting_strength);

	// Lines composite over whatever is beneath (transparent elsewhere)
	COLOR = vec4(line_color.rgb, clamp(c, 0.0, 1.0) * line_color.a);
}
