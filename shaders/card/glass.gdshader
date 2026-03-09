shader_type canvas_item;

uniform vec2 card_size = vec2(202.0, 270.0);
uniform float corner_radius_ratio = 0.06;
uniform sampler2D game_texture : filter_linear, repeat_disable;

// Glass parameters
uniform float distortion : hint_range(0.0, 1.0) = 0.5;  // 0.0 = pinch in, 0.5 = nothing, 1.0 = bulge out
uniform vec4 glass_color : source_color = vec4(0.2, 0.4, 1.0, 0.3);

float rounded_rect_sdf(vec2 pos, vec2 size, float radius_ratio) {
	vec2 half_size = size * 0.5;
	float radius = radius_ratio * min(size.x, size.y) / 2.0;
	vec2 d = abs(pos - half_size) - (half_size - vec2(radius));
	return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
}

vec2 spherical_distort(vec2 uv, float raw_distortion) {
	// Convert UV to centered coordinates (-0.5 to 0.5)
	vec2 centered = uv - 0.5;
	
	// Adjust for aspect ratio
	float aspect = card_size.x / card_size.y;
	centered.x *= aspect;
	
	// Calculate normalized distance from center (0 at center, ~0.7 at corners)
	float dist = length(centered);
	
	// Map distortion slider to spheroblast parameter
	// 0.0 = pinch (barrel): small distortion value
	// 0.5 = flat: distortion = 1.0 (no effect)
	// 1.0 = bulge (fisheye): large distortion value
	float dist_param;
	if (raw_distortion < 0.5) {
		// Pinch: 0.0 -> 0.5 maps to 0.1 -> 1.0
		dist_param = mix(0.1, 1.0, raw_distortion * 2.0);
	} else {
		// Bulge: 0.5 -> 1.0 maps to 1.0 -> 3.0
		dist_param = mix(1.0, 3.0, (raw_distortion - 0.5) * 2.0);
	}
	
	// Spheroblast spherical projection formula
	// Scale dist to make effect more pronounced
	float d = dist * 2.5;
	
	float z = sqrt(dist_param + d * d * -dist_param);
	float r = atan(d, z) / 3.14159265359;
	
	// Calculate angle
	float angle = atan(centered.y, centered.x);
	
	// Convert back to UV coordinates
	vec2 distorted;
	distorted.x = (r * cos(angle) / aspect) + 0.5;
	distorted.y = (r * sin(angle)) + 0.5;
	
	return distorted;
}

void fragment() {
	vec2 pixel_pos = UV * card_size;
	
	// Check if inside rounded card (SDF is for clipping, not distortion)
	float dist = rounded_rect_sdf(pixel_pos, card_size, corner_radius_ratio);
	
	vec4 final_color;
	
	if (dist > 0.0) {
		// Outside card - transparent
		final_color = vec4(0.0, 0.0, 0.0, 0.0);
	} else {
		// Apply spherical distortion to entire card
		vec2 warped_uv = spherical_distort(UV, distortion);
		
		// Sample the game texture with warping
		vec4 tex_color = texture(game_texture, warped_uv);
		
		// Apply glass tint overlay
		vec3 glass_tint = mix(tex_color.rgb, glass_color.rgb, glass_color.a);
		
		// Calculate edge alpha for smooth corners
		float aa_width = fwidth(pixel_pos.x) + fwidth(pixel_pos.y);
		float edge_alpha = 1.0 - smoothstep(-aa_width, 0.0, dist);
		
		final_color = vec4(glass_tint, tex_color.a * edge_alpha);
	}
	
	COLOR = final_color;
}
