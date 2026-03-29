shader_type canvas_item;

uniform sampler2D gradient_texture : filter_linear, repeat_disable;
uniform int gradient_direction = 0;  // 0 = Horizontal, 1 = Vertical, 2 = Diagonal

void fragment() {
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
	
	// Output the gradient color - alpha is controlled by gradient stops
	COLOR = gradient_color;
	
	// Discard fully transparent pixels
	if (COLOR.a <= 0.0) {
		discard;
	}
}
