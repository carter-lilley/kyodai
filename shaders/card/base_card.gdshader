shader_type canvas_item;

#include "res://shaders/card/includes/card_common.gdshaderinc"

uniform sampler2D game_texture : filter_linear, repeat_disable;
uniform float border_inset_ratio = 0.0;  // 0.0 to 1.0, relative to card width
uniform float glass_inset_ratio = 0.0;  // 0.0 to 1.0, relative to card width (additional inset from glass effect)
uniform float alpha = 1.0;  // Global alpha multiplier for fade animations
uniform int display_mode = 0;  // 0 = Standard, 1 = Transparent, 2 = Media Only

void fragment() {
	vec2 pixel_pos = UV * card_size;
	
	float aa_width = fwidth(pixel_pos.x) + fwidth(pixel_pos.y);
	aa_width = max(aa_width, 0.5);
	
	// Use shared shape parameters from MediaContainer
	// total_inset_pixels already includes border + glass insets
	float effective_border_inset = total_inset_pixels;
	
	// For glass inset calculation, derive glass pixels from the ratio
	float glass_inset_pixels = glass_inset_ratio * card_size.x;
	
	vec2 inner_size = card_size - vec2(effective_border_inset * 2.0);
	vec2 inner_offset = vec2(effective_border_inset);
	
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
		// Transparent / Media Only: smoothstep anti-aliasing on the edge
		edge_alpha = 1.0 - smoothstep(0.0, aa_width, dist);
		if (edge_alpha <= 0.0) {
			discard;
		}
	}
	
	// Calculate the inner edge (glass inset area) - clip the base card to this shape
	// Reuse glass_inset_pixels from earlier calculation
	vec2 glass_inner_size = card_size - vec2(glass_inset_pixels * 2.0);
	vec2 glass_inner_offset = vec2(glass_inset_pixels);
	
	// Calculate inner corner radius for glass inset
	float glass_inner_radius_pixels = max(0.0, corner_radius_ratio * min(card_size.x, card_size.y) / 2.0 - glass_inset_pixels);
	float glass_inner_radius_ratio = 0.0;
	if (min(glass_inner_size.x, glass_inner_size.y) > 0.0) {
		glass_inner_radius_ratio = glass_inner_radius_pixels / (min(glass_inner_size.x, glass_inner_size.y) / 2.0);
	}
	
	// Check if inside glass inset area
	vec2 glass_pixel_pos = pixel_pos - glass_inner_offset;
	float glass_sdf_dist = rounded_rect_sdf_ratio(glass_pixel_pos, glass_inner_size, glass_inner_radius_ratio);
	float glass_edge_alpha = 1.0 - smoothstep(-aa_width, 0.0, glass_sdf_dist);
	
	// If there's a glass inset, clip the base card to the inner shape
	if (glass_inset_ratio > 0.0 && glass_edge_alpha <= 0.0) {
		discard;
	}
	
	vec2 inner_pixel_pos = pixel_pos - inner_offset;
	vec2 inner_uv = inner_pixel_pos / inner_size;
	
	if (inner_uv.x < 0.0 || inner_uv.x > 1.0 || inner_uv.y < 0.0 || inner_uv.y > 1.0) {
		discard;
	}
	
	vec2 tex_size = vec2(textureSize(game_texture, 0));
	
	vec2 tex_uv = aspect_covered_uv(inner_uv, inner_size, tex_size);
	vec4 tex_color = texture(game_texture, tex_uv);
	
	// Combine edge_alpha with glass_edge_alpha to clip base card to glass inset shape
	float final_alpha = edge_alpha;
	if (glass_inset_ratio > 0.0) {
		final_alpha = min(edge_alpha, glass_edge_alpha);
	}
	
	tex_color.a *= final_alpha * alpha;
	COLOR = tex_color;
}
