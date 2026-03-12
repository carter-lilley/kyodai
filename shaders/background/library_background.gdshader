shader_type canvas_item;

uniform vec4 background_color : source_color = vec4(0.1, 0.1, 0.1, 1.0);

void fragment() {
    COLOR = background_color;
}
