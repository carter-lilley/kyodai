shader_type canvas_item;

#include "res://shaders/card/includes/card_common.gdshaderinc"

uniform vec4 logo_rect = vec4(0.0, 0.0, 0.0, 0.0);
uniform vec2 uv_inner_scale = vec2(1.0, 1.0);
uniform vec2 uv_inner_offset = vec2(0.0, 0.0);

void fragment() {
	// logo_rect is in normalized texture-space: x, y, width, height.
	// A zero-size rect means nothing to draw.
	if (logo_rect.z <= 0.0 || logo_rect.w <= 0.0) {
		discard;
	}

	const vec4 BOX_COLOR = vec4(1.0, 0.0, 0.0, 0.9);
	const float LINE_WIDTH = 2.0;

	vec2 pixel_pos = UV * card_size;

	// The base card renders the cover inside the inner media area, after border
	// and glass insets. Match that area so the box aligns with the visible image.
	vec2 inner_size = card_size - vec2(total_inset_pixels * 2.0);
	vec2 inner_offset = vec2(total_inset_pixels);

	// Invert the base shader's aspect-cover transform:
	//   texture_uv = inner_uv * uv_inner_scale + uv_inner_offset
	// so we can turn the detected texture-space rect into inner media UVs.
	vec2 inner_uv_min = (logo_rect.xy - uv_inner_offset) / uv_inner_scale;
	vec2 inner_uv_max = (logo_rect.xy + logo_rect.zw - uv_inner_offset) / uv_inner_scale;

	vec2 logo_top_left = inner_offset + inner_size * inner_uv_min;
	vec2 logo_bottom_right = inner_offset + inner_size * inner_uv_max;

	bool inside_outer = pixel_pos.x >= logo_top_left.x && pixel_pos.x <= logo_bottom_right.x
					 && pixel_pos.y >= logo_top_left.y && pixel_pos.y <= logo_bottom_right.y;
	bool inside_inner = pixel_pos.x >= logo_top_left.x + LINE_WIDTH && pixel_pos.x <= logo_bottom_right.x - LINE_WIDTH
					 && pixel_pos.y >= logo_top_left.y + LINE_WIDTH && pixel_pos.y <= logo_bottom_right.y - LINE_WIDTH;

	if (inside_outer && !inside_inner) {
		COLOR = BOX_COLOR;
	} else {
		discard;
	}
}
