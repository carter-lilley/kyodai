shader_type canvas_item;

uniform vec2 card_size = vec2(202.0, 270.0);
uniform float corner_radius_pixels = 12.0;
uniform sampler2D game_texture : filter_linear, repeat_disable;

float rounded_rect_sdf(vec2 pos, vec2 size, float radius) {
	vec2 half_size = size * 0.5;
	vec2 d = abs(pos - half_size) - (half_size - radius);
	return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
}

vec2 aspect_covered_uv(vec2 uv, vec2 card, vec2 tex) {
	float card_aspect = card.x / card.y;
	float tex_aspect = tex.x / tex.y;
	
	vec2 scale;
	if (card_aspect > tex_aspect) {
		scale = vec2(1.0, tex_aspect / card_aspect);
	} else {
		scale = vec2(card_aspect / tex_aspect, 1.0);
	}
	
	return (uv - 0.5) * scale + 0.5;
}

void fragment() {
	vec2 pixel_pos = UV * card_size;
	
	float aa_width = fwidth(pixel_pos.x) + fwidth(pixel_pos.y);
	aa_width = max(aa_width, 0.5);
	
	float dist = rounded_rect_sdf(pixel_pos, card_size, corner_radius_pixels);
	float edge_alpha = 1.0 - smoothstep(-aa_width, 0.0, dist);
	
	if (edge_alpha <= 0.0) {
		discard;
	}
	
	vec2 tex_size = vec2(textureSize(game_texture, 0));
	vec2 tex_uv = aspect_covered_uv(UV, card_size, tex_size);
	vec4 tex_color = texture(game_texture, tex_uv);
	
	tex_color.a *= edge_alpha;
	COLOR = tex_color;
}
