shader_type canvas_item;
render_mode blend_mix;

uniform vec2 card_size = vec2(202.0, 270.0);
uniform float corner_radius_ratio = 0.06;
uniform float glow_margin = 20.0;
uniform float glow_radius = 20.0;
uniform float glow_intensity = 1.5;
uniform float blur_amount = 12.0;
uniform float threshold = 0.1;
uniform float glow_spread : hint_range(0.0, 0.5) = 0.05; // Expands glow outward like drop shadow
uniform sampler2D game_texture : source_color;

float rounded_rect_sdf(vec2 pixel_pos, vec2 size, float radius) {
	vec2 d = abs(pixel_pos) - (size * 0.5 - vec2(radius));
	return length(max(d, vec2(0.0))) + min(max(d.x, d.y), 0.0) - radius;
}

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
			vec4 sample_color = texture(game_texture, uv + offset);
			
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
	vec2 total_size = card_size + vec2(glow_margin * 2.0);
	vec2 pixel_pos = UV * total_size;
	
	// Calculate UV
	vec2 uv = pixel_pos / total_size;
	
	// Center and scale UV
	float card_aspect = card_size.x / card_size.y;
	float total_aspect = total_size.x / total_size.y;
	
	vec2 scale = vec2(1.0);
	if (card_aspect > total_aspect) {
		scale = vec2(1.0, card_aspect / total_aspect);
	} else {
		scale = vec2(total_aspect / card_aspect, 1.0);
	}
	
	uv = (uv - 0.5) * scale + 0.5;
	
	// Get blurred, thresholded texture
	vec2 tex_size = vec2(textureSize(game_texture, 0));
	vec3 blurred = sample_box_blur(uv, tex_size);
	
	// Calculate distance from card edge
	vec2 card_center = total_size * 0.5;
	vec2 local_pos = pixel_pos - card_center;
	// 1.0 ratio = corners touch (half of smallest dimension)
	float corner_radius = corner_radius_ratio * min(card_size.x, card_size.y) / 2.0;
	float dist = rounded_rect_sdf(local_pos, card_size, corner_radius);
	
	// Apply glow_spread - insets the fade from the outer edge
	// 0.0 = fade over full glow_radius (slow fade)
	// 0.5 = fade over half glow_radius (faster fade, reaches 0 at 50%)
	// Higher spread = faster fade, glow is more concentrated near card edge
	// Convert spread to effective fade distance
	float effective_radius = glow_radius * (1.0 - glow_spread);
	
	// Only show glow outside the card
	float glow_alpha = 0.0;
	if (dist > 0.0 && effective_radius > 0.0) {
		// Fade from card edge (dist=0) to effective_radius
		// After effective_radius, alpha is 0
		glow_alpha = 1.0 - smoothstep(0.0, effective_radius, dist);
		glow_alpha = clamp(glow_alpha, 0.0, 1.0);
	}
	
	// Apply intensity
	vec3 glow_color = blurred * glow_intensity;
	
	// Calculate brightness of glow for alpha
	float glow_brightness = length(blurred);
	glow_alpha *= glow_brightness * glow_intensity;
	
	COLOR = vec4(glow_color, glow_alpha);
}
