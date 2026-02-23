shader_type canvas_item;

uniform vec2 card_size = vec2(202.0, 270.0);
uniform float corner_radius_ratio = 0.06;  // 0.0 to 1.0, relative to card width

uniform bool hide_background = false;
uniform float badge_size_ratio = 0.16;  // Badge size as ratio of card width (was 32px at 202px width)
uniform vec2 badge_aspect_ratio = vec2(1.0, 1.0);  // Badge aspect ratio (width/height)
uniform float badge_inner_radius = 0.0;  // 0.0 to 1.0 for inner corner roundness
uniform vec4 badge_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float border_width_ratio = 0.0;  // Border width as ratio of card width

float rounded_rect_sdf(vec2 pos, vec2 size, float radius_ratio) {
	vec2 half_size = size * 0.5;
	float radius = radius_ratio * size.x;  // Radius as ratio of width
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
	
	vec4 final_color = vec4(0.0, 0.0, 0.0, 0.0);
	
	// Convert ratios to pixels
	float badge_size_pixels = badge_size_ratio * card_size.x;
	float border_width_pixels = border_width_ratio * card_size.x;
	
	float badge_width = badge_size_pixels * badge_aspect_ratio.x;
	float badge_height = badge_size_pixels * badge_aspect_ratio.y;
	
	if (pixel_pos.x < badge_width && pixel_pos.y < badge_height) {
		float dist_left = pixel_pos.x;
		float dist_top = pixel_pos.y;
		
		bool outside_badge = pixel_pos.x > badge_width || pixel_pos.y > badge_height;
		
		float alpha_left = smoothstep(-aa_width, 0.0, dist_left);
		float alpha_top = smoothstep(-aa_width, 0.0, dist_top);
		float bounds_alpha = outside_badge ? 0.0 : 1.0;
		
		float badge_alpha = min(min(alpha_left, alpha_top), bounds_alpha);
		
		if (badge_inner_radius > 0.0) {
			float min_dimension = min(badge_width, badge_height);
			float max_radius = max(0.0, min_dimension * 0.5 - border_width_pixels);
			float inner_radius = max_radius * clamp(badge_inner_radius, 0.0, 1.0);
			
			vec2 corner_center = vec2(badge_width - inner_radius, badge_height - inner_radius);
			bool in_corner_region = pixel_pos.x > badge_width - inner_radius && pixel_pos.y > badge_height - inner_radius;
			
			if (in_corner_region && inner_radius > 0.0) {
				float dist_from_center = length(pixel_pos - corner_center);
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
	
	float edge_dist = rounded_rect_sdf(pixel_pos, card_size, corner_radius_ratio);
	float edge_alpha = 1.0 - smoothstep(-aa_width, 0.0, edge_dist);
	final_color.a *= edge_alpha;
	
	if (final_color.a <= 0.0) {
		discard;
	}
	
	COLOR = final_color;
}
