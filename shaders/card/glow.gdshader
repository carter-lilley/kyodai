shader_type canvas_item;
render_mode blend_mix;

#include "res://shaders/card/includes/card_common.gdshaderinc"

uniform vec2 glow_margin = vec2(20.0, 20.0);
uniform float glow_radius = 20.0;
uniform float glow_intensity = 1.5;
uniform float blur_amount = 12.0;
uniform float threshold = 0.1;
uniform float glow_spread : hint_range(0.0, 0.5) = 0.05; // Expands glow outward like drop shadow
uniform sampler2D game_texture : source_color, repeat_disable;
uniform float effect_alpha : hint_range(0.0, 1.0) = 1.0;

// Full box blur with 24x24 samples (radius 12)
vec3 sample_box_blur(vec2 uv, vec2 tex_size) {
	vec3 sum = vec3(0.0);
	float total_samples = 0.0;
	
	float step_x = blur_amount / tex_size.x;
	float step_y = blur_amount / tex_size.y;
	
	int blur_radius = 12; // 12 samples in each direction = 25x25 grid = 625 samples total
	
	for (int x = -blur_radius; x <= blur_radius; x++) {
		for (int y = -blur_radius; y <= blur_radius; y++) {
			vec2 offset = vec2(float(x) * step_x, float(y) * step_y);
			vec4 sample_color = texture(game_texture, clamp(uv + offset, 0.0, 1.0));
			
			// Threshold: bright pixels keep color, dark pixels become black
			float brightness = dot(sample_color.rgb, vec3(0.2126, 0.7152, 0.0722));
			if (brightness >= threshold) {
				sum += sample_color.rgb;
			}
			
			total_samples += 1.0;
		}
	}
	
	return sum / total_samples;
}

void fragment() {
	// Total area including proportional glow margin per axis
	vec2 total_size = card_size + glow_margin * 2.0;
	vec2 pixel_pos = UV * total_size;
	
	// Map to card-local coordinates (0 to card_size within the card area)
	vec2 card_local_pos = pixel_pos - glow_margin;
	
	// Convert to normalized UV (0-1 within card bounds)
	vec2 card_uv = card_local_pos / card_size;
	
	// Apply aspect-ratio preserving transform to sample texture correctly
	vec2 tex_size = vec2(textureSize(game_texture, 0));
	vec2 tex_uv = aspect_covered_uv(card_uv, card_size, tex_size);
	
	// Get blurred, thresholded texture
	vec3 blurred = sample_box_blur(tex_uv, tex_size);
	
	// Calculate distance from card edge using card-local position
	vec2 card_half = card_size * 0.5;
	float dist = rounded_rect_sdf_pixels(card_local_pos, card_size, corner_radius_pixels);
	
	// Apply glow_spread - insets the fade from the outer edge
	float effective_radius = glow_radius * (1.0 - glow_spread);
	
	// Only show glow outside the card
	float glow_alpha = 0.0;
	if (dist > 0.0 && effective_radius > 0.0) {
		// Fade from card edge (dist=0) to effective_radius
		glow_alpha = 1.0 - smoothstep(0.0, effective_radius, dist);
		glow_alpha = clamp(glow_alpha, 0.0, 1.0);
	}
	
	// Apply intensity
	vec3 glow_color = blurred * glow_intensity;
	
	// Calculate brightness of glow for alpha
	float glow_brightness = length(blurred);
	glow_alpha *= glow_brightness * glow_intensity * effect_alpha;
	
	COLOR = vec4(glow_color, glow_alpha);
}
