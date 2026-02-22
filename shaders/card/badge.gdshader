shader_type canvas_item;

uniform vec2 card_size = vec2(202.0, 270.0);
uniform float corner_radius_pixels = 12.0;

uniform bool badge_enabled = false;
uniform float badge_size = 1.0;
uniform float badge_inner_radius = 0.0;
uniform vec4 badge_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform vec4 icon_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform sampler2D badge_icon : filter_linear, repeat_disable;
uniform float border_width = 0.0;

float rounded_rect_sdf(vec2 pos, vec2 size, float radius) {
	vec2 half_size = size * 0.5;
	vec2 d = abs(pos - half_size) - (half_size - radius);
	return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
}

void fragment() {
	vec2 pixel_pos = UV * card_size;
	
	float aa_width = fwidth(pixel_pos.x) + fwidth(pixel_pos.y);
	aa_width = max(aa_width, 0.5);
	
	vec4 final_color = vec4(0.0, 0.0, 0.0, 0.0);
	
	if (badge_enabled) {
		float base_badge_size = 32.0 * badge_size;
		float actual_badge_size = max(base_badge_size, corner_radius_pixels);
		
		if (pixel_pos.x < actual_badge_size && pixel_pos.y < actual_badge_size) {
			float max_inner_radius = max(0.0, actual_badge_size - border_width);
			float inner_radius = max_inner_radius * clamp(badge_inner_radius, 0.0, 1.0);
			
			float dist_left = pixel_pos.x;
			float dist_top = pixel_pos.y;
			
			vec2 inner_corner_center = vec2(actual_badge_size - inner_radius);
			bool in_inner_corner = pixel_pos.x > actual_badge_size - inner_radius && pixel_pos.y > actual_badge_size - inner_radius;
			float inner_dist = 0.0;
			if (in_inner_corner && inner_radius > 0.0) {
				inner_dist = length(pixel_pos - inner_corner_center) - inner_radius;
			}
			
			bool outside_badge = pixel_pos.x > actual_badge_size || pixel_pos.y > actual_badge_size;
			
			float alpha_left = smoothstep(-aa_width, 0.0, dist_left);
			float alpha_top = smoothstep(-aa_width, 0.0, dist_top);
			float inner_alpha = 1.0;
			if (in_inner_corner && inner_radius > 0.0) {
				inner_alpha = 1.0 - smoothstep(-aa_width, 0.0, inner_dist);
			}
			float bounds_alpha = outside_badge ? 0.0 : 1.0;
			
			float badge_alpha = min(min(alpha_left, alpha_top), min(inner_alpha, bounds_alpha));
			
			final_color = vec4(badge_color.rgb, badge_color.a * badge_alpha);
			
			vec2 icon_uv = pixel_pos / actual_badge_size;
			vec4 icon_tex_color = texture(badge_icon, icon_uv);
			icon_tex_color.rgb *= icon_color.rgb;
			
			float icon_alpha = icon_tex_color.a * badge_alpha;
			final_color = mix(final_color, icon_tex_color, icon_alpha);
		}
	}
	
	float edge_dist = rounded_rect_sdf(pixel_pos, card_size, corner_radius_pixels);
	float edge_alpha = 1.0 - smoothstep(-aa_width, 0.0, edge_dist);
	final_color.a *= edge_alpha;
	
	if (final_color.a <= 0.0) {
		discard;
	}
	
	COLOR = final_color;
}
