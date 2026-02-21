shader_type canvas_item;

// === Card dimensions (passed from script) ===
uniform vec2 card_size = vec2(202.0, 270.0);

// === Layer 1: Clipping ===
uniform float corner_radius_pixels = 12.0;

// === Layer 2: Game texture ===
uniform sampler2D game_texture : filter_linear, repeat_disable;

// === Layer 3: Border ===
uniform bool border_enabled = false;
uniform float border_width_pixels = 4.0;
uniform float border_fade_in_pixels = 0.0;
uniform vec4 border_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);

// === Platform Badge ===
uniform bool platform_badge_enabled = false;
uniform float platform_badge_size = 1.0; // Scale factor for entire badge (0.5 to 2.0)
uniform float platform_badge_inner_radius = 0.0; // 0.0 = square, 1.0 = rounded to touch border
uniform float platform_badge_icon_padding = 0.5; // Icon padding multiplier (0.0 to 1.0)
uniform vec4 platform_badge_icon_color : source_color = vec4(1.0, 1.0, 1.0, 1.0); // Icon color
uniform sampler2D platform_badge_icon : filter_linear, repeat_disable;

float rounded_rect_sdf(vec2 pos, vec2 size, float radius) {
	vec2 half_size = size * 0.5;
	vec2 d = abs(pos - half_size) - (half_size - radius);
	return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
}

vec2 aspect_covered_uv(vec2 uv, vec2 card, vec2 tex) {
	// CSS "cover" mode: scale texture to fill card, maintain aspect ratio, crop edges
	float card_aspect = card.x / card.y;
	float tex_aspect = tex.x / tex.y;
	
	// Calculate UV scale factors (separate for X and Y)
	// We zoom in by sampling a smaller region of the texture
	vec2 scale;
	if (card_aspect > tex_aspect) {
		// Card is wider than texture: fit to width, crop top/bottom
		scale = vec2(1.0, tex_aspect / card_aspect);
	} else {
		// Card is narrower than texture: fit to height, crop left/right
		scale = vec2(card_aspect / tex_aspect, 1.0);
	}
	
	// Scale UVs toward center (multiply to zoom in)
	return (uv - 0.5) * scale + 0.5;
}

void fragment() {
	vec2 pixel_pos = UV * card_size;
	
	// Calculate a single anti-aliasing width for all elements
	// This ensures consistent AA across borders, badge, and icons
	float aa_width = fwidth(pixel_pos.x) + fwidth(pixel_pos.y);
	aa_width = max(aa_width, 0.5); // Minimum AA width to prevent artifacts
	
	// Layer 1: Clipping mask (rounded rect SDF) 
	float dist = rounded_rect_sdf(pixel_pos, card_size, corner_radius_pixels);
	float edge_alpha = 1.0 - smoothstep(-aa_width, 0.0, dist);
	
	// Early discard for fully transparent pixels
	if (edge_alpha <= 0.0) {
		discard;
	}
	
	// Layer 2: Game texture - cover mode (fill card, maintain aspect ratio, crop edges)
	vec2 tex_size = vec2(textureSize(game_texture, 0));
	vec2 tex_uv = aspect_covered_uv(UV, card_size, tex_size);
	vec4 tex_color = texture(game_texture, tex_uv);
	
	// Layer 3: Border
	float total_border = border_width_pixels + border_fade_in_pixels;
	vec4 final_color = tex_color;
	
	if (border_enabled && total_border > 0.0 && dist >= -total_border && dist <= 0.0) {
		float rel_d = (dist + total_border) / total_border;
		float inner_aa_alpha = smoothstep(0.0, aa_width / total_border, rel_d);
		
		float fade_in_factor = border_fade_in_pixels / total_border;
		
		float border_alpha = 1.0;
		if (fade_in_factor > 0.001) {
			border_alpha = min(border_alpha, rel_d / fade_in_factor);
		}
		border_alpha = clamp(border_alpha, 0.0, 1.0);
		
		float solid_border_end = (border_fade_in_pixels + border_width_pixels) / total_border;
		
		if (rel_d < solid_border_end) {
			vec4 border_mix = vec4(mix(tex_color.rgb, border_color.rgb, border_alpha), mix(tex_color.a, border_color.a, border_alpha));
			final_color = mix(tex_color, border_mix, inner_aa_alpha);
		} else {
			final_color = vec4(border_color.rgb, border_color.a * border_alpha);
		}
	}
	
	// Layer 4: Platform Badge
	if (platform_badge_enabled) {
		float base_badge_size = 32.0 * platform_badge_size;
		float badge_size = max(base_badge_size, corner_radius_pixels);
		
		if (pixel_pos.x < badge_size && pixel_pos.y < badge_size) {
			float max_inner_radius = max(0.0, badge_size - border_width_pixels);
			float inner_radius = max_inner_radius * clamp(platform_badge_inner_radius, 0.0, 1.0);
			
			// Calculate raw distances for AA (without smoothstep yet)
			float dist_left = pixel_pos.x;
			float dist_top = pixel_pos.y;
			
			// Inner corner distance
			vec2 inner_corner_center = vec2(badge_size - inner_radius);
			bool in_inner_corner = pixel_pos.x > badge_size - inner_radius && pixel_pos.y > badge_size - inner_radius;
			float inner_dist = 0.0;
			if (in_inner_corner && inner_radius > 0.0) {
				inner_dist = length(pixel_pos - inner_corner_center) - inner_radius;
			}
			
			// Badge bounds
			bool outside_badge = pixel_pos.x > badge_size || pixel_pos.y > badge_size;
			
			// Apply single smoothstep AA pass to all elements
			float alpha_left = smoothstep(-aa_width, 0.0, dist_left);
			float alpha_top = smoothstep(-aa_width, 0.0, dist_top);
			float inner_alpha = 1.0;
			if (in_inner_corner && inner_radius > 0.0) {
				inner_alpha = 1.0 - smoothstep(-aa_width, 0.0, inner_dist);
			}
			float bounds_alpha = outside_badge ? 0.0 : 1.0;
			
			// Combine all alphas with single AA pass
			float badge_alpha = min(min(alpha_left, alpha_top), min(inner_alpha, bounds_alpha));
			
			// Blend badge background
			vec4 badge_color = border_color;
			final_color = mix(final_color, badge_color, badge_alpha);
		}
	}
	
	// Final AA pass on entire card edge
	final_color.a *= edge_alpha;
	COLOR = final_color;
}
