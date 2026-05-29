// Shared card effect utilities — included by all card shaders

// Core shape uniforms used by nearly every effect
uniform vec2 card_size = vec2(202.0, 270.0);
uniform float corner_radius_pixels = 0.0;
uniform float corner_radius_ratio = 0.06;
uniform float total_inset_pixels = 0.0;

// UV transform chain precomputed by BaseCardEffect (avoids re-deriving aspect math)
uniform vec2 uv_transform_scale = vec2(1.0, 1.0);
uniform vec2 uv_transform_offset = vec2(0.0, 0.0);
uniform float vertical_offset = 0.0;

// Pixel-accurate rounded rect SDF (used by base, blur, border, badge, gradient)
float rounded_rect_sdf_pixels(vec2 pos, vec2 size, float radius_pixels) {
	vec2 half_size = size * 0.5;
	float radius = clamp(radius_pixels, 0.0, min(half_size.x, half_size.y));
	vec2 d = abs(pos - half_size) - (half_size - vec2(radius));
	return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
}

// Ratio-based rounded rect SDF (used when caller already has a ratio)
float rounded_rect_sdf_ratio(vec2 pos, vec2 size, float radius_ratio) {
	vec2 half_size = size * 0.5;
	float radius_pixels = radius_ratio * min(size.x, size.y) / 2.0;
	vec2 d = abs(pos - half_size) - (half_size - vec2(radius_pixels));
	return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius_pixels;
}

// Aspect-ratio preserving UV transform: fits `tex` inside `card` using cover semantics
vec2 aspect_covered_uv(vec2 uv, vec2 card, vec2 tex) {
	float card_aspect = card.x / card.y;
	float tex_aspect = tex.x / tex.y;
	vec2 scale;
	if (card_aspect > tex_aspect) {
		scale = vec2(1.0, tex_aspect / card_aspect);
	} else {
		scale = vec2(card_aspect / tex_aspect, 1.0);
	}
	return (uv - 0.5) * scale + 0.5;
}
