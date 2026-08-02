shader_type canvas_item;

#include "res://shaders/card/includes/card_common.gdshaderinc"

uniform sampler2D game_texture : filter_linear, repeat_disable;
uniform float border_inset_ratio = 0.0;  // 0.0 to 1.0, relative to card width
uniform float glass_inset_ratio = 0.0;  // 0.0 to 1.0, relative to card width (additional inset from glass effect)
uniform float alpha = 1.0;  // Global alpha multiplier for fade animations

void fragment() {
	vec2 pixel_pos = UV * card_size;
	
	float aa_width = fwidth(pixel_pos.x) + fwidth(pixel_pos.y);
	aa_width = max(aa_width, 0.5);
	
	// The media area is inset by the total of border + glass insets.
	// total_inset_pixels (from MediaContainer) already combines both.
	vec2 inner_size = card_size - vec2(total_inset_pixels * 2.0);
	vec2 inner_offset = vec2(total_inset_pixels);
	
	// Safety: extreme insets could collapse the inner area.
	if (inner_size.x <= 0.0 || inner_size.y <= 0.0) {
		discard;
	}
	
	// Calculate the outer edge (base card shape)
	// Use shared corner_radius_pixels from MediaContainer for consistent rounding
	float dist = rounded_rect_sdf_pixels(pixel_pos, card_size, corner_radius_pixels);
	
	float edge_alpha;
	if (display_mode == 0) {
		// Standard mode: hard edge — parent panel provides anti-aliasing
		if (dist > 0.0) {
			discard;
		}
		edge_alpha = 1.0;
	} else {
		// Fade inward so anti-aliasing stays within card bounds (parent clips children)
		edge_alpha = 1.0 - smoothstep(-aa_width, 0.0, dist);
		if (edge_alpha <= 0.0) {
			discard;
		}
	}
	
	// Calculate the inner edge (media area after border + glass insets)
	float inner_radius_pixels = max(0.0, corner_radius_pixels - total_inset_pixels);
	float inner_radius_ratio = 0.0;
	if (min(inner_size.x, inner_size.y) > 0.0) {
		inner_radius_ratio = inner_radius_pixels / (min(inner_size.x, inner_size.y) / 2.0);
	}
	
	vec2 inner_pixel_pos = pixel_pos - inner_offset;
	float inner_sdf_dist = rounded_rect_sdf_ratio(inner_pixel_pos, inner_size, inner_radius_ratio);
	float inner_edge_alpha = 1.0 - smoothstep(-aa_width, 0.0, inner_sdf_dist);
	
	// Clip the base card to the inset media shape
	if (total_inset_pixels > 0.0 && inner_edge_alpha <= 0.0) {
		discard;
	}
	
	vec2 inner_uv = inner_pixel_pos / inner_size;
	
	// Use the precomputed UV transform from MediaContainer. The transform maps
	// inner media UV -> texture UV.
	vec2 tex_uv = inner_uv * uv_transform_scale + uv_transform_offset;
	vec4 tex_color = texture(game_texture, tex_uv);
	
	// Combine outer edge alpha with inner inset alpha
	float final_alpha = edge_alpha;
	if (total_inset_pixels > 0.0) {
		final_alpha = min(edge_alpha, inner_edge_alpha);
	}
	
	tex_color.a *= final_alpha * alpha;
	COLOR = tex_color;
}
