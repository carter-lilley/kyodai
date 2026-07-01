shader_type canvas_item;

#include "res://shaders/card/includes/card_common.gdshaderinc"

uniform sampler2D game_texture : filter_linear, repeat_disable;
uniform float alpha = 1.0;

void fragment() {
	vec2 pixel_pos = UV * card_size;

	float aa_width = fwidth(pixel_pos.x) + fwidth(pixel_pos.y);
	aa_width = max(aa_width, 0.5);

	// Outer media shape
	float dist = rounded_rect_sdf_pixels(pixel_pos, card_size, corner_radius_pixels);
	float edge_alpha = 1.0 - smoothstep(-aa_width, 0.0, dist);
	if (edge_alpha <= 0.0) {
		discard;
	}

	vec2 tex_size = vec2(textureSize(game_texture, 0));
	vec2 tex_uv = aspect_covered_uv(UV, card_size, tex_size);
	vec4 tex_color = texture(game_texture, tex_uv);

	tex_color.a *= edge_alpha * alpha;
	COLOR = tex_color;
}
