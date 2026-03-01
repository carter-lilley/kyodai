shader_type canvas_item;

uniform vec4 icon_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);

void fragment() {
	vec4 tex_color = texture(TEXTURE, UV);
	// Use the texture alpha to determine where the icon is
	// Apply the icon color where the texture is visible
	COLOR = vec4(icon_color.rgb, tex_color.a * icon_color.a);
}
