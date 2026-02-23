shader_type canvas_item;

uniform vec2 card_size = vec2(202.0, 270.0);
uniform float corner_radius_ratio = 0.06;  // 0.0 to 1.0, relative to card width

uniform float border_width_ratio = 0.04;  // 0.0 to 1.0, relative to card width
uniform float border_fade_in_ratio = 0.0;  // 0.0 to 1.0, relative to card width
uniform vec4 border_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform bool use_gradient = false;
uniform sampler2D gradient_texture;
uniform int gradient_direction = 0;

float rounded_rect_sdf(vec2 pos, vec2 size, float radius_ratio) {
	vec2 half_size = size * 0.5;
	float radius = radius_ratio * size.x;  // Radius as ratio of width
	vec2 d = abs(pos - half_size) - (half_size - radius);
	return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
}

void fragment() {
	vec2 pixel_pos = UV * card_size;
	
	float aa_width = fwidth(pixel_pos.x) + fwidth(pixel_pos.y);
	aa_width = max(aa_width, 0.5);
	
	// Convert ratios to pixels
	float corner_radius_pixels = corner_radius_ratio * card_size.x;
	float border_width_pixels = border_width_ratio * card_size.x;
	float border_fade_in_pixels = border_fade_in_ratio * card_size.x;
	
	float dist = rounded_rect_sdf(pixel_pos, card_size, corner_radius_ratio);
	
	vec4 final_color = vec4(0.0, 0.0, 0.0, 0.0);
	
	float total_border = border_width_pixels + border_fade_in_pixels;
	
	if (total_border > 0.0 && dist >= -total_border && dist <= 0.0) {
		float rel_d = (dist + total_border) / total_border;
		float inner_aa_alpha = smoothstep(0.0, aa_width / total_border, rel_d);
		
		float fade_in_factor = border_fade_in_pixels / total_border;
		float border_alpha = 1.0;
		
		if (fade_in_factor > 0.001) {
			border_alpha = min(border_alpha, rel_d / fade_in_factor);
		}
		border_alpha = clamp(border_alpha, 0.0, 1.0);
		
		float solid_border_end = (border_fade_in_pixels + border_width_pixels) / total_border;
		
		vec4 color;
		if (use_gradient) {
			float gradient_t;
			if (gradient_direction == 0) {
				gradient_t = UV.x;
			} else if (gradient_direction == 1) {
				gradient_t = UV.y;
			} else {
				gradient_t = (UV.x + UV.y) * 0.5;
			}
			color = texture(gradient_texture, vec2(gradient_t, 0.0));
		} else {
			color = border_color;
		}
		
		if (rel_d < solid_border_end) {
			final_color = vec4(color.rgb, color.a * border_alpha * inner_aa_alpha);
		} else {
			final_color = vec4(color.rgb, color.a * border_alpha);
		}
	}
	
	float edge_dist = rounded_rect_sdf(pixel_pos, card_size, corner_radius_ratio);
	float edge_alpha = 1.0 - smoothstep(-aa_width, 0.0, edge_dist);
	final_color.a *= edge_alpha;
	
	if (final_color.a <= 0.0) {
		discard;
	}
	
	COLOR = final_color;
}
