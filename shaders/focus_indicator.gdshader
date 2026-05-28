shader_type canvas_item;

uniform vec2 shape_size = vec2(100.0, 100.0);
uniform float corner_radius_ratio = 0.0;
uniform float corner_radius_pixels = 0.0;  // Pre-calculated from MediaContainer for consistency
uniform vec4 border_color : source_color = vec4(1.0, 1.0, 1.0, 0.8);
uniform float border_width : hint_range(1.0, 20.0) = 6.0;
uniform bool debug_mode = false;
uniform float chase_speed : hint_range(0.0, 5.0) = 0.65;
uniform float gap_size : hint_range(0.0, 0.3) = 0.04;
uniform float fade_length : hint_range(0.0, 0.5) = 0.35;

// SDF using pre-calculated pixel radius (matches MediaContainer calculation exactly)
float rounded_rect_sdf_pixels(vec2 pos, vec2 size, float radius_pixels) {
	vec2 half_size = size * 0.5;
	float radius = clamp(radius_pixels, 0.0, min(half_size.x, half_size.y));
	vec2 d = abs(pos - half_size) - (half_size - vec2(radius));
	return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
}

// Legacy SDF using ratio (kept for backward compatibility)
float rounded_rect_sdf(vec2 pos, vec2 size, float radius_ratio) {
	vec2 half_size = size * 0.5;
	// 1.0 ratio = corners touch (half of smallest dimension)
	float radius = radius_ratio * min(size.x, size.y) / 2.0;
	vec2 d = abs(pos - half_size) - (half_size - vec2(radius));
	return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
}

// Simple angular position around the shape
// Returns 0-1 going clockwise from bottom-left
float get_angular_position(vec2 uv, vec2 size) {
	vec2 pixel_pos = uv * size;
	vec2 center = size * 0.5;
	
	// Calculate angle from center (-PI to PI)
	float angle = atan(pixel_pos.y - center.y, pixel_pos.x - center.x);
	
	// Convert to 0-1 range, clockwise, starting from bottom-left (-135 degrees or -3PI/4)
	// We want 0 at bottom-left, going clockwise
	float normalized = angle / (2.0 * 3.14159) + 0.5;  // 0 to 1, counter-clockwise from right
	
	// Flip to clockwise
	normalized = 1.0 - normalized;
	
	// Offset so 0 is at bottom-left
	normalized = fract(normalized + 0.375);  // 0.375 = 3/8, shifts to bottom-left
	
	return normalized;
}

void fragment() {
	vec2 pixel_pos = UV * shape_size;
	
	if (debug_mode) {
		COLOR = vec4(1.0, 0.0, 0.0, 1.0);
	} else {
		float aa_width = fwidth(pixel_pos.x) + fwidth(pixel_pos.y);
		aa_width = max(aa_width, 0.5);
		
		// Use pre-calculated pixel radius if available, otherwise calculate from ratio
		float dist;
		if (corner_radius_pixels > 0.0) {
			dist = rounded_rect_sdf_pixels(pixel_pos, shape_size, corner_radius_pixels);
		} else {
			dist = rounded_rect_sdf(pixel_pos, shape_size, corner_radius_ratio);
		}
		
		vec4 final_color = vec4(0.0, 0.0, 0.0, 0.0);
		
		if (border_width > 0.0 && dist >= -border_width && dist <= 0.0) {
			float rel_dist = (dist + border_width) / border_width;
			float inner_aa_alpha = smoothstep(0.0, aa_width / border_width, rel_dist);
			
			// Get angular position around the shape
			float angular_pos = get_angular_position(UV, shape_size);
			
			// The gap center moves around
			float gap_center = fract(TIME * chase_speed);
			
			// Calculate distance from gap center (wrapping around 0-1)
			float dist_from_gap = abs(angular_pos - gap_center);
			if (dist_from_gap > 0.5) {
				dist_from_gap = 1.0 - dist_from_gap;
			}
			
			// Calculate alpha
			float alpha_mod = 1.0;
			
			if (dist_from_gap < gap_size * 0.5) {
				alpha_mod = 0.0;
			} else if (dist_from_gap < gap_size * 0.5 + fade_length) {
				float fade_progress = (dist_from_gap - gap_size * 0.5) / fade_length;
				alpha_mod = smoothstep(0.0, 1.0, fade_progress);
			}
			
			float final_alpha = inner_aa_alpha * alpha_mod;
			
			final_color = vec4(border_color.rgb, border_color.a * final_alpha);
		}
		
		float edge_alpha = 1.0 - smoothstep(-aa_width, 0.0, dist);
		final_color.a *= edge_alpha;
		
		COLOR = final_color;
	}
	
	if (COLOR.a <= 0.001) {
		discard;
	}
}
