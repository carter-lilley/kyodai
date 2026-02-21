shader_type canvas_item;

uniform vec4 icon_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);

void fragment() {
	vec4 tex_color = texture(TEXTURE, UV);
	// Use the icon color RGB, keep the texture alpha
	COLOR = vec4(icon_color.rgb, tex_color.a);
}
