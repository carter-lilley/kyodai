shader_type canvas_item;

uniform vec2 card_size = vec2(202.0, 270.0);
uniform float corner_radius_pixels = 12.0;
uniform sampler2D game_texture : filter_linear, repeat_disable;
uniform float border_inset = 0.0;
uniform bool debug_sobel = false;
uniform bool debug_sobel_density = true;
uniform bool debug_thirds = true;
uniform bool smart_crop_enabled = false;
uniform float detection_window_ratio = 0.15;
uniform float edge_threshold = 0.4;

const int ROW_SAMPLES = 16;
const int COL_SAMPLES = 16;

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
	vec3 luminance_weights = vec3(0.2126, 0.725152, 0.0722);
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

float find_max_density_region(sampler2D tex, float window_ratio, float threshold) {
	int window_rows = max(1, int(float(ROW_SAMPLES) * window_ratio));
	int num_windows = ROW_SAMPLES - window_rows + 1;
	float max_hits = 0.0;
	float best_center_y = 0.5;
	
	for (int w = 0; w < ROW_SAMPLES; w++) {
		if (w >= num_windows) break;
		
		float hits = 0.0;
		
		for (int r = 0; r < ROW_SAMPLES; r++) {
			if (r >= window_rows) break;
			
			int row = w + r;
			float y = float(row) / float(ROW_SAMPLES - 1);
			
			for (int c = 0; c < COL_SAMPLES; c++) {
				float x = float(c) / float(COL_SAMPLES - 1);
				vec2 sample_uv = vec2(x, y);
				float edge = sobel_edge_detection(sample_uv, tex);
				
				if (edge > threshold) {
					hits += 1.0;
				}
			}
		}
		
		if (hits > max_hits) {
			max_hits = hits;
			best_center_y = (float(w) + float(window_rows) * 0.5) / float(ROW_SAMPLES);
		}
	}
	
	return best_center_y;
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
	
	float card_aspect = inner_size.x / inner_size.y;
	float tex_aspect = tex_size.x / tex_size.y;
	
	if (tex_aspect < card_aspect && (smart_crop_enabled || debug_sobel_density)) {
		logo_y = find_max_density_region(game_texture, detection_window_ratio, edge_threshold);
	}
	
	if (smart_crop_enabled && tex_aspect < card_aspect) {
		// Calculate visible region in texture space
		float scale_y = tex_aspect / card_aspect;
		float visible_top = 0.5 - scale_y * 0.5;
		float visible_height = scale_y;
		
		// Thirds within visible region: .33, .5, .66
		float third1 = visible_top + visible_height * 0.275;
		float third2 = visible_top + visible_height * 0.5;
		float third3 = visible_top + visible_height * 0.725;
		
		// Find nearest third line to logo_y
		float dist1 = abs(logo_y - third1);
		float dist2 = abs(logo_y - third2);
		float dist3 = abs(logo_y - third3);
		
		float nearest_target = third2;
		if (dist1 < dist2 && dist1 < dist3) {
			nearest_target = third1;
		} else if (dist3 < dist2) {
			nearest_target = third3;
		}
		
		vertical_offset = nearest_target - logo_y;
	}
	
	vec2 tex_uv = aspect_covered_uv(inner_uv, inner_size, tex_size);
	tex_uv.y += vertical_offset;
	vec4 tex_color = texture(game_texture, tex_uv);
	
	if (debug_sobel) {
		float edge = sobel_edge_detection(tex_uv, game_texture);
		tex_color = vec4(vec3(edge), 1.0);
	}
	
	if (debug_thirds) {
		float line_thickness = 3.0 / tex_size.y;
		
		// Calculate visible region in texture space
		float scale_y_calc = 1.0;
		if (tex_aspect < card_aspect) {
			scale_y_calc = tex_aspect / card_aspect;
		}
		float visible_top = 0.5 - scale_y_calc * 0.5;
		
		// Thirds divide the VISIBLE region: .33, .5, .66
		float tex_third1 = visible_top + scale_y_calc * 0.275;
		float tex_third2 = visible_top + scale_y_calc * 0.5;
		float tex_third3 = visible_top + scale_y_calc * 0.725;
		
		vec2 base_tex_uv = aspect_covered_uv(inner_uv, inner_size, tex_size);
		
		if (abs(base_tex_uv.y - tex_third1) < line_thickness || 
		    abs(base_tex_uv.y - tex_third2) < line_thickness ||
		    abs(base_tex_uv.y - tex_third3) < line_thickness) {
			tex_color = vec4(0.5, 0.0, 0.5, 1.0);
		}
	}
	
	if (debug_sobel_density) {
		float line_thickness = 3.0 / tex_size.y;
		
		// Thirds in texture space
		vec2 base_tex_uv = aspect_covered_uv(inner_uv, inner_size, tex_size);
		
		// Convert thirds to texture space based on visible region
		float scale_y_calc = 1.0;
		if (tex_aspect < card_aspect) {
			scale_y_calc = tex_aspect / card_aspect;
		}
		float visible_top = 0.5 - scale_y_calc * 0.5;
		float tex_third1 = visible_top + scale_y_calc * 0.275;
		float tex_third2 = visible_top + scale_y_calc * 0.5;
		float tex_third3 = visible_top + scale_y_calc * 0.725;
		
		// Draw cyan line showing the target third we're blending toward
		if (smart_crop_enabled && tex_aspect < card_aspect) {
			float dist1 = abs(logo_y - tex_third1);
			float dist2 = abs(logo_y - tex_third2);
			float dist3 = abs(logo_y - tex_third3);
			
			float nearest_target = tex_third2;
			if (dist1 < dist2 && dist1 < dist3) {
				nearest_target = tex_third1;
			} else if (dist3 < dist2) {
				nearest_target = tex_third3;
			}
			
			float display_y = nearest_target + vertical_offset;
			
			if (abs(base_tex_uv.y - display_y) < line_thickness * 1.5) {
				tex_color = vec4(0.0, 1.0, 1.0, 1.0);
			}
		}
		
		if (abs(tex_uv.y - logo_y) < line_thickness * 0.5) {
			tex_color = vec4(0.0, 1.0, 0.0, 1.0);
		}
	}
	
	tex_color.a *= edge_alpha;
	COLOR = tex_color;
}
