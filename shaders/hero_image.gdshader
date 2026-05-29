shader_type canvas_item;

#include "res://shaders/card/includes/card_common.gdshaderinc"

uniform sampler2D game_texture : filter_linear, repeat_disable;
uniform vec2 hero_size = vec2(1920.0, 640.0);

uniform vec4 shadow_color : source_color = vec4(0.0, 0.0, 0.0, 0.7);
uniform float shadow_intensity : hint_range(0.0, 1.0) = 0.5;
uniform float corner_radius : hint_range(0.0, 0.5) = 0.06;

void fragment() {
	vec2 tex_size = vec2(textureSize(game_texture, 0));
	
	// Default to gray if no texture
	vec4 tex_color = vec4(0.5, 0.5, 0.5, 1.0);
	
	if (tex_size.x > 0.0 && tex_size.y > 0.0) {
		// COVER mode - scale shortest edge to longest edge, crop excess
		vec2 tex_uv = aspect_covered_uv(UV, hero_size, tex_size);
		tex_color = texture(game_texture, tex_uv);
	}
	
	// Rounded corners
	vec2 uv_centered = UV - 0.5;
	vec2 d = abs(uv_centered) - (vec2(1.0) - vec2(corner_radius));
	float dist = length(max(d, 0.0)) + min(d.x, d.y) - corner_radius;
	float edge_alpha = 1.0 - smoothstep(0.0, 0.01, dist);
	
	if (edge_alpha <= 0.0) {
		discard;
	}
	
	// Inner shadow
	float edge_dist = length(uv_centered);
	float inner_shadow = smoothstep(0.1, 0.5, edge_dist) * shadow_intensity;
	vec3 final_color = mix(tex_color.rgb, shadow_color.rgb, inner_shadow * shadow_color.a);
	
	COLOR = vec4(final_color, tex_color.a * edge_alpha);
}
