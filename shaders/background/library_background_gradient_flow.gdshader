shader_type canvas_item;

// Gradient Flow - two warped gradient layers flowing via noise-driven rotation
// Ported from "Gradient Flow" by inigo quilez - iq/2014
// License Creative Commons Attribution-NonCommercial-ShareAlike 3.0 Unported License.

uniform float time_scale : hint_range(0.0, 2.0, 0.05) = 1.0;
uniform float rotation_speed : hint_range(0.0, 1.0, 0.01) = 0.1;
uniform float rotation_amount : hint_range(0.0, 1440.0, 10.0) = 720.0;
uniform float wave_frequency : hint_range(0.5, 20.0, 0.1) = 5.0;
uniform float wave_amplitude : hint_range(1.0, 100.0, 1.0) = 30.0;
uniform float wave_speed : hint_range(0.0, 10.0, 0.1) = 2.0;
uniform vec4 layer1_color_a : source_color = vec4(0.957, 0.804, 0.623, 1.0);
uniform vec4 layer1_color_b : source_color = vec4(0.192, 0.384, 0.933, 1.0);
uniform vec4 layer2_color_a : source_color = vec4(0.910, 0.510, 0.800, 1.0);
uniform vec4 layer2_color_b : source_color = vec4(0.350, 0.710, 0.953, 1.0);
uniform float opacity : hint_range(0.0, 1.0, 0.05) = 1.0;

mat2 rot(float a) {
	float s = sin(a);
	float c = cos(a);
	return mat2(vec2(c, -s), vec2(s, c));
}

vec2 flow_hash(vec2 p) {
	p = vec2(dot(p, vec2(2127.1, 81.17)), dot(p, vec2(1269.5, 283.37)));
	return fract(sin(p) * 43758.5453);
}

float flow_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);

	vec2 u = f * f * (3.0 - 2.0 * f);

	float n = mix(mix(dot(-1.0 + 2.0 * flow_hash(i + vec2(0.0, 0.0)), f - vec2(0.0, 0.0)),
						dot(-1.0 + 2.0 * flow_hash(i + vec2(1.0, 0.0)), f - vec2(1.0, 0.0)), u.x),
					mix(dot(-1.0 + 2.0 * flow_hash(i + vec2(0.0, 1.0)), f - vec2(0.0, 1.0)),
						dot(-1.0 + 2.0 * flow_hash(i + vec2(1.0, 1.0)), f - vec2(1.0, 1.0)), u.x), u.y);
	return 0.5 + 0.5 * n;
}

void fragment() {
	vec2 res = 1.0 / SCREEN_PIXEL_SIZE;
	vec2 uv = FRAGCOORD.xy / res;
	float ratio = res.x / res.y;
	float t = TIME * time_scale;

	vec2 tuv = uv - 0.5;

	// Rotate with noise
	float degree = flow_noise(vec2(t * rotation_speed, tuv.x * tuv.y));

	tuv.y *= 1.0 / ratio;
	tuv *= rot(radians((degree - 0.5) * rotation_amount + 180.0));
	tuv.y *= ratio;

	// Wave warp with sin
	float speed = t * wave_speed;
	tuv.x += sin(tuv.y * wave_frequency + speed) / wave_amplitude;
	tuv.y += sin(tuv.x * wave_frequency * 1.5 + speed) / (wave_amplitude * 0.5);

	// Draw the gradient layers
	float grad_x = (tuv * rot(radians(-5.0))).x;
	vec3 layer1 = mix(layer1_color_a.rgb, layer1_color_b.rgb, smoothstep(-0.3, 0.2, grad_x));
	vec3 layer2 = mix(layer2_color_a.rgb, layer2_color_b.rgb, smoothstep(-0.3, 0.2, grad_x));

	// Original: smoothstep(0.5, -0.3, tuv.y) — rewritten with ascending edges
	// (identical result, avoids undefined behavior from reversed edges)
	vec3 col = mix(layer1, layer2, 1.0 - smoothstep(-0.3, 0.5, tuv.y));

	COLOR = vec4(col, opacity);
}
