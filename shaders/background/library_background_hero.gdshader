shader_type canvas_item;

// Hero Artwork background layer - shows the currently focused game's cover,
// cover-cropped to fill. Transparent when no artwork is available so layers
// beneath show through.

uniform sampler2D art_texture : source_color, filter_linear_mipmap, repeat_disable;
uniform vec2 rect_size = vec2(1.0);
uniform float dim : hint_range(0.0, 1.0) = 0.35;
uniform float blur : hint_range(0.0, 1.0) = 0.3;
uniform float opacity : hint_range(0.0, 1.0) = 1.0;
uniform bool has_art = false;

// Golden-angle spiral: keeps the tap distribution uniform for any sample
// count, so a fixed budget still reads as an even blur.
const float GOLDEN_ANGLE = 2.399963;
const int BLUR_TAPS = 20;
// Screen-space blur radius at blur = 1.0, referenced to 1080p height so the
// slider means the same thing at any resolution.
const float MAX_BLUR_RADIUS_PX = 48.0;

void fragment() {
	if (has_art) {
		vec2 tex_size = vec2(textureSize(art_texture, 0));
		vec2 scale = vec2(1.0);
		float rect_aspect = rect_size.x / max(rect_size.y, 1.0);
		float tex_aspect = tex_size.x / max(tex_size.y, 1.0);
		if (rect_aspect > tex_aspect) {
			scale.y = tex_aspect / rect_aspect;
		} else {
			scale.x = rect_aspect / tex_aspect;
		}
		vec2 uv = (UV - 0.5) * scale + 0.5;

		vec4 col;
		if (blur < 0.01) {
			col = texture(art_texture, uv);
		} else {
			// Radius in screen pixels -> cover-cropped UV space.
			float radius_px = blur * MAX_BLUR_RADIUS_PX * (rect_size.y / 1080.0);
			vec2 step_uv = (radius_px / max(rect_size, vec2(1.0))) * scale;
			vec4 sum = vec4(0.0);
			for (int i = 0; i < BLUR_TAPS; i++) {
				float fi = float(i);
				float angle = fi * GOLDEN_ANGLE;
				float r = sqrt((fi + 0.5) / float(BLUR_TAPS));
				vec2 offset = vec2(cos(angle), sin(angle)) * r * step_uv;
				sum += texture(art_texture, uv + offset);
			}
			col = sum / float(BLUR_TAPS);
		}

		COLOR = vec4(col.rgb * (1.0 - dim), col.a * opacity);
	} else {
		COLOR = vec4(0.0);
	}
}
