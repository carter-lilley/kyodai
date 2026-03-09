shader_type canvas_item;

uniform vec2 card_size = vec2(202.0, 270.0);
uniform float corner_radius_ratio = 0.06;  // 0.0 to 1.0, relative to card width
uniform sampler2D game_texture : filter_linear, repeat_disable;
uniform float border_inset_ratio = 0.0;  // 0.0 to 1.0, relative to card width
uniform float alpha = 1.0;  // Global alpha multiplier for fade animations
uniform bool debug_sobel = false;
uniform bool debug_sobel_density = false;
uniform bool debug_blend_vls = false;
uniform bool debug_thirds = false;
uniform bool smart_crop_enabled = true;
uniform float resolution_scale : hint_range(0.0, 100.0) = 50.0;
uniform float blend_outlier_threshold = 0.15;
uniform float detection_window_ratio = 0.15;
uniform float edge_threshold = 0.4;
uniform float smart_crop_overshoot = 0.15;

const int ROW_SAMPLES = 8;
const int COL_SAMPLES = 8;

float rounded_rect_sdf(vec2 pos, vec2 size, float radius_ratio) {
	vec2 half_size = size * 0.5;
	// 1.0 ratio = corners touch (half of smallest dimension)
	float radius = radius_ratio * min(size.x, size.y) / 2.0;
	vec2 d = abs(pos - half_size) - (half_size - vec2(radius));
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

float get_saturation(vec4 col) {
	float max_val = max(max(col.r, col.g), col.b);
	float min_val = min(min(col.r, col.g), col.b);
	if (max_val <= 0.0) return 0.0;
	return (max_val - min_val) / max_val;
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

float find_max_density_region(sampler2D tex, float window_ratio, float threshold, float scale) {
	// Calculate dynamic grid size based on resolution scale
	int row_samples = max(2, int(float(ROW_SAMPLES) * scale / 100.0));
	int col_samples = max(2, int(float(COL_SAMPLES) * scale / 100.0));
	
	int window_rows = max(1, int(float(row_samples) * window_ratio));
	int num_windows = row_samples - window_rows + 1;
	float max_hits = 0.0;
	float best_center_y = 0.5;
	
	for (int w = 0; w < ROW_SAMPLES; w++) {
		if (w >= num_windows) break;
		
		float hits = 0.0;
		
		for (int r = 0; r < ROW_SAMPLES; r++) {
			if (r >= window_rows) break;
			
			int row = w + r;
			float y = float(row) / float(row_samples - 1);
			
			for (int c = 0; c < COL_SAMPLES; c++) {
				if (c >= col_samples) break;
				float x = float(c) / float(col_samples - 1);
				vec2 sample_uv = vec2(x, y);
				float edge = sobel_edge_detection(sample_uv, tex);
				
				if (edge > threshold) {
					hits += 1.0;
				}
			}
		}
		
		if (hits > max_hits) {
			max_hits = hits;
			best_center_y = (float(w) + float(window_rows) * 0.5) / float(row_samples);
		}
	}
	
	return best_center_y;
}

float find_max_variance_region(sampler2D tex, float band_height_ratio, bool use_saturation, float scale) {
	// Calculate dynamic grid size based on resolution scale
	int row_samples = max(2, int(float(ROW_SAMPLES) * scale / 100.0));
	int col_samples = max(2, int(float(COL_SAMPLES) * scale / 100.0));
	
	int band_rows = max(1, int(float(row_samples) * band_height_ratio));
	int num_bands = row_samples - band_rows + 1;
	
	float max_variance = -1.0;
	float best_center_y = 0.5;
	
	for (int b = 0; b < ROW_SAMPLES; b++) {
		if (b >= num_bands) break;
		
		float sum = 0.0;
		float sum_sq = 0.0;
		int count = 0;
		
		for (int r = 0; r < ROW_SAMPLES; r++) {
			if (r >= band_rows) break;
			
			int row = b + r;
			float y = float(row) / float(row_samples - 1);
			
			for (int c = 0; c < COL_SAMPLES; c++) {
				if (c >= col_samples) break;
				float x = float(c) / float(col_samples - 1);
				vec2 sample_uv = vec2(x, y);
				float val = use_saturation ? get_saturation(texture(tex, sample_uv)) : get_luminance(texture(tex, sample_uv));
				
				sum += val;
				sum_sq += val * val;
				count++;
			}
		}
		
		float mean = sum / float(count);
		float variance = (sum_sq / float(count)) - (mean * mean);
		
		if (variance > max_variance) {
			max_variance = variance;
			best_center_y = (float(b) + float(band_rows) * 0.5) / float(row_samples);
		}
	}
	
	return best_center_y;
}

float find_blend_vls(sampler2D tex, float window_ratio, float threshold, float outlier_threshold, float scale) {
	float sobel_y = find_max_density_region(tex, window_ratio, threshold, scale);
	float luminance_y = find_max_variance_region(tex, window_ratio, false, scale);
	float saturation_y = find_max_variance_region(tex, window_ratio, true, scale);
	
	float anchor = (sobel_y + luminance_y) * 0.5;
	float sat_distance = abs(saturation_y - anchor);
	
	if (sat_distance > outlier_threshold) {
		return anchor;
	}
	
	float sat_weight = 2.0;
	float sobel_weight = 1.0;
	float lum_weight = 1.0;
	float total_weight = sat_weight + sobel_weight + lum_weight;
	
	return (saturation_y * sat_weight + sobel_y * sobel_weight + luminance_y * lum_weight) / total_weight;
}

void fragment() {
	vec2 pixel_pos = UV * card_size;
	
	float aa_width = fwidth(pixel_pos.x) + fwidth(pixel_pos.y);
	aa_width = max(aa_width, 0.5);
	
	// Convert ratio to pixels
	float border_inset_pixels = border_inset_ratio * card_size.x;
	
	// Subtract padding to make base card sit deeper under the border
	// (negative padding = larger card, extending further under the border edge)
	float padding_pixels = 5.0;
	float effective_border_inset = max(0.0, border_inset_pixels - padding_pixels);
	
	vec2 inner_size = card_size - vec2(effective_border_inset * 2.0);
	vec2 inner_offset = vec2(effective_border_inset);
	
	float dist = rounded_rect_sdf(pixel_pos, card_size, corner_radius_ratio);
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
		logo_y = find_blend_vls(game_texture, detection_window_ratio, edge_threshold, blend_outlier_threshold, resolution_scale);
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
		
		float snap_offset = nearest_target - logo_y;
		
		if (nearest_target == third2) {
			vertical_offset = snap_offset;
		} else {
			float max_slide = visible_top;
			float overshoot_offset = (nearest_target < 0.5) ? max_slide : -max_slide;
			vertical_offset = mix(snap_offset, overshoot_offset, smart_crop_overshoot);
		}
		
		vertical_offset = clamp(vertical_offset, -visible_top, visible_top);
	}
	
	vec2 tex_uv = aspect_covered_uv(inner_uv, inner_size, tex_size);
	tex_uv.y -= vertical_offset;
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
	
	if (debug_blend_vls) {
		float blend_y = find_blend_vls(game_texture, detection_window_ratio, edge_threshold, blend_outlier_threshold, resolution_scale);
		float display_y = blend_y;
		
		if (smart_crop_enabled && tex_aspect < card_aspect) {
			display_y = blend_y + vertical_offset;
		}
		
		float line_thickness = 3.0 / tex_size.y;
		vec2 base_tex_uv = aspect_covered_uv(inner_uv, inner_size, tex_size);
		
		if (abs(base_tex_uv.y - display_y) < line_thickness * 6.0) {
			tex_color = vec4(1.0, 1.0, 0.0, 1.0);
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
			
			if (abs(base_tex_uv.y - nearest_target) < line_thickness * 1.5) {
				tex_color = vec4(0.0, 1.0, 1.0, 1.0);
			}
		}
		
		if (abs(tex_uv.y - logo_y) < line_thickness * 0.5) {
			tex_color = vec4(0.0, 1.0, 0.0, 1.0);
		}
	}
	
	tex_color.a *= edge_alpha * alpha;
	COLOR = tex_color;
}
