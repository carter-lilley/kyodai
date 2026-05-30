shader_type canvas_item;

#include "res://shaders/card/includes/card_common.gdshaderinc"

uniform float border_width_ratio = 0.0;  // 0.0 to 1.0, relative to card width
uniform float border_fade_in_ratio = 0.0;  // 0.0 to 1.0, relative to card width
uniform vec4 border_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform bool use_gradient = false;
uniform sampler2D gradient_texture : filter_linear, repeat_disable;
uniform int gradient_direction = 0;

uniform float inner_stroke_width_ratio = 0.0;  // 0.0 to 1.0, relative to card width
uniform bool use_inner_stroke_gradient = false;
uniform sampler2D inner_stroke_gradient_texture : filter_linear, repeat_disable;
uniform vec4 inner_stroke_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float outer_stroke_width_ratio = 0.0;  // 0.0 to 1.0, relative to card width
uniform bool use_outer_stroke_gradient = false;
uniform sampler2D outer_stroke_gradient_texture : filter_linear, repeat_disable;
uniform vec4 outer_stroke_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);

uniform float effect_alpha : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	vec2 pixel_pos = UV * card_size;
	
	// Convert border ratios to pixels
	float border_width_pixels = border_width_ratio * card_size.x;
	float border_fade_in_pixels = border_fade_in_ratio * card_size.x;
	float total_border = border_width_pixels + border_fade_in_pixels;
	
	// No border → nothing to do
	if (total_border <= 0.0) {
		discard;
	}
	
	// SDF distance from card edge (negative inside, positive outside)
	float dist = rounded_rect_sdf_pixels(pixel_pos, card_size, corner_radius_pixels);
	
	// Unified edge anti-aliasing — same formula as all other effects
	float aa_width = fwidth(pixel_pos.x) + fwidth(pixel_pos.y);
	aa_width = max(aa_width, 0.5);
	
	// Border ring: from inner edge (-total_border) to outer edge
	if (dist < -total_border) {
		discard;
	}
	
	float edge_alpha;
	if (display_mode == 0) {
		// Standard mode: hard edge — parent panel provides anti-aliasing
		if (dist > 0.0) { discard; }
		edge_alpha = 1.0;
	} else {
		// Transparent / Media Only: smoothstep anti-aliasing (fade inward so parent clip doesn't cut it)
		edge_alpha = 1.0 - smoothstep(-aa_width, 0.0, dist);
		if (edge_alpha <= 0.0) { discard; }
	}
	
	// Normalized distance: 0 = inner edge, 1 = outer edge
	float rel_d = (dist + total_border) / total_border;
	
	// Optional fade-in from inner edge
	float border_alpha = 1.0;
	if (border_fade_in_pixels > 0.001) {
		float fade_in_factor = border_fade_in_pixels / total_border;
		border_alpha = min(border_alpha, rel_d / fade_in_factor);
		border_alpha = clamp(border_alpha, 0.0, 1.0);
	}
	
	// Apply outer edge alpha
	border_alpha *= edge_alpha;
	
	vec4 color;
	if (use_gradient) {
		float gradient_t;
		if (gradient_direction == 0) {
			gradient_t = UV.x;
		} else if (gradient_direction == 1) {
			gradient_t = UV.y;
		} else {
			gradient_t = (UV.x + UV.y) * 0.5;
		}
		gradient_t = clamp(gradient_t, 0.0, 1.0);
		color = texture(gradient_texture, vec2(gradient_t, 0.0));
	} else {
		color = border_color;
	}
	
	vec4 final_color = vec4(color.rgb, color.a * border_alpha);
	
	// Inner stroke
	float inner_stroke_width_pixels = inner_stroke_width_ratio * card_size.x;
	if (inner_stroke_width_pixels > 0.0) {
		float inner_stroke_pos = border_fade_in_pixels / total_border;
		float inner_stroke_half = (inner_stroke_width_pixels / total_border) * 0.5;
		if (abs(rel_d - inner_stroke_pos) < inner_stroke_half) {
			float stroke_alpha = smoothstep(inner_stroke_half, inner_stroke_half - aa_width / total_border, abs(rel_d - inner_stroke_pos));
			
			vec4 stroke_color;
			if (use_inner_stroke_gradient) {
				float gradient_t;
				if (gradient_direction == 0) {
					gradient_t = UV.x;
				} else if (gradient_direction == 1) {
					gradient_t = UV.y;
				} else {
					gradient_t = (UV.x + UV.y) * 0.5;
				}
				gradient_t = clamp(gradient_t, 0.0, 1.0);
				stroke_color = texture(inner_stroke_gradient_texture, vec2(gradient_t, 0.0));
			} else {
				stroke_color = inner_stroke_color;
			}
			
			final_color = mix(final_color, stroke_color, stroke_alpha * stroke_color.a);
		}
	}
	
	// Outer stroke
	float outer_stroke_width_pixels = outer_stroke_width_ratio * card_size.x;
	if (outer_stroke_width_pixels > 0.0) {
		float outer_stroke_pos = 1.0;
		float outer_stroke_half = (outer_stroke_width_pixels / total_border) * 0.5;
		if (abs(rel_d - outer_stroke_pos) < outer_stroke_half) {
			float stroke_alpha = smoothstep(outer_stroke_half, outer_stroke_half - aa_width / total_border, abs(rel_d - outer_stroke_pos));
			
			vec4 stroke_color;
			if (use_outer_stroke_gradient) {
				float gradient_t;
				if (gradient_direction == 0) {
					gradient_t = UV.x;
				} else if (gradient_direction == 1) {
					gradient_t = UV.y;
				} else {
					gradient_t = (UV.x + UV.y) * 0.5;
				}
				gradient_t = clamp(gradient_t, 0.0, 1.0);
				stroke_color = texture(outer_stroke_gradient_texture, vec2(gradient_t, 0.0));
			} else {
				stroke_color = outer_stroke_color;
			}
			
			final_color = mix(final_color, stroke_color, stroke_alpha * stroke_color.a);
		}
	}
	
	final_color.a *= effect_alpha;
	
	if (final_color.a <= 0.0) {
		discard;
	}
	
	COLOR = final_color;
}
