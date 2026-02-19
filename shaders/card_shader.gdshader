shader_type canvas_item;

// === Card dimensions (passed from script) ===
uniform vec2 card_size = vec2(200.0, 280.0);

// === Layer 1: Clipping ===
uniform float corner_radius_pixels = 12.0;

// === Layer 2: Game texture ===
uniform sampler2D game_texture : filter_linear, repeat_disable;

// === Layer 3: Border ===
uniform bool border_enabled = false;
uniform float border_width_pixels = 4.0;
uniform float border_fade_in_pixels = 0.0;
uniform float border_fade_out_pixels = 0.0;
uniform vec4 border_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);

// === Future layers (placeholders) ===
// uniform bool shadow_enabled = false;
// uniform float shadow_blur = 10.0;
// uniform vec4 shadow_color : source_color = vec4(0.0, 0.0, 0.0, 0.5);

float rounded_rect_sdf(vec2 pos, vec2 size, float radius) {
	vec2 half_size = size * 0.5;
	vec2 d = abs(pos - half_size) - (half_size - radius);
	return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
}

vec2 aspect_covered_uv(vec2 uv, vec2 card, vec2 tex) {
	// CSS "cover" mode: scale texture to fill card, maintain aspect ratio, crop edges
	float card_aspect = card.x / card.y;
	float tex_aspect = tex.x / tex.y;
	
	// Calculate UV scale factor (always <= 1.0 for cover mode)
	// We zoom in by sampling a smaller region of the texture
	float scale;
	if (card_aspect > tex_aspect) {
		// Card is wider relative to height: scale based on height
		scale = tex_aspect / card_aspect;
	} else {
		// Texture is wider relative to height: scale based on width  
		scale = card_aspect / tex_aspect;
	}
	
	// Scale UVs toward center (multiply, not divide, to zoom in)
	return (uv - 0.5) * scale + 0.5;
}

void fragment() {
	vec2 pixel_pos = UV * card_size;
	
	// Layer 1: Clipping mask (rounded rect SDF)
	// dist > 0 = outside, dist < 0 = inside
	float dist = rounded_rect_sdf(pixel_pos, card_size, corner_radius_pixels);
	
	// Outside rounded rect - discard
	if (dist > 0.0) {
		discard;
	}
	
	// Layer 2: Game texture - cover mode (fill card, maintain aspect ratio, crop edges)
	vec2 tex_size = vec2(textureSize(game_texture, 0));
	vec2 tex_uv = aspect_covered_uv(UV, card_size, tex_size);
	
	vec4 tex_color = texture(game_texture, tex_uv);
	
	// Layer 3: Border (adapted from original flat-border-ui-box shader)
	// In original: d <= corner_radius and d >= corner_radius - border_width
	// In our SDF: dist <= 0 and dist >= -border_width
	float total_border = border_width_pixels + border_fade_in_pixels + border_fade_out_pixels;
	
	if (border_enabled && total_border > 0.0 && dist >= -total_border && dist <= 0.0) {
		float rel_d = (dist + total_border) / total_border; // 0 at inner edge, 1 at outer edge
		
		// Calculate fade alpha using original formula
		float fade_in_factor = border_fade_in_pixels / total_border;
		float fade_out_factor = border_fade_out_pixels / total_border;
		
		float alpha = 1.0;
		if (fade_in_factor > 0.001) {
			alpha = min(alpha, rel_d / fade_in_factor);
		}
		if (fade_out_factor > 0.001) {
			alpha = min(alpha, (1.0 - rel_d) / fade_out_factor);
		}
		alpha = clamp(alpha, 0.0, 1.0);
		
		// Inner zone: blend between texture and border
		// Outer zone: border color fading to transparent
		float solid_border_start = (border_fade_in_pixels) / total_border;
		float solid_border_end = (border_fade_in_pixels + border_width_pixels) / total_border;
		
		if (rel_d < solid_border_end) {
			// Inner transition zone (fade from texture to border)
			COLOR = vec4(mix(tex_color.rgb, border_color.rgb, alpha), mix(tex_color.a, border_color.a, alpha));
		} else {
			// Outer zone (border fading to transparent)
			COLOR = vec4(border_color.rgb, border_color.a * alpha);
		}
	} else {
		// Interior - just texture
		COLOR = tex_color;
	}
}
