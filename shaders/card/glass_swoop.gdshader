shader_type canvas_item;

uniform vec2 card_size = vec2(202.0, 270.0);
uniform float corner_radius_ratio = 0.06;
uniform float border_inset_ratio = 0.0;

// Swoop parameters
uniform vec4 glass_color : source_color = vec4(0.2, 0.4, 1.0, 0.3);
uniform float swoop_intensity : hint_range(0.0, 1.0) = 0.3;
uniform float swoop_height : hint_range(0.0, 0.8) = 0.5;  // Y position of the line (0 = bottom, 1 = top)
uniform float swoop_curve : hint_range(0.0, 1.0) = 0.3;  // Curve amount: 0 = flat, 1 = maximum dip
uniform float swoop_tilt : hint_range(-1.0, 1.0) = 0.0;   // Tilt: raises one side, lowers the other

float rounded_rect_sdf(vec2 pos, vec2 size, float radius_ratio) {
	vec2 half_size = size * 0.5;
	float radius = radius_ratio * min(size.x, size.y) / 2.0;
	vec2 d = abs(pos - half_size) - (half_size - vec2(radius));
	return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
}

void fragment() {
	vec2 pixel_pos = UV * card_size;
	
	// Calculate border inset
	float border_inset_pixels = border_inset_ratio * card_size.x;
	
	// Calculate inner area
	float padding_pixels = 5.0;
	float effective_border_inset = max(0.0, border_inset_pixels - padding_pixels);
	
	vec2 inner_size = card_size - vec2(effective_border_inset * 2.0);
	vec2 inner_offset = vec2(effective_border_inset);
	
	// Calculate SDF for the glass shape
	vec2 inner_pixel_pos = pixel_pos - inner_offset;
	float sdf_dist = rounded_rect_sdf(inner_pixel_pos, inner_size, corner_radius_ratio);
	
	// Edge anti-aliasing
	float aa_width = fwidth(pixel_pos.x) + fwidth(pixel_pos.y);
	float edge_alpha = 1.0 - smoothstep(-aa_width, 0.0, sdf_dist);
	
	if (edge_alpha <= 0.0) {
		discard;
	}
	
	// Base Y position of the swoop line (from bottom)
	// swoop_height: 0 = bottom of card, 1 = top of card
	float base_y = 1.0 - swoop_height;
	
	// Bezier-like curve that bends down
	// Uses a quadratic function: x * (2 - x) creates a curve that starts at 0, peaks at 1 (at x=1), then back to 0
	// But we want it to dip down, so we invert and shift
	float x = UV.x;
	
	// Create a curve that bends down from left to right
	// At x=0 (left): curve = 0
	// At x=0.5 (center): curve = maximum dip
	// At x=1 (right): curve = back to 0
	float curve_shape = 4.0 * x * (1.0 - x);  // Parabola: 0 at edges, 1 at center
	
	// Apply curve amount (positive = dips down, negative = rises up)
	float curve_offset = curve_shape * swoop_curve * 0.5;
	
	// Apply tilt - raises one side, lowers the other
	// (x - 0.5) goes from -0.5 on left to +0.5 on right
	float tilt_offset = (x - 0.5) * swoop_tilt * 0.5;
	
	// Calculate boundary Y position
	// Add curve_offset so positive values dip DOWN (increase Y)
	float boundary_y = base_y + curve_offset + tilt_offset;
	
	// Check if pixel is below the boundary (in the filled swoop area)
	// Hard edge with anti-aliasing - use fwidth for sharp but smooth edge
	float dist_to_boundary = UV.y - boundary_y;
	float boundary_aa = fwidth(dist_to_boundary) * 0.5;
	float is_in_swoop = smoothstep(-boundary_aa, boundary_aa, dist_to_boundary);
	
	// Apply intensity
	float alpha = is_in_swoop * swoop_intensity;
	
	// Output darkened glass color (much darker version of glass_color)
	vec3 dark_glass = glass_color.rgb * 0.3;  // Darken to 30% of original brightness
	vec3 final_color = dark_glass;
	float final_alpha = alpha * edge_alpha;
	
	COLOR = vec4(final_color, final_alpha);
}
