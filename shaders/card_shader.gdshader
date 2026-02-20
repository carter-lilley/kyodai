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
uniform float border_fade_out_pixels = 0.0;
uniform vec4 border_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);

// === Layer 4: Fluid Glass ===
uniform bool fluid_glass_enabled = false;
uniform float fluid_chromatic_shift : hint_range(0.0, 1.0) = 0.2;
uniform float fluid_bend_amount : hint_range(0.0, 1.0) = 0.4;
uniform float fluid_curve_light : hint_range(0.0, 1.0) = 0.5;
uniform float fluid_rim_light : hint_range(0.0, 1.0) = 0.8;
uniform float fluid_noise_amount : hint_range(0.0, 1.0) = 0.05;
uniform float fluid_edge_falloff : hint_range(10.0, 200.0) = 50.0;

float rounded_rect_sdf(vec2 pos, vec2 size, float radius) {
	vec2 half_size = size * 0.5;
	vec2 d = abs(pos - half_size) - (half_size - radius);
	return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
}

float fluid_noise(vec2 uv) {
	return fract(sin(dot(uv, vec2(9.82131, 58.234))) * 45312.1324);
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
	
	// Layer 4: Fluid Glass (applied on top, inset by border width)
	if (fluid_glass_enabled) {
		// Calculate total border width to inset the glass effect
		float total_border = border_width_pixels + border_fade_in_pixels + border_fade_out_pixels;
		
		// Offset dist by border width: glass starts where border ends
		// dist is negative inside, 0 at outer edge, -total_border at inner border edge
		float dist_from_border = dist + total_border;
		
		// Create edge mask from the inset distance: 0 at center, 1 at inner border edge
		// dist_from_border: 0 at inner border edge, negative going inward toward center
		float edge_mask = clamp(1.0 + dist_from_border / fluid_edge_falloff, 0.0, 1.0);
		
		// Only apply glass inside the border area
		if (dist_from_border < 0.0) {
			// Calculate warp direction like the original (curved UV based on pow)
			vec2 warp_dir = UV;
			warp_dir.x = 1.0 - mix(mix(0.5, 1.0, pow(warp_dir.x, 8.0)), 0.0, pow(1.0 - warp_dir.x, 8.0));
			warp_dir.y = mix(mix(0.5, 1.0, pow(warp_dir.y, 8.0)), 0.0, pow(1.0 - warp_dir.y, 8.0));
			warp_dir = warp_dir * 2.0 - 1.0;
			
			// Calculate warp offset based on edge proximity
			vec2 warp = warp_dir * pow(edge_mask - 0.1, 2.0) * fluid_bend_amount;
			vec2 warped_tex_uv = tex_uv / (1.0 - warp);
			
			// Chromatic shift
			vec2 chromatic_shift = warp * fluid_chromatic_shift;
			
			// Sample the texture with chromatic aberration
			vec4 fluid_color = vec4(
				texture(game_texture, warped_tex_uv + chromatic_shift).rg,
				texture(game_texture, warped_tex_uv).ba
			);
			
			// Calculate curve light (highlights the curved edge)
			float curve_mask = clamp((edge_mask - 0.5) / (1.0 - 0.5), 0.0, 1.0);
			float curve_light = sin(curve_mask * 3.14159) * edge_mask;
			curve_light *= 1.0 - pow(length(UV), 2.0);
			curve_light = clamp(curve_light, 0.0, 1.0);
			curve_light *= fluid_curve_light;
			
			// Calculate rim light
			float rim_mask = abs((UV.y + UV.x) - 1.0);
			float rim = clamp((edge_mask - 0.9) / (1.0 - 0.9), 0.0, 1.0);
			rim *= fluid_rim_light;
			rim *= rim_mask;
			
			// Add grain
			float grain = clamp(fluid_noise(UV), 0.0, 1.0);
			grain = grain * 2.0 - 1.0;
			grain = (grain * fluid_noise_amount) + 1.0;
			
			fluid_color *= grain;
			
			// Apply glass effect: distorted texture with highlights over the original
			// Replace the original color with the distorted version, then add highlights
			vec3 final_color = fluid_color.rgb + rim + curve_light;
			COLOR = vec4(final_color, COLOR.a);
		}
	}
}
