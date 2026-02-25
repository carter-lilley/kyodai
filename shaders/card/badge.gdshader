shader_type canvas_item;

uniform vec2 card_size = vec2(202.0, 270.0);
uniform float corner_radius_ratio = 0.06;

uniform bool hide_background = false;
uniform float badge_size_ratio = 0.16;
uniform vec2 badge_aspect_ratio = vec2(1.0, 1.0);
uniform float badge_inner_radius = 0.0;
uniform vec4 badge_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float border_width_ratio = 0.0;
uniform float border_inset_pixels = 0.0;
uniform int badge_type = 0; // 0 = corner badge, 1 = top bar

// Safe zone uniforms (set by GameCard for debugging)
uniform bool show_safe_zone = false;
uniform vec4 safe_zone = vec4(0.0, 0.0, 0.0, 0.0); // x, y, width, height in pixels

float rounded_rect_sdf(vec2 pos, vec2 size, float radius_ratio) {
	vec2 half_size = size * 0.5;
	float radius = radius_ratio * size.x;
	vec2 d = abs(pos - half_size) - (half_size - radius);
	return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
}

void fragment() {
	if (hide_background) {
		discard;
	}
	
	vec2 pixel_pos = UV * card_size;
	float aa_width = fwidth(pixel_pos.x) + fwidth(pixel_pos.y);
	aa_width = max(aa_width, 0.5);
	
	// Effective corner radius at inset position
	float effective_corner_radius = max(0.0, corner_radius_ratio * card_size.x - border_inset_pixels);
	float effective_corner_radius_ratio = (card_size.x > 0.0) ? (effective_corner_radius / card_size.x) : 0.0;
	
	vec4 final_color = vec4(0.0, 0.0, 0.0, 0.0);
	
	float badge_size_pixels = badge_size_ratio * card_size.x;
	float border_width_pixels = border_width_ratio * card_size.x;
	
	float badge_width = badge_size_pixels * badge_aspect_ratio.x;
	float badge_height = badge_size_pixels * badge_aspect_ratio.y;
	
	// Draw badge based on type
	if (badge_type == 0) {
		// Corner badge (original implementation)
		// Offset by border_inset_pixels for inset positioning
		vec2 badge_origin = vec2(border_inset_pixels, border_inset_pixels);
		vec2 local_pos = pixel_pos - badge_origin;
		
		if (local_pos.x >= 0.0 && local_pos.x < badge_width && local_pos.y >= 0.0 && local_pos.y < badge_height) {
			float dist_left = local_pos.x;
			float dist_top = local_pos.y;
			bool outside_badge = local_pos.x >= badge_width || local_pos.y >= badge_height;
			float alpha_left = smoothstep(-aa_width, 0.0, dist_left);
			float alpha_top = smoothstep(-aa_width, 0.0, dist_top);
			float bounds_alpha = outside_badge ? 0.0 : 1.0;
			float badge_alpha = min(min(alpha_left, alpha_top), bounds_alpha);
			
		if (badge_inner_radius > 0.0) {
			float min_dimension = min(badge_width, badge_height);
			float max_radius = min_dimension * 0.5;
			float inner_radius = max_radius * clamp(badge_inner_radius, 0.0, 1.0);
			vec2 corner_center = vec2(badge_width - inner_radius, badge_height - inner_radius);
			bool in_corner_region = local_pos.x > badge_width - inner_radius && local_pos.y > badge_height - inner_radius;
				
				if (in_corner_region && inner_radius > 0.0) {
					float dist_from_center = length(local_pos - corner_center);
					if (dist_from_center > inner_radius) {
						badge_alpha = 0.0;
					} else {
						float edge_alpha = 1.0 - smoothstep(inner_radius - aa_width, inner_radius, dist_from_center);
						badge_alpha *= edge_alpha;
					}
				}
			}
			
			final_color = vec4(badge_color.rgb, badge_color.a * badge_alpha);
		}
	} else {
		// Top bar badge - full width at top
		float bar_height = badge_size_pixels;
		float card_width_pixels = card_size.x - border_inset_pixels * 2.0;
		// Offset by border_inset_pixels
		float local_y = pixel_pos.y - border_inset_pixels;
		
		if (local_y >= 0.0 && local_y < bar_height && pixel_pos.x >= border_inset_pixels && pixel_pos.x < card_width_pixels + border_inset_pixels) {
			// Top edge fade
			float alpha_top = smoothstep(-aa_width, 0.0, local_y);
			// Bottom edge fade
			float alpha_bottom = 1.0 - smoothstep(bar_height - aa_width, bar_height, local_y);
			float badge_alpha = min(alpha_top, alpha_bottom);
			
			// Apply rounded corners to bottom of bar
			if (badge_inner_radius > 0.0) {
				float max_radius = max(0.0, bar_height * 0.5);
				float corner_radius = max_radius * clamp(badge_inner_radius, 0.0, 1.0);
				
				float local_x = pixel_pos.x - border_inset_pixels;
				
				// Bottom left corner
				vec2 bl_corner_center = vec2(corner_radius, bar_height - corner_radius);
				// Bottom right corner
				vec2 br_corner_center = vec2(card_width_pixels - corner_radius, bar_height - corner_radius);
				
				// Check if in bottom left corner region
				if (local_x < corner_radius && local_y > bar_height - corner_radius) {
					float dist_bl = length(vec2(local_x, local_y) - bl_corner_center);
					if (dist_bl > corner_radius) {
						badge_alpha = 0.0;
					} else {
						float edge_alpha = 1.0 - smoothstep(corner_radius - aa_width, corner_radius, dist_bl);
						badge_alpha *= edge_alpha;
					}
				}
				
				// Check if in bottom right corner region
				if (local_x > card_width_pixels - corner_radius && local_y > bar_height - corner_radius) {
					float dist_br = length(vec2(local_x, local_y) - br_corner_center);
					if (dist_br > corner_radius) {
						badge_alpha = 0.0;
					} else {
						float edge_alpha = 1.0 - smoothstep(corner_radius - aa_width, corner_radius, dist_br);
						badge_alpha *= edge_alpha;
					}
				}
			}
			
			final_color = vec4(badge_color.rgb, badge_color.a * badge_alpha);
		}
	}
	
	// Use effective corner radius for edge clipping
	float edge_dist = rounded_rect_sdf(pixel_pos, card_size, effective_corner_radius_ratio);
	float edge_alpha = 1.0 - smoothstep(-aa_width, 0.0, edge_dist);
	final_color.a *= edge_alpha;
	
	// Debug: overlay safe zone in magenta
	if (show_safe_zone && safe_zone.z > 0.0 && safe_zone.w > 0.0) {
		if (pixel_pos.x >= safe_zone.x && pixel_pos.x <= safe_zone.x + safe_zone.z &&
			pixel_pos.y >= safe_zone.y && pixel_pos.y <= safe_zone.y + safe_zone.w) {
			// Blend magenta overlay
			final_color = mix(final_color, vec4(1.0, 0.0, 1.0, 0.6), 0.6);
		}
	}
	
	if (final_color.a <= 0.0) {
		discard;
	}
	
	COLOR = final_color;
}