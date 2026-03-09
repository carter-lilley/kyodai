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

// Exact spheroblast distort function
vec2 distort(vec2 p, float dist_param, float aspect)
{
	float d = length(p);
	float z = sqrt(dist_param + d * d * -dist_param);
	float r = atan(d, z) / 3.1415926535;
	float phi = atan(p.y, p.x);
	return vec2(r * cos(phi) * (1.0 / aspect) + 0.5, r * sin(phi) + 0.5);
}

vec2 spherical_distort(vec2 uv, float raw_distortion) {
	vec2 pixel_pos = uv * card_size;
	vec2 half_size = card_size * 0.5;
	
	// Calculate aspect ratio
	float aspect = card_size.x / card_size.y;
	
	// Convert to centered coordinates (like spheroblast: SCREEN_UV * 2.0 - 1.0)
	vec2 centered = (pixel_pos - half_size) / half_size;
	
	// Scale so that maximum distance is ~1.0 (corners of card)
	// The furthest point is at a corner: distance = sqrt(aspect² + 1) when aspect >= 1
	// We want to normalize so this equals 1.0
	float max_dist = sqrt(aspect * aspect + 1.0);
	centered = centered / max_dist;
	
	// Also apply aspect ratio adjustment (like spheroblast does)
	centered.x *= aspect;
	
	// Map distortion slider (0.0-1.0) to spheroblast distortion parameter
	// 0.0 = pinch (dist_param < 1.0), 0.5 = flat (1.0), 1.0 = bulge (> 1.0)
	float dist_param;
	if (raw_distortion < 0.5) {
		// Pinch: map 0.0-0.5 to 0.3-1.0
		dist_param = mix(0.3, 1.0, raw_distortion * 2.0);
	} else {
		// Bulge: map 0.5-1.0 to 1.0-1.8
		dist_param = mix(1.0, 1.8, (raw_distortion - 0.5) * 2.0);
	}
	
	// Apply spheroblast distortion
	vec2 distorted_uv = distort(centered, dist_param, aspect);
	
	return distorted_uv;
}

void fragment() {
	vec2 pixel_pos = UV * card_size;
	
	// Check if inside rounded card
	float dist = rounded_rect_sdf(pixel_pos, card_size, corner_radius_ratio);
	
	vec4 final_color;
	
	if (dist > 0.0) {
		final_color = vec4(0.0, 0.0, 0.0, 0.0);
	} else {
		vec2 warped_uv = spherical_distort(UV, distortion);
		
		// Clamp to prevent sampling outside texture
		warped_uv = clamp(warped_uv, 0.0, 1.0);
		
		vec4 tex_color = texture(game_texture, warped_uv);
		vec3 glass_tint = mix(tex_color.rgb, glass_color.rgb, glass_color.a);
		
		float aa_width = fwidth(pixel_pos.x) + fwidth(pixel_pos.y);
		float edge_alpha = 1.0 - smoothstep(-aa_width, 0.0, dist);
		
		final_color = vec4(glass_tint, tex_color.a * edge_alpha);
	}
	
	COLOR = final_color;
}
