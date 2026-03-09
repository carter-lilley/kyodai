shader_type canvas_item;

uniform vec2 card_size = vec2(202.0, 270.0);
uniform float corner_radius_ratio = 0.06;
uniform sampler2D game_texture : filter_linear, repeat_disable;

// Glass parameters
uniform float distortion : hint_range(0.0, 1.0) = 0.5;  // 0.0 = pinch in, 0.5 = nothing, 1.0 = bulge out
uniform vec4 glass_color : source_color = vec4(0.2, 0.4, 1.0, 0.3);

float rounded_rect_sdf(vec2 pos, vec2 size, float radius_ratio) {
	vec2 half_size = size * 0.5;
	// 1.0 ratio = corners touch (half of smallest dimension)
	float radius = radius_ratio * min(size.x, size.y) / 2.0;
	vec2 d = abs(pos - half_size) - (half_size - vec2(radius));
	return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
}

vec2 spherical_distort(vec2 uv, float raw_distortion) {
	// Map 0.0-1.0 to -1.0 to 1.0
	// 0.0 = most pinch (1.0), 0.5 = nothing (0.0), 1.0 = most bulge (-1.0)
	float strength = raw_distortion * 2.0 - 1.0;  // Remap 0.0-1.0 to -1.0-1.0
	
	// Convert UV to centered coordinates (-0.5 to 0.5)
	vec2 centered = uv - 0.5;
	
	// Adjust for aspect ratio
	float aspect = card_size.x / card_size.y;
	centered.x *= aspect;
	
	// Calculate distance from center (circular)
	float dist = length(centered);
	
	// Calculate SDF distance for rounded rect edge detection
	vec2 pixel_pos = uv * card_size;
	float sdf_dist = rounded_rect_sdf(pixel_pos, card_size, corner_radius_ratio);
	// sdf_dist is negative inside, 0 at edge, positive outside
	// Map to 0-1 where 0 is center, 1 is edge
	float max_sdf = -min(card_size.x, card_size.y) * 0.5 * 0.5; // Approximate
	float edge_influence = 1.0 - smoothstep(max_sdf, 0.0, sdf_dist);
	
	// Apply spherical distortion based on strength
	// Positive strength = bulge out (fisheye)
	// Negative strength = pinch in (barrel)
	float distorted_dist;
	
	if (strength > 0.0) {
		// Bulge: push edges outward more
		float bulge_amount = strength * edge_influence * 0.3;
		distorted_dist = dist * (1.0 + bulge_amount);
	} else if (strength < 0.0) {
		// Pinch: pull edges inward more
		float pinch_amount = abs(strength) * edge_influence * 0.3;
		distorted_dist = dist * (1.0 - pinch_amount);
	} else {
		// No distortion
		distorted_dist = dist;
	}
	
	// Calculate angle
	float angle = atan(centered.y, centered.x);
	
	// Convert back to UV space
	vec2 distorted;
	distorted.x = (distorted_dist * cos(angle) / aspect) + 0.5;
	distorted.y = (distorted_dist * sin(angle)) + 0.5;
	
	return distorted;
}

void fragment() {
	vec2 pixel_pos = UV * card_size;
	
	// Check if inside rounded card
	float dist = rounded_rect_sdf(pixel_pos, card_size, corner_radius_ratio);
	
	vec4 final_color;
	
	if (dist > 0.0) {
		// Outside card - transparent
		final_color = vec4(0.0, 0.0, 0.0, 0.0);
	} else {
		// Apply spherical distortion to UV coordinates
		vec2 warped_uv = spherical_distort(UV, distortion);
		
		// Clamp UV to valid range
		warped_uv = clamp(warped_uv, 0.0, 1.0);
		
		// Sample the game texture with warping
		vec4 tex_color = texture(game_texture, warped_uv);
		
		// Apply glass tint overlay (always at full opacity)
		vec3 glass_tint = mix(tex_color.rgb, glass_color.rgb, glass_color.a);
		
		// Calculate edge alpha for smooth corners
		float aa_width = fwidth(pixel_pos.x) + fwidth(pixel_pos.y);
		aa_width = max(aa_width, 0.5);
		float edge_alpha = 1.0 - smoothstep(-aa_width, 0.0, dist);
		
		// Always use full opacity (1.0)
		final_color = vec4(glass_tint, tex_color.a * edge_alpha);
	}
	
	COLOR = final_color;
}
