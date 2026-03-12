shader_type canvas_item;

uniform sampler2D gradient_texture : source_color;
uniform int gradient_direction = 0; // 0 = horizontal, 1 = vertical, 2 = diagonal

void fragment() {
    vec2 uv = UV;
    
    // Calculate gradient coordinate based on direction
    float gradient_coord;
    if (gradient_direction == 0) {
        // Horizontal
        gradient_coord = uv.x;
    } else if (gradient_direction == 1) {
        // Vertical
        gradient_coord = uv.y;
    } else {
        // Diagonal
        gradient_coord = (uv.x + uv.y) * 0.5;
    }
    
    // Sample gradient texture
    vec4 color = texture(gradient_texture, vec2(gradient_coord, 0.0));
    
    COLOR = color;
}
