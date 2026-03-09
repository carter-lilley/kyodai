shader_type canvas_item;

uniform vec2 card_size = vec2(202.0, 270.0);
uniform float corner_radius_ratio = 0.06;
uniform sampler2D game_texture : filter_linear, repeat_disable;

// Glass parameters  
uniform float distortion : hint_range(0.0, 1.0) = 0.5;
uniform vec4 glass_color : source_color = vec4(0.2, 0.4, 1.0, 0.3);

// Specular parameters
uniform float specular_power : hint_range(1.0, 128.0) = 32.0;
uniform float specular_intensity : hint_range(0.0, 2.0) = 0.8;
uniform float light_angle : hint_range(0.0, 360.0) = 45.0;
uniform float light_height : hint_range(0.0, 1.0) = 0.5;

// Bounce light parameters
uniform float bounce_intensity : hint_range(0.0, 1.0) = 0.4;
uniform float bounce_softness : hint_range(1.0, 8.0) = 3.0;

// Rim light parameters
uniform float rim_intensity : hint_range(0.0, 2.0) = 1.0;
uniform float rim_sharpness : hint_range(2.0, 10.0) = 5.0;

float rounded_rect_sdf(vec2 pos, vec2 size, float radius_ratio) {
	vec2 half_size = size * 0.5;
	float radius = radius_ratio * min(size.x, size.y) / 2.0;
	vec2 d = abs(pos - half_size) - (half_size - vec2(radius));
	return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
}

vec3 calculate_dome_normal(vec2 pos, vec2 size) {
	// Calculate fake 3D dome normal for spherical specular highlights
	vec2 half_size = size * 0.5;
	vec2 from_center = pos - half_size;
	
	// Normalize to -1 to 1 range
	float max_dist = min(size.x, size.y) * 0.5;
	vec2 normalized_pos = from_center / max_dist;
	
	// Calculate distance from center (clamped to hemisphere bounds)
	float r = length(normalized_pos);
	r = min(r, 0.99); // Clamp to avoid sqrt(negative)
	
	// Hemisphere height: z = sqrt(1 - r^2)
	// This gives us the 3D position on a unit hemisphere
	float z = sqrt(1.0 - r * r);
	
	// The normal of a hemisphere at (x, y, z) is just the normalized position
	return normalize(vec3(normalized_pos.x, normalized_pos.y, z));
}

vec2 distort(vec2 p, float dist_param, float aspect) {
	float d = length(p);
	float z = sqrt(dist_param + d * d * -dist_param);
	float r = atan(d, z) / 3.1415926535;
	float phi = atan(p.y, p.x);
	return vec2(r * cos(phi) * (1.0 / aspect) + 0.5, r * sin(phi) + 0.5);
}

vec2 spherical_distort(vec2 uv, float raw_distortion) {
	vec2 pixel_pos = uv * card_size;
	vec2 half_size = card_size * 0.5;
	float aspect = card_size.x / card_size.y;
	vec2 centered = (pixel_pos - half_size) / half_size;
	float max_dist = sqrt(aspect * aspect + 1.0);
	centered = centered / max_dist;
	centered.x *= aspect;
	
	float dist_param;
	if (raw_distortion < 0.5) {
		dist_param = mix(0.3, 1.0, raw_distortion * 2.0);
	} else {
		dist_param = mix(1.0, 1.8, (raw_distortion - 0.5) * 2.0);
	}
	
	return distort(centered, dist_param, aspect);
}

void fragment() {
	vec2 pixel_pos = UV * card_size;
	float sdf_dist = rounded_rect_sdf(pixel_pos, card_size, corner_radius_ratio);
	vec4 final_color;
	
	if (sdf_dist > 0.0) {
		final_color = vec4(0.0);
	} else {
		vec2 warped_uv = spherical_distort(UV, distortion);
		warped_uv = clamp(warped_uv, 0.0, 1.0);
		vec4 tex_color = texture(game_texture, warped_uv);
		
		// Calculate 3D dome normal
		vec3 normal = calculate_dome_normal(pixel_pos, card_size);
		
		// Specular with 3D lighting
		// Convert angle and height to 3D light direction
		float angle_rad = radians(light_angle);
		float height_rad = light_height * 3.14159265359 * 0.5; // 0 to 90 degrees
		
		vec3 light_dir = normalize(vec3(
			cos(angle_rad) * cos(height_rad),
			sin(angle_rad) * cos(height_rad),
			sin(height_rad)
		));
		
		vec3 view_dir = vec3(0.0, 0.0, 1.0); // View from above
		vec3 half_dir = normalize(light_dir + view_dir);
		float spec_angle = max(0.0, dot(normal, half_dir));
		float specular = pow(spec_angle, specular_power) * specular_intensity;
		
		// Bounce light - opposite side, low angle, very soft
		float bounce_angle_rad = radians(light_angle + 180.0); // Opposite side
		float bounce_height_rad = 0.25 * 3.14159265359 * 0.5; // Low on horizon (~12°)
		
		vec3 bounce_dir = normalize(vec3(
			cos(bounce_angle_rad) * cos(bounce_height_rad),
			sin(bounce_angle_rad) * cos(bounce_height_rad),
			sin(bounce_height_rad)
		));
		
		float bounce = max(0.0, dot(normal, bounce_dir));
		bounce = pow(bounce, bounce_softness) * bounce_intensity;
		
		// Derive colors from glass_color
		// Specular: brighter, more saturated
		vec3 specular_color = glass_color.rgb * 2.0;
		specular_color = clamp(specular_color, vec3(0.0), vec3(1.0));
		
		// Bounce: warmer, slightly brighter
		vec3 bounce_color = glass_color.rgb * 1.3;
		bounce_color = mix(bounce_color, vec3(1.0, 0.9, 0.7), 0.2); // Add warmth
		bounce_color = clamp(bounce_color, vec3(0.0), vec3(1.0));
		
		// Rim light - harsh rim on opposite side from specular
		// Fresnel effect: strongest at silhouette edges
		float fresnel = 1.0 - abs(dot(view_dir, normal));
		
		// Make it opposite to light - stronger on dark side
		float opposite_light = 1.0 - max(0.0, dot(normal, light_dir));
		
		// Combine for half-edge rim
		float rim = fresnel * opposite_light;
		rim = pow(rim, rim_sharpness) * rim_intensity;
		
		// Rim color: very bright glass color
		vec3 rim_color = glass_color.rgb * 3.0;
		rim_color = clamp(rim_color, vec3(0.0), vec3(1.0));
		
		// Apply glass color tint to texture
		vec3 glass_tint = mix(tex_color.rgb, glass_color.rgb, glass_color.a);
		
		vec3 final_rgb = glass_tint + (specular_color * specular) + (bounce_color * bounce) + (rim_color * rim);
		
		float aa_width = fwidth(pixel_pos.x) + fwidth(pixel_pos.y);
		float edge_alpha = 1.0 - smoothstep(-aa_width, 0.0, sdf_dist);
		
		final_color = vec4(final_rgb, tex_color.a * edge_alpha);
	}
	
	COLOR = final_color;
}
