shader_type canvas_item;

// Post-Process Anti-Aliasing (AHAA) for 2D
// Apply this to a full-screen ColorRect or as a layer on your main viewport

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_nearest;
uniform float luma_threshold : hint_range(0.0, 1.0) = 0.375;
uniform float low_threshold : hint_range(0.0, 1.0) = 0.05;
uniform float high_threshold : hint_range(0.0, 1.0) = 0.2;
uniform float blend_strength : hint_range(0.0, 1.0) = 0.5;
uniform float epsilon = 0.001;

// Scharr operator kernels
const mat3 scharr_kernel_x = mat3(
	vec3(-3.0, 0.0, 3.0), 
	vec3(-10.0, 0.0, 10.0), 
	vec3(-3.0, 0.0, 3.0)
);

const mat3 scharr_kernel_y = mat3(
	vec3(-3.0, -10.0, -3.0), 
	vec3(0.0, 0.0, 0.0), 
	vec3(3.0, 10.0, 3.0)
);

// Gaussian kernel for blending
const mat3 gaussian_kernel = mat3(
	vec3(0.0625, 0.125, 0.0625),
	vec3(0.125,  0.25,  0.125),
	vec3(0.0625, 0.125, 0.0625)
);

float get_luma(vec3 color) {
	return dot(color, vec3(0.299, 0.587, 0.114));
}

vec3 get_chroma(vec3 color) {
	float max_component = max(max(color.r, color.g), color.b);
	return color / (max_component + epsilon);
}

vec2 apply_scharr(vec2 uv, vec2 tex_size) {
	float gx = 0.0;
	float gy = 0.0;
	
	for (int x = -1; x <= 1; x++) {
		for (int y = -1; y <= 1; y++) {
			vec2 offset = vec2(float(x), float(y)) / tex_size;
			vec4 sample_color = texture(screen_texture, uv + offset);
			float luma = get_luma(sample_color.rgb);
			gx += luma * scharr_kernel_x[x + 1][y + 1];
			gy += luma * scharr_kernel_y[x + 1][y + 1];
		}
	}
	return vec2(gx, gy);
}

vec3 gaussian_blur(vec2 uv, vec2 tex_size) {
	vec3 color_sum = vec3(0.0);
	for (int x = -1; x <= 1; x++) {
		for (int y = -1; y <= 1; y++) {
			vec2 offset = vec2(float(x), float(y)) / tex_size;
			color_sum += texture(screen_texture, uv + offset).rgb * gaussian_kernel[x + 1][y + 1];
		}
	}
	return color_sum;
}

void fragment() {
	vec2 tex_size = vec2(textureSize(screen_texture, 0));
	vec2 uv = SCREEN_UV;
	
	// Get center pixel color
	vec4 center_color = texture(screen_texture, uv);
	
	// Scharr-based edge detection
	vec2 gradient = apply_scharr(uv, tex_size);
	float gradient_magnitude = length(gradient);
	
	// Check edge strength
	bool is_strong_edge = gradient_magnitude >= high_threshold;
	bool is_weak_edge = gradient_magnitude >= low_threshold && gradient_magnitude < high_threshold;
	
	// Hysteresis: check if weak edge is connected to strong edge
	bool is_connected = false;
	if (is_weak_edge && !is_strong_edge) {
		for (int x = -1; x <= 1; x++) {
			for (int y = -1; y <= 1; y++) {
				if (x == 0 && y == 0) continue;
				vec2 neighbor_uv = uv + vec2(float(x), float(y)) / tex_size;
				vec2 neighbor_grad = apply_scharr(neighbor_uv, tex_size);
				if (length(neighbor_grad) >= high_threshold) {
					is_connected = true;
					break;
				}
			}
			if (is_connected) break;
		}
	}
	
	// Apply anti-aliasing on edges
	vec3 final_color = center_color.rgb;
	if (is_strong_edge || (is_weak_edge && is_connected)) {
		// Collect neighborhood colors
		vec3 neighborhood_colors[9];
		float neighborhood_luma[9];
		int index = 0;
		
		for (int x = -1; x <= 1; x++) {
			for (int y = -1; y <= 1; y++) {
				vec2 offset = vec2(float(x), float(y)) / tex_size;
				vec3 color = texture(screen_texture, uv + offset).rgb;
				neighborhood_colors[index] = color;
				neighborhood_luma[index] = get_luma(color);
				index++;
			}
		}
		
		// Calculate local variance
		float local_variance = 0.0;
		for (int i = 0; i < 9; i++) {
			local_variance += distance(center_color.rgb, neighborhood_colors[i]);
		}
		local_variance /= 9.0;
		
		// Dynamic threshold based on local variance
		float dynamic_threshold = mix(luma_threshold, 1.0, local_variance);
		
		if (local_variance <= dynamic_threshold) {
			// Apply Gaussian blur on edges
			vec3 blurred = gaussian_blur(uv, tex_size);
			final_color = mix(center_color.rgb, blurred, blend_strength);
		}
	}
	
	COLOR = vec4(final_color, center_color.a);
}
