shader_type canvas_item;

// PS3 XMB Background Shader Port
// Based on: https://www.shadertoy.com/view/tXy3DK by int_45h
// Ported to Godot 4.x

uniform float time_scale : hint_range(0.0, 2.0) = 1.0;
uniform bool show_dust = true;
uniform float wave_intensity : hint_range(0.0, 2.0) = 1.0;
uniform float star_threshold : hint_range(0.9, 1.0) = 0.99;
uniform sampler2D noise_texture : filter_linear, repeat_enable;

const float THRESHOLD = 0.99;
const float MIN_DIST = 0.13;
const float MAX_DIST = 40.0;
const int MAX_DRAWS = 40;

// Hash function (Dave Hoskins style)
float hash12(vec2 p) {
	uvec2 q = uvec2(ivec2(p)) * uvec2(1597334673U, 3812015801U);
	uint n = (q.x ^ q.y) * 1597334673U;
	return float(n) * 2.328306437080797e-10;
}

// Value noise using texture
float value2d_tex(vec2 p) {
	return texture(noise_texture, p / vec2(1024.0, 1024.0)).r;
}

// Alternative value noise using hash
float value2d_hash(vec2 p) {
	vec2 pg = floor(p);
	vec2 pc = p - pg;
	vec2 k = vec2(0.0, 1.0);
	pc *= pc * pc * (3.0 - 2.0 * pc);
	return mix(
		mix(hash12(pg + k.xx), hash12(pg + k.yx), pc.x),
		mix(hash12(pg + k.xy), hash12(pg + k.yy), pc.x),
		pc.y
	);
}

// Get stars (rough)
float get_stars_rough(vec2 p) {
	float h = hash12(p);
	float s = smoothstep(THRESHOLD, 1.0, h);
	if (s >= THRESHOLD) {
		s = pow((s - THRESHOLD) / (1.0 - THRESHOLD), 10.0);
	}
	return s;
}

// Get stars (smooth)
float get_stars(vec2 p, float a, float t, float time) {
	vec2 pg = floor(p);
	vec2 pc = p - pg;
	vec2 k = vec2(0.0, 1.0);
	pc *= pc * pc * (3.0 - 2.0 * pc);
	
	float s = mix(
		mix(get_stars_rough(pg + k.xx), get_stars_rough(pg + k.yx), pc.x),
		mix(get_stars_rough(pg + k.xy), get_stars_rough(pg + k.yy), pc.x),
		pc.y
	);
	return smoothstep(a, a + t, s) * pow(value2d_hash(p * 0.1 + time) * 0.5 + 0.5, 8.3);
}

// Shorthand for .5+.5*sin/cos
float s5(float x) { return 0.5 + 0.5 * sin(x); }
float c5(float x) { return 0.5 + 0.5 * cos(x); }

// Get dust particles
float get_dust(vec2 p, vec2 size, float f, float time, vec2 resolution) {
	vec2 ar = vec2(resolution.x / resolution.y, 1.0);
	vec2 pp = p * size * ar;
	
	float intensity = pow(0.64 + 0.46 * cos(p.x * 6.28), 1.7);
	
	return intensity * f * (
		get_stars(0.1 * pp + time * vec2(20.0, -10.1), 0.11, 0.71, time) * 4.0 +
		get_stars(0.2 * pp + time * vec2(30.0, -10.1), 0.1, 0.31, time) * 5.0 +
		get_stars(0.32 * pp + time * vec2(40.0, -10.1), 0.1, 0.91, time) * 2.0
	);
}

// SDF for the wave
float sdf(vec3 p, float time) {
	p *= 2.0;
	float o = 4.2 * sin(0.05 * p.x + time * 0.25) +
		(0.04 * p.z) *
		sin(p.x * 0.11 + time) *
		2.0 * sin(p.z * 0.2 + time) *
		value2d_hash(vec2(0.03, 0.4) * p.xz + vec2(time * 0.5, 0.0));
	return abs(dot(p, normalize(vec3(0.0, 1.0, 0.05))) + 2.5 + o * 0.5);
}

// Normal calculation
vec3 norm(vec3 p, float time) {
	const vec2 k = vec2(1.0, -1.0);
	const float t = 0.001;
	return normalize(
		k.xyy * sdf(p + t * k.xyy, time) +
		k.yyx * sdf(p + t * k.yyx, time) +
		k.yxy * sdf(p + t * k.yxy, time) +
		k.xxx * sdf(p + t * k.xxx, time)
	);
}

// Raymarching
vec2 raymarch(vec3 o, vec3 d, float omega, float time) {
	float t = 0.0;
	float a = 0.0;
	float g = MAX_DIST;
	float dt = 0.0;
	float sl = 0.0;
	float emin = 0.03;
	float ed = emin;
	int dr = 0;
	bool hit = false;
	
	for (int i = 0; i < 100; i++) {
		vec3 p = o + d * t;
		float ndt = sdf(p, time);
		
		if (abs(dt) + abs(ndt) < sl) {
			sl -= omega * sl;
			omega = 1.0;
		} else {
			sl = ndt * omega;
		}
		
		dt = ndt;
		t += sl;
		
		g = (t > 10.0) ? min(g, abs(dt)) : MAX_DIST;
		
		t += dt;
		if (t >= MAX_DIST) break;
		
		if (dt < MIN_DIST) {
			if (dr > MAX_DRAWS) break;
			dr++;
			
			float f = smoothstep(0.09, 0.11, (p.z * 0.9) / 100.0);
			
			if (!hit) {
				a = 0.01;
				hit = true;
			}
			
			ed = 2.0 * max(emin, abs(ndt));
			a += 0.0135 * f;
			t += ed;
		}
	}
	
	g /= 3.0;
	return vec2(a, max(1.0 - g, 0.0));
}

void fragment() {
	vec2 resolution = 1.0 / SCREEN_PIXEL_SIZE;
	vec2 uv = UV;
	vec2 U = uv * resolution;
	
	float time = TIME * time_scale;
	
	vec3 o = vec3(0.0);
	vec3 d = vec3((U - 0.5 * resolution) / resolution.y, 1.0);
	
	vec2 mg = raymarch(o, d, 1.2, time);
	float m = mg.x * wave_intensity;
	
	// Simple reddish 4-point gradient
	vec3 c = mix(
		mix(vec3(0.7, 0.2, 0.2), vec3(0.4, 0.1, 0.1), uv.x),
		mix(vec3(0.45, 0.1, 0.1), vec3(0.8, 0.3, 0.5), uv.x),
		uv.y
	);
	
	// Blend between color and white based on wave alpha
	c = mix(c, vec3(1.0), m);
	
	// Add dust
	if (show_dust) {
		c += get_dust(uv, vec2(2000.0), mg.y, time, resolution) * 0.3;
	}
	
	COLOR = vec4(c, 1.0);
}
