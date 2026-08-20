shader_type canvas_item;

// Hero Artwork background layer - shows the currently focused game's cover,
// cover-cropped to fill. Transparent when no artwork is available so layers
// beneath show through.

uniform sampler2D art_texture : source_color, filter_linear_mipmap, repeat_disable;
uniform vec2 rect_size = vec2(1.0);
uniform float dim : hint_range(0.0, 1.0) = 0.35;
uniform bool has_art = false;

void fragment() {
	if (has_art) {
		vec2 tex_size = vec2(textureSize(art_texture, 0));
		vec2 scale = vec2(1.0);
		float rect_aspect = rect_size.x / rect_size.y;
		float tex_aspect = tex_size.x / max(tex_size.y, 1.0);
		if (rect_aspect > tex_aspect) {
			scale.y = tex_aspect / rect_aspect;
		} else {
			scale.x = rect_aspect / tex_aspect;
		}
		vec2 uv = (UV - 0.5) * scale + 0.5;
		vec4 col = texture(art_texture, uv);
		COLOR = vec4(col.rgb * (1.0 - dim), col.a);
	} else {
		COLOR = vec4(0.0);
	}
}
