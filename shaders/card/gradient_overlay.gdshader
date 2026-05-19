shader_type canvas_item;

#include "res://shaders/card/includes/card_common.gdshaderinc"

uniform sampler2D gradient_texture : filter_linear, repeat_disable;
uniform int gradient_direction = 0;  // 0 = Horizontal, 1 = Vertical, 2 = Diagonal
uniform float effect_alpha : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	vec2 pixel_pos = UV * card_size;
	
	// Calculate anti-aliasing width
	float aa_width = fwidth(pixel_pos.x) + fwidth(pixel_pos.y);
	aa_width = max(aa_width, 0.5);
	
	// Check if we're inside the card shape using SDF
	float dist = rounded_rect_sdf_pixels(pixel_pos, card_size, corner_radius_pixels);
	float edge_alpha = 1.0 - smoothstep(-aa_width, 0.0, dist);
	
	// Discard pixels outside the card shape
	if (edge_alpha <= 0.0) {
		discard;
	}
	
	// Calculate gradient coordinate based on direction
	float gradient_t;
	if (gradient_direction == 0) {
		// Horizontal: left to right
		gradient_t = UV.x;
	} else if (gradient_direction == 1) {
		// Vertical: top to bottom
		gradient_t = UV.y;
	} else {
		// Diagonal: average of X and Y
		gradient_t = (UV.x + UV.y) * 0.5;
	}
	
	// Clamp to valid range
	gradient_t = clamp(gradient_t, 0.0, 1.0);
	
	// Sample gradient
	vec4 gradient_color = texture(gradient_texture, vec2(gradient_t, 0.0));
	
	// Apply edge alpha and effect alpha
	gradient_color.a *= edge_alpha * effect_alpha;
	
	// Output the gradient color
	COLOR = gradient_color;
	
	// Discard fully transparent pixels
	if (COLOR.a <= 0.0) {
		discard;
	}
}
