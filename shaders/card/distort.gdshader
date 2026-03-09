shader_type canvas_item;

uniform vec2 card_size = vec2(202.0, 270.0);
uniform float corner_radius_ratio = 0.06;
uniform float border_inset_ratio = 0.0;
uniform sampler2D game_texture : filter_linear, repeat_disable;

// Distortion parameters
uniform float distortion : hint_range(0.0, 1.0) = 0.5;
uniform float opacity : hint_range(0.0, 1.0) = 1.0;

float rounded_rect_sdf(vec2 pos, vec2 size, float radius_ratio) {
	vec2 half_size = size * 0.5;
	float radius = radius_ratio * min(size.x, size.y) / 2.0;
	vec2 d = abs(pos - half_size) - (half_size - vec2(radius));
	return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
}

vec2 distort(vec2 p, float dist_param, float aspect) {
	float d = length(p);
	float z = sqrt(dist_param + d * d * -dist_param);
	float r = atan(d, z) / 3.1415926535;
	float phi = atan(p.y, p.x);
	return vec2(r * cos(phi) * (1.0 / aspect) + 0.5, r * sin(phi) + 0.5);
}

vec2 spherical_distort(vec2 uv, float raw_distortion, vec2 size) {
	vec2 pixel_pos = uv * size;
	vec2 half_size = size * 0.5;
	float aspect = size.x / size.y;
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
	
	// Calculate border inset
	float border_inset_pixels = border_inset_ratio * card_size.x;
	
	// Subtract padding to extend under the border edge
	float padding_pixels = 5.0;
	float effective_border_inset = max(0.0, border_inset_pixels - padding_pixels);
	
	vec2 inner_size = card_size - vec2(effective_border_inset * 2.0);
	vec2 inner_offset = vec2(effective_border_inset);
	
	// Calculate effective inner corner radius
	float inner_radius_pixels = max(0.0, corner_radius_ratio * min(card_size.x, card_size.y) / 2.0 - effective_border_inset);
	float inner_radius_ratio = inner_radius_pixels / (min(inner_size.x, inner_size.y) / 2.0);
	
	// Offset pixel position for inset calculations
	vec2 inner_pixel_pos = pixel_pos - inner_offset;
	
	// Check if we're inside the area
	float sdf_dist = rounded_rect_sdf(inner_pixel_pos, inner_size, inner_radius_ratio);
	
	// Calculate edge anti-aliasing
	float aa_width = fwidth(pixel_pos.x) + fwidth(pixel_pos.y);
	float edge_alpha = 1.0 - smoothstep(-aa_width, 0.0, sdf_dist);
	
	if (edge_alpha <= 0.0) {
		discard;
	}
	
	// Get distorted/warped UVs
	vec2 warped_uv = spherical_distort(UV, distortion, card_size);
	warped_uv = clamp(warped_uv, 0.0, 1.0);
	
	// Apply aspect ratio correction
	vec2 tex_size = vec2(textureSize(game_texture, 0));
	warped_uv = aspect_covered_uv(warped_uv, card_size, tex_size);
	
	// Sample the distorted texture
	vec4 tex_color = texture(game_texture, warped_uv);
	
	// Apply opacity
	tex_color.a *= opacity * edge_alpha;
	
	COLOR = tex_color;
}
