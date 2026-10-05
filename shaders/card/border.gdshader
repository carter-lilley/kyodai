shader_type canvas_item;

#include "res://shaders/card/includes/card_common.gdshaderinc"

uniform float border_width_ratio = 0.0;  // 0.0 to 1.0, relative to card width
uniform float border_fade_in_ratio = 0.0;  // 0.0 to 1.0, relative to card width
uniform vec4 border_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform bool use_gradient = false;
uniform sampler2D gradient_texture : source_color, filter_linear, repeat_disable;
uniform float border_gradient_angle = 180.0;  // degrees, 0 = up, clockwise
uniform bool border_gradient_radial = false;

uniform float inner_stroke_width_ratio = 0.0;  // 0.0 to 1.0, relative to card width
uniform bool use_inner_stroke_gradient = false;
uniform sampler2D inner_stroke_gradient_texture : source_color, filter_linear, repeat_disable;
uniform vec4 inner_stroke_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float inner_stroke_gradient_angle = 180.0;
uniform bool inner_stroke_gradient_radial = false;
uniform float outer_stroke_width_ratio = 0.0;  // 0.0 to 1.0, relative to card width
uniform bool use_outer_stroke_gradient = false;
uniform sampler2D outer_stroke_gradient_texture : source_color, filter_linear, repeat_disable;
uniform vec4 outer_stroke_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float outer_stroke_gradient_angle = 180.0;
uniform bool outer_stroke_gradient_radial = false;

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
	
	// --- BORDER FILL (original logic, unchanged) ---
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
		float gradient_t = gradient_coord(UV, border_gradient_angle, border_gradient_radial);
		color = texture(gradient_texture, vec2(gradient_t, 0.0));
	} else {
		color = border_color;
	}
	
	vec4 final_color = vec4(color.rgb, color.a * border_alpha);
	
	// --- STROKES ---
	// Strokes are drawn ON TOP of the border fill.  They must stay within the
	// border bounds and inherit the border alpha so they share the same smooth
	// anti-aliased edges.
	float aa_norm = aa_width / total_border;
	
	// Inner stroke — centred at the fade-in boundary (original position)
	float inner_stroke_width_pixels = inner_stroke_width_ratio * card_size.x;
	if (inner_stroke_width_pixels > 0.001) {
		float inner_stroke_pos = border_fade_in_pixels / total_border;
		float inner_stroke_half = (inner_stroke_width_pixels / total_border) * 0.5;
		float d = rel_d - inner_stroke_pos;
		
		// Soft band: smoothstep on both edges instead of a hard if-check
		float stroke_alpha =
			smoothstep(-inner_stroke_half - aa_norm, -inner_stroke_half, d) *
			(1.0 - smoothstep(inner_stroke_half, inner_stroke_half + aa_norm, d));
		
		// Inherit border alpha so the stroke fades where the border fades
		stroke_alpha *= border_alpha;
		
		if (stroke_alpha > 0.0) {
			vec4 stroke_color;
			if (use_inner_stroke_gradient) {
				float gradient_t = gradient_coord(UV, inner_stroke_gradient_angle, inner_stroke_gradient_radial);
				stroke_color = texture(inner_stroke_gradient_texture, vec2(gradient_t, 0.0));
			} else {
				stroke_color = inner_stroke_color;
			}
			final_color = mix(final_color, stroke_color, stroke_alpha * stroke_color.a);
		}
	}
	
	// Outer stroke — centred near the outer edge but fully inside the border
	float outer_stroke_width_pixels = outer_stroke_width_ratio * card_size.x;
	if (outer_stroke_width_pixels > 0.001) {
		// Position so the stroke is fully contained within the border ring
		float outer_stroke_half = (outer_stroke_width_pixels / total_border) * 0.5;
		float outer_stroke_pos = 1.0 - outer_stroke_half;
		float d = rel_d - outer_stroke_pos;
		
		// Soft band: smoothstep on both edges
		float stroke_alpha =
			smoothstep(-outer_stroke_half - aa_norm, -outer_stroke_half, d) *
			(1.0 - smoothstep(outer_stroke_half, outer_stroke_half + aa_norm, d));
		
		// Inherit border alpha
		stroke_alpha *= border_alpha;
		
		if (stroke_alpha > 0.0) {
			vec4 stroke_color;
			if (use_outer_stroke_gradient) {
				float gradient_t = gradient_coord(UV, outer_stroke_gradient_angle, outer_stroke_gradient_radial);
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
