shader_type canvas_item;

// PSP Classic Wave - Ported from Shadertoy
// https://www.shadertoy.com/view/ddV3DK by ParkingLotGames
// License: MIT

// Single user color - top and bottom gradient colors are derived from this
uniform vec4 wave_color : source_color = vec4(0.04, 0.69, 0.87, 1.0);

uniform float time_scale : hint_range(0.0, 2.0) = 1.0;
uniform float frequency : hint_range(1.0, 10.0) = 4.29;
uniform float outer_amplitude : hint_range(0.0, 2.0) = 0.5;
uniform float inner_amplitude : hint_range(0.0, 1.0) = 0.18;
uniform float outer_speed : hint_range(0.0, 0.2) = 0.044;
uniform float inner_speed : hint_range(0.0, 0.2) = 0.064;

// Original color ratio for deriving gradient from single color
// Top was (0.04, 0.19, 0.54), Bottom was (0.04, 0.69, 0.87)
const vec3 COLOR_RATIO = vec3(1.0, 0.275, 0.621);

void fragment() {
    vec2 uv = UV;
    float time = TIME * time_scale;
    
    // Derive gradient colors from single user color
    vec3 bottom_color = wave_color.rgb;
    vec3 top_color = wave_color.rgb * COLOR_RATIO;
    
    vec3 white = vec3(1.0, 1.0, 1.0);
    
    float top_outer_wave = sin((uv.x + (time * (outer_speed + (0.0025 * 1.0)))) * frequency) * outer_amplitude;
    float bottom_outer_wave = sin((uv.x + (time * (outer_speed + (0.0025 * 20.0)))) * frequency) * outer_amplitude;
    float top_inner_wave = sin((uv.x + (time * (inner_speed + (0.0025 * 8.0)))) * frequency) * inner_amplitude;
    float bottom_inner_wave = sin((uv.x + (time * (inner_speed + (0.0025 * 40.0)))) * frequency) * inner_amplitude;
    
    float top_outer_wave_falloff = top_outer_wave;
    float bottom_outer_wave_falloff = bottom_outer_wave;
    float top_inner_wave_falloff = top_inner_wave;
    float bottom_inner_wave_falloff = bottom_inner_wave;
    
    top_outer_wave += 1.0 - (1.0 - uv.y) * 6.0;
    bottom_outer_wave += 1.0 - (uv.y * 6.0);
    top_inner_wave += 1.0 - (uv.y) * 2.5;
    bottom_inner_wave += 1.0 - (1.0 - uv.y) * 2.5;
    
    top_outer_wave_falloff += 1.0 - (1.0 - uv.y - 0.2) * 6.0;
    bottom_outer_wave_falloff += 1.0 - ((uv.y - 0.2) * 6.0);
    top_inner_wave_falloff += 1.0 - ((uv.y - 0.1) * 2.2);
    bottom_inner_wave_falloff += 1.0 - (((1.0 - uv.y - 0.1)) * 2.2);
    
    float wave1 = 1.0 - smoothstep(0.0, 0.025, top_outer_wave);
    float wave2 = 1.0 - smoothstep(0.0, 0.025, bottom_outer_wave);
    float wave3 = 1.0 - smoothstep(0.0, 0.025, top_inner_wave);
    float wave4 = 1.0 - smoothstep(0.0, 0.025, bottom_inner_wave);
    
    float wave1_falloff = 1.0 - smoothstep(0.0, 2.0, top_outer_wave_falloff);
    float wave2_falloff = 1.0 - smoothstep(0.0, 2.0, bottom_outer_wave_falloff);
    float wave3_falloff = 1.0 - smoothstep(0.0, 1.0, top_inner_wave_falloff);
    float wave4_falloff = 1.0 - smoothstep(0.0, 1.0, bottom_inner_wave_falloff);
    
    wave1 -= wave1_falloff;
    wave2 -= wave2_falloff;
    wave3 -= wave3_falloff;
    wave4 -= wave4_falloff;
    
    wave1 = clamp(wave1, 0.0, 1.0);
    wave2 = clamp(wave2, 0.0, 1.0);
    wave3 = clamp(wave3, 0.0, 1.0);
    wave4 = clamp(wave4, 0.0, 1.0);
    
    float wave = wave1 + wave2 + wave3 + wave4;
    vec4 wave_contribution = vec4(white, wave);
    vec4 background = vec4(mix(bottom_color, top_color, uv.y), 1.0);
    
    COLOR = mix(background, wave_contribution, wave);
}
