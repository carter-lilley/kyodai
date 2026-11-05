shader_type canvas_item;
render_mode unshaded;

#include "res://shaders/card/includes/card_common.gdshaderinc"

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_nearest;
uniform float fit_margin = 1.0;

void fragment() {
	vec2 group_size = card_size + vec2(fit_margin * 2.0);
	vec2 pixel_pos = UV * group_size - vec2(fit_margin);
	float dist = rounded_rect_sdf_pixels(pixel_pos, card_size, corner_radius_pixels);
	float aa_width = max(fwidth(pixel_pos.x) + fwidth(pixel_pos.y), 0.5);
	float coverage = 1.0 - smoothstep(-aa_width, 0.0, dist);

	vec4 contents = textureLod(screen_texture, SCREEN_UV, 0.0);
	if (contents.a > 0.0001) {
		contents.rgb /= contents.a;
	}
	vec4 modulate = COLOR;
	COLOR = vec4(contents.rgb * modulate.rgb, contents.a * coverage * modulate.a);
}
