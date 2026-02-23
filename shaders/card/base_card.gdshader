shader_type canvas_item;

uniform vec2 card_size = vec2(202.0, 270.0);
uniform float corner_radius_pixels = 12.0;
uniform sampler2D game_texture : filter_linear, repeat_disable;
uniform float border_inset = 0.0;
uniform bool debug_sobel = false;
uniform bool debug_logo_row = true;
uniform bool smart_crop_enabled = true;
uniform float logo_blend_factor = 1.0;

float rounded_rect_sdf(vec2 pos, vec2 size, float radius) {
	vec2 half_size = size * 0.5;
	vec2 d = abs(pos - half_size) - (half_size - radius);
	return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
}

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

float get_luminance(vec4 col) {
	vec3 luminance_weights = vec3(0.2126, 0.7152, 0.0722);
	return dot(col.rgb, luminance_weights);
}

float sobel_edge_detection(vec2 uv, sampler2D tex) {
	vec2 tex_size = vec2(textureSize(tex, 0));
	float offset = 1.0 / min(tex_size.x, tex_size.y);
	
	float tl = get_luminance(texture(tex, uv + vec2(-offset, -offset)));
	float t  = get_luminance(texture(tex, uv + vec2(0.0, -offset)));
	float tr = get_luminance(texture(tex, uv + vec2(offset, -offset)));
	float l  = get_luminance(texture(tex, uv + vec2(-offset, 0.0)));
	float r  = get_luminance(texture(tex, uv + vec2(offset, 0.0)));
	float bl = get_luminance(texture(tex, uv + vec2(-offset, offset)));
	float b  = get_luminance(texture(tex, uv + vec2(0.0, offset)));
	float br = get_luminance(texture(tex, uv + vec2(offset, offset)));
	
	float sobel_x = -1.0 * tl + 1.0 * tr +
	               -2.0 * l  + 2.0 * r  +
	               -1.0 * bl + 1.0 * br;
	
	float sobel_y = -1.0 * tl + -2.0 * t + -1.0 * tr +
	                1.0 * bl +  2.0 * b +  1.0 * br;
	
	float edge_strength = sqrt(sobel_x * sobel_x + sobel_y * sobel_y);
	return clamp(edge_strength * 2.0, 0.0, 1.0);
}

float horizontal_edge_density(vec2 uv, sampler2D tex, int samples) {
	vec2 tex_size = vec2(textureSize(tex, 0));
	float density = 0.0;
	
	for (int i = 0; i < samples; i++) {
		float t = float(i) / float(samples - 1);
		vec2 sample_uv = vec2(t, uv.y);
		density += sobel_edge_detection(sample_uv, tex);
	}
	
	return density / float(samples);
}

float find_max_density_row(sampler2D tex, int row_samples, int col_samples) {
	float max_density = 0.0;
	float max_row_y = 0.5;
	
	for (int row = 0; row < row_samples; row++) {
		float y = float(row) / float(row_samples - 1);
		float density = 0.0;
		
		for (int col = 0; col < col_samples; col++) {
			float x = float(col) / float(col_samples - 1);
			vec2 sample_uv = vec2(x, y);
			density += sobel_edge_detection(sample_uv, tex);
		}
		density /= float(col_samples);
		
		if (density > max_density) {
			max_density = density;
			max_row_y = y;
		}
	}
	
	return max_row_y;
}

void fragment() {
	vec2 pixel_pos = UV * card_size;
	
	float aa_width = fwidth(pixel_pos.x) + fwidth(pixel_pos.y);
	aa_width = max(aa_width, 0.5);
	
	vec2 inner_size = card_size - vec2(border_inset * 2.0);
	vec2 inner_offset = vec2(border_inset);
	
	float dist = rounded_rect_sdf(pixel_pos, card_size, corner_radius_pixels);
	float edge_alpha = 1.0 - smoothstep(-aa_width, 0.0, dist);
	
	if (edge_alpha <= 0.0) {
		discard;
	}
	
	vec2 inner_pixel_pos = pixel_pos - inner_offset;
	vec2 inner_uv = inner_pixel_pos / inner_size;
	
	if (inner_uv.x < 0.0 || inner_uv.x > 1.0 || inner_uv.y < 0.0 || inner_uv.y > 1.0) {
		discard;
	}
	
	vec2 tex_size = vec2(textureSize(game_texture, 0));
	
	float vertical_offset = 0.0;
	float logo_y = 0.5;
	
	if (smart_crop_enabled) {
		float card_aspect = inner_size.x / inner_size.y;
		float tex_aspect = tex_size.x / tex_size.y;
		
		if (tex_aspect < card_aspect) {
			logo_y = find_max_density_row(game_texture, 32, 32);
			float blended_y = mix(logo_y, 0.5, logo_blend_factor);
			
			float scale_y = tex_aspect / card_aspect;
			float visible_portion = scale_y;
			float hidden_portion = 1.0 - visible_portion;
			float max_offset = hidden_portion * 0.5;
			
			float desired_offset = blended_y - 0.5;
			vertical_offset = clamp(desired_offset, -max_offset, max_offset);
		}
	}
	
	vec2 tex_uv = aspect_covered_uv(inner_uv, inner_size, tex_size);
	tex_uv.y += vertical_offset;
	vec4 tex_color = texture(game_texture, tex_uv);
	
	if (debug_sobel) {
		float edge = sobel_edge_detection(tex_uv, game_texture);
		tex_color = vec4(vec3(edge), 1.0);
	}
	
	if (debug_logo_row) {
		float line_thickness = 3.0 / tex_size.y;
		if (abs(tex_uv.y - logo_y) < line_thickness) {
			tex_color = vec4(1.0, 0.0, 0.0, 1.0);
		}
		
		float blend_line_y = mix(logo_y, 0.5, logo_blend_factor);
		if (abs(tex_uv.y - blend_line_y) < line_thickness * 0.5) {
			tex_color = vec4(0.0, 1.0, 0.0, 1.0);
		}
	}
	
	tex_color.a *= edge_alpha;
	COLOR = tex_color;
}
