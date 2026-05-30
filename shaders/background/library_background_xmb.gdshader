shader_type canvas_item;

// PS3 XMB Background Shader Port - Self-Contained Version
// Based on: https://www.shadertoy.com/view/tXy3DK by int_45h
// Ported to Godot 4.x

uniform float time_scale : hint_range(0.0, 2.0) = 1.0;
uniform bool show_dust = true;
uniform float wave_intensity : hint_range(0.0, 5.0) = 0.812;
uniform float star_threshold : hint_range(0.9, 1.0) = 1.0;
uniform float wave_thickness : hint_range(0.5, 5.0) = 0.5;
uniform float wave_amplitude : hint_range(0.0, 3.0) = 0.324;
uniform float wave_vertical_offset : hint_range(-1.0, 1.0) = -0.2;
uniform sampler2D noise_texture : filter_linear, repeat_enable;

// Single user color - background gradient and dust are derived from this
uniform vec4 wave_color : source_color = vec4(0.04, 0.69, 0.87, 1.0);

// Color ratio for deriving gradient from single color (matching XMB Classic)
const vec3 COLOR_RATIO = vec3(1.0, 0.275, 0.621);

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

// SDF for the wave - Vita-style broad, soft waves
float sdf(vec3 p, float time) {
	// Scale down for broader waves
	vec3 wp = p * 0.5;
	
	// Multiple parallel wave bands (Vita has several flowing ribbons)
	// Distributed vertically for full-screen coverage
	float wave1 = sin(wp.x * 0.8 + time * 0.3) * 0.5;
	float wave2 = sin(wp.x * 0.6 + wp.z * 0.3 + time * 0.25 + 1.0) * 0.4;
	float wave3 = sin(wp.x * 0.4 + time * 0.2 + 2.0) * 0.3;
	float wave4 = sin(wp.x * 0.5 + wp.y * 0.2 + time * 0.35 + 0.5) * 0.35;  // Vertical variation
	
	// Combine waves
	float combined_wave = wave1 + wave2 + wave3 + wave4;
	
	// Soft SDF - returns distance from wave center with smooth falloff
	// Not using abs() - instead we get signed distance for soft edges
	float wave_height = combined_wave * 1.5 * wave_amplitude;
	// Center the wave vertically with offset
	float dist = dot(wp, normalize(vec3(0.0, 1.0, 0.05))) + wave_height + wave_vertical_offset;
	
	// Return soft distance (positive = outside wave, negative = inside)
	return dist;
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

// Raymarching with density accumulation for soft Vita-style waves
vec2 raymarch(vec3 o, vec3 d, float omega, float time) {
	float t = 0.0;
	float density = 0.0;
	float step_size = 0.1;
	float total_density = 0.0;
	int samples = 0;
	
	for (int i = 0; i < 80; i++) {
		vec3 p = o + d * t;
		float dist = sdf(p, time);
		
		// Accumulate density based on how close we are to the wave center
		// Smooth falloff for soft, broad waves
		float sample_density = smoothstep(wave_thickness, 0.0, abs(dist));
		
		total_density += sample_density;
		samples++;
		
		t += step_size;
		if (t >= MAX_DIST) break;
	}
	
	// Average density
	float avg_density = total_density / float(samples);
	
	// Calculate glow based on density (brighter where wave is denser)
	float glow = avg_density * 3.0;
	
	return vec2(avg_density, glow);
}

void fragment() {
	vec2 resolution = 1.0 / SCREEN_PIXEL_SIZE;
	vec2 uv = UV;
	vec2 U = uv * resolution;
	
	float time = TIME * time_scale;
	
	vec3 o = vec3(0.0);
	vec3 d = vec3((U - 0.5 * resolution) / resolution.y, 1.0);
	
	vec2 mg = raymarch(o, d, 1.2, time);
	float wave_density = mg.x;
	float wave_glow = mg.y;
	
	// Derive gradient colors from single user color
	vec3 bottom_color = wave_color.rgb;
	vec3 top_color = wave_color.rgb * COLOR_RATIO;
	
	// Self-contained background gradient
	vec3 final_color = mix(top_color, bottom_color, uv.y);
	
	// Vita-style: broad, soft waves with bright white center
	if (wave_density > 0.0) {
		// Power curve for brighter center, softer edges
		float brightness = pow(wave_density, 0.7) * wave_intensity;
		// Add glow falloff
		brightness *= (1.0 + wave_glow * 0.5);
		final_color += vec3(1.0) * brightness;  // White waves
	}
	
	// Add dust particles (subtle, derived from user color)
	if (show_dust) {
		float dust = get_dust(uv, vec2(2000.0), mg.y, time, resolution);
		vec3 derived_dust_color = wave_color.rgb * 0.6;
		final_color += derived_dust_color * dust * 0.3;
	}
	
	// Clamp and output opaque
	final_color = clamp(final_color, vec3(0.0), vec3(1.0));
	COLOR = vec4(final_color, 1.0);
}
