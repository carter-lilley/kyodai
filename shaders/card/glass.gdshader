shader_type canvas_item;

uniform vec2 card_size = vec2(202.0, 270.0);
uniform float corner_radius_ratio = 0.06;
uniform float border_inset_ratio = 0.0;  // Inherited from border effect
uniform sampler2D game_texture : filter_linear, repeat_disable;

// Glass parameters  
uniform float distortion : hint_range(0.0, 1.0) = 0.5;
uniform vec4 glass_color : source_color = vec4(0.2, 0.4, 1.0, 0.3);
uniform float reflection_overlay_opacity : hint_range(0.0, 1.0) = 1.0;

// Specular parameters
uniform float specular_power : hint_range(1.0, 128.0) = 32.0;
uniform float specular_intensity : hint_range(0.0, 2.0) = 0.8;
uniform float light_angle : hint_range(0.0, 360.0) = 45.0;
uniform float light_height : hint_range(-0.5, 1.0) = 0.5;

// Bounce light parameters
uniform float bounce_intensity : hint_range(0.0, 1.0) = 0.4;
uniform float bounce_softness : hint_range(1.0, 8.0) = 3.0;

// Rim light parameters
uniform float rim_intensity : hint_range(0.0, 2.0) = 1.0;
uniform float rim_sharpness : hint_range(2.0, 10.0) = 5.0;

// Additional inset to push underlying image inward (creates blank corners like Wii U icons)
uniform float additional_inset_ratio : hint_range(0.0, 0.5) = 0.0;

float rounded_rect_sdf(vec2 pos, vec2 size, float radius_ratio) {
	vec2 half_size = size * 0.5;
	float radius = radius_ratio * min(size.x, size.y) / 2.0;
	vec2 d = abs(pos - half_size) - (half_size - vec2(radius));
	return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
}

// Simple and correct: spherical dome using SDF distance
vec3 calculate_dome_normal(vec2 pos, vec2 size, float radius_ratio) {
	vec2 half_size = size * 0.5;
	
	// Get signed distance from edge (negative inside)
	float sdf_dist = rounded_rect_sdf(pos, size, radius_ratio);
	
	// Distance from edge (0 at edge, positive inside)
	float dist_from_edge = -sdf_dist;
	
	// Maximum distance
	float max_dist = min(size.x, size.y) * 0.5;
	
	// Normalize: 0 at edge, 1 at center
	float t = dist_from_edge / max_dist;
	t = clamp(t, 0.0, 0.99);
	
	// Calculate height on hemisphere: z = sqrt(1 - (1-t)^2)
	// This creates true spherical curvature rising from the edge
	float z = sqrt(1.0 - (1.0 - t) * (1.0 - t));
	
	// Calculate surface position for normal
	// Project from center toward edge based on t
	vec2 from_center = pos - half_size;
	float center_dist = length(from_center);
	
	vec2 surface_xy;
	if (center_dist < 0.001) {
		surface_xy = vec2(0.0);
	} else {
		// Scale to match the spherical surface at this height
		surface_xy = from_center / max_dist * (1.0 - t);
	}
	
	// Normal is the position on unit hemisphere
	return normalize(vec3(surface_xy.x, surface_xy.y, z));
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

// Aspect ratio preserving UV calculation (same as base_card)
vec2 aspect_covered_uv(vec2 uv, vec2 card, vec2 tex) {
	float card_aspect = card.x / card.y;
	float tex_aspect = tex.x / tex.y;
	
	vec2 scale;
	if (card_aspect > tex_aspect) {
		scale = vec2(1.0, tex_aspect / card_aspect);
	} else {
		scale = vec2(card_aspect / tex_aspect, 1.0);
	}
	
	return (uv - 0.5) * scale + 0.5;
}

void fragment() {
	vec2 pixel_pos = UV * card_size;
	
	// Calculate border inset (same as base_card)
	float border_inset_pixels = border_inset_ratio * card_size.x;
	
	// Subtract padding to extend under the border edge (same as base_card)
	float padding_pixels = 5.0;
	float effective_border_inset = max(0.0, border_inset_pixels - padding_pixels);
	
	vec2 inner_size = card_size - vec2(effective_border_inset * 2.0);
	vec2 inner_offset = vec2(effective_border_inset);
	
	// Calculate effective inner corner radius
	// Inner radius = outer radius - effective_inset (but not less than 0)
	float inner_radius_pixels = max(0.0, corner_radius_ratio * min(card_size.x, card_size.y) / 2.0 - effective_border_inset);
	float inner_radius_ratio = inner_radius_pixels / (min(inner_size.x, inner_size.y) / 2.0);
	
	// Offset pixel position for inset calculations
	vec2 inner_pixel_pos = pixel_pos - inner_offset;
	
	// Check if we're inside the inset area using the adjusted corner radius
	float sdf_dist = rounded_rect_sdf(inner_pixel_pos, inner_size, inner_radius_ratio);
	
	// Calculate edge anti-aliasing for the outer glass edge
	float aa_width = fwidth(pixel_pos.x) + fwidth(pixel_pos.y);
	float edge_alpha = 1.0 - smoothstep(-aa_width, 0.0, sdf_dist);
	
	// Calculate the inner "image area" with additional inset (like Wii U icons)
	float additional_inset_pixels = additional_inset_ratio * card_size.x;
	float effective_additional_inset = max(0.0, additional_inset_pixels);
	
	vec2 image_area_size = inner_size - vec2(effective_additional_inset * 2.0);
	vec2 image_area_offset = inner_offset + vec2(effective_additional_inset);
	
	// Calculate image area corner radius
	float image_area_radius_pixels = max(0.0, inner_radius_pixels - effective_additional_inset);
	float image_area_radius_ratio = 0.0;
	if (min(image_area_size.x, image_area_size.y) > 0.0) {
		image_area_radius_ratio = image_area_radius_pixels / (min(image_area_size.x, image_area_size.y) / 2.0);
	}
	
	// Check if current pixel is inside the image area
	vec2 image_pixel_pos = pixel_pos - image_area_offset;
	float image_sdf_dist = rounded_rect_sdf(image_pixel_pos, image_area_size, image_area_radius_ratio);
	float image_aa = 1.0 - smoothstep(-aa_width, 0.0, image_sdf_dist);
	
	// Calculate 3D dome normal from inset area with adjusted corner radius
	vec3 normal = calculate_dome_normal(inner_pixel_pos, inner_size, inner_radius_ratio);
	
	// Specular
	float angle_rad = radians(light_angle);
	float height_rad = light_height * 3.14159265359 * 0.5;
	
	vec3 light_dir = normalize(vec3(
		cos(angle_rad) * cos(height_rad),
		sin(angle_rad) * cos(height_rad),
		sin(height_rad)
	));
	
	vec3 view_dir = vec3(0.0, 0.0, 1.0);
	vec3 half_dir = normalize(light_dir + view_dir);
	float spec_angle = max(0.0, dot(normal, half_dir));
	float specular = pow(spec_angle, specular_power) * specular_intensity;
	
	// Bounce
	float bounce_angle_rad = radians(light_angle + 180.0);
	float bounce_height_rad = 0.25 * 3.14159265359 * 0.5;
	
	vec3 bounce_dir = normalize(vec3(
		cos(bounce_angle_rad) * cos(bounce_height_rad),
		sin(bounce_angle_rad) * cos(bounce_height_rad),
		sin(bounce_height_rad)
	));
	
	float bounce = max(0.0, dot(normal, bounce_dir));
	bounce = pow(bounce, bounce_softness) * bounce_intensity;
	
	// Colors
	vec3 specular_color = glass_color.rgb * 2.0;
	specular_color = clamp(specular_color, vec3(0.0), vec3(1.0));
	
	vec3 bounce_color = glass_color.rgb * 1.3;
	bounce_color = mix(bounce_color, vec3(1.0, 0.9, 0.7), 0.2);
	bounce_color = clamp(bounce_color, vec3(0.0), vec3(1.0));
	
	// Rim
	float fresnel = 1.0 - abs(dot(view_dir, normal));
	float opposite_light = 1.0 - max(0.0, dot(normal, light_dir));
	float rim = fresnel * opposite_light;
	rim = pow(rim, rim_sharpness) * rim_intensity;
	
	vec3 rim_color = glass_color.rgb * 3.0;
	rim_color = clamp(rim_color, vec3(0.0), vec3(1.0));
	
	// Calculate lights contribution (additive) - always on full glass area
	vec3 lights = (specular_color * specular) + (bounce_color * bounce) + (rim_color * rim);
	
	// Calculate UVs for the image area with proper aspect ratio
	// Map from image area space to 0-1 UV space
	vec2 image_uv = vec2(0.0);
	if (image_area_size.x > 0.0 && image_area_size.y > 0.0) {
		image_uv = (image_pixel_pos) / image_area_size;
		image_uv = clamp(image_uv, 0.0, 1.0);
		
		// Apply aspect ratio correction to prevent stretching
		vec2 tex_size = vec2(textureSize(game_texture, 0));
		image_uv = aspect_covered_uv(image_uv, image_area_size, tex_size);
	}
	
	// Calculate the "corner mask" - 1.0 in corners (outside image area), 0.0 inside image area
	float corner_mask = 1.0 - image_aa;
	
	// Sample the base game texture (only inside image area)
	vec3 base_color = vec3(0.0);
	if (image_aa > 0.0) {
		base_color = texture(game_texture, image_uv).rgb;
	}
	
	// Create reflection overlay only when reflection_overlay_opacity > 0
	vec3 reflection_content = vec3(0.0);
	if (reflection_overlay_opacity > 0.0 && image_aa > 0.0) {
		// Get distorted/warped game texture for reflection
		vec2 warped_uv = spherical_distort(UV, distortion);
		warped_uv = clamp(warped_uv, 0.0, 1.0);
		vec3 warped_color = texture(game_texture, warped_uv).rgb;
		
		vec3 tinted_reflection = mix(warped_color, glass_color.rgb, glass_color.a);
		reflection_content = tinted_reflection * reflection_overlay_opacity;
	}
	
	// In the image area: base + reflection + lights
	// In the corners: just lights (transparent, showing background behind)
	vec3 image_content = base_color + reflection_content;
	
	// Mix between transparent corners and image content based on image_aa
	vec3 content = image_content * image_aa;
	
	// Add lights on top of everything
	vec3 final_rgb = content + lights;
	
	// Calculate lights intensity for alpha
	float lights_intensity = length(lights);
	
	// Final alpha: 
	// - image_aa when showing the image content
	// - lights_intensity when showing only lights
	// - edge_alpha for the outer glass edge
	float content_alpha = max(image_aa, lights_intensity);
	float final_alpha = edge_alpha * content_alpha;
	
	COLOR = vec4(final_rgb, final_alpha);
}
