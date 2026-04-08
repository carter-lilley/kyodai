shader_type canvas_item;
render_mode blend_mix;

uniform sampler2D game_texture : source_color;
uniform float effect_alpha : hint_range(0.0, 1.0) = 1.0;

// HSL adjustment parameters
uniform float hue_shift : hint_range(-1.0, 1.0) = 0.0;
uniform float saturation_scale : hint_range(0.0, 2.0) = 1.0;
uniform float lightness_scale : hint_range(0.0, 2.0) = 1.0;

// UV transform parameters (passed from base_card_effect)
uniform vec2 uv_transform_scale = vec2(1.0, 1.0);
uniform vec2 uv_transform_offset = vec2(0.0, 0.0);
uniform float vertical_offset = 0.0;

// Card shape parameters for SDF clipping
uniform vec2 card_size = vec2(202.0, 270.0);
uniform float corner_radius_pixels = 0.0;
uniform float total_inset_pixels = 0.0;

// SDF that accepts radius in pixels
float rounded_rect_sdf_pixels(vec2 pos, vec2 size, float radius_pixels) {
	vec2 half_size = size * 0.5;
	float radius = clamp(radius_pixels, 0.0, min(half_size.x, half_size.y));
	vec2 d = abs(pos - half_size) - (half_size - vec2(radius));
	return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
}

// Helper function for HSL to RGB conversion
float hue_to_rgb(float p, float q, float t) {
    if (t < 0.0) t += 1.0;
    if (t > 1.0) t -= 1.0;
    if (t < 1.0 / 6.0) return p + (q - p) * 6.0 * t;
    if (t < 1.0 / 2.0) return q;
    if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6.0;
    return p;
}

// Convert RGB to HSL
vec3 rgb_to_hsl(vec3 color) {
    float max_val = max(max(color.r, color.g), color.b);
    float min_val = min(min(color.r, color.g), color.b);
    float delta = max_val - min_val;
    
    float l = (max_val + min_val) / 2.0;
    float s = 0.0;
    float h = 0.0;
    
    if (delta > 0.0) {
        s = l > 0.5 ? delta / (2.0 - max_val - min_val) : delta / (max_val + min_val);
        
        if (max_val == color.r) {
            h = (color.g - color.b) / delta + (color.g < color.b ? 6.0 : 0.0);
        } else if (max_val == color.g) {
            h = (color.b - color.r) / delta + 2.0;
        } else {
            h = (color.r - color.g) / delta + 4.0;
        }
        h /= 6.0;
    }
    
    return vec3(h, s, l);
}

// Convert HSL to RGB
vec3 hsl_to_rgb(vec3 hsl) {
    float h = hsl.x;
    float s = hsl.y;
    float l = hsl.z;
    
    vec3 rgb = vec3(l);
    
    if (s > 0.0) {
        float q = l < 0.5 ? l * (1.0 + s) : l + s - l * s;
        float p = 2.0 * l - q;
        
        rgb.r = hue_to_rgb(p, q, h + 1.0 / 3.0);
        rgb.g = hue_to_rgb(p, q, h);
        rgb.b = hue_to_rgb(p, q, h - 1.0 / 3.0);
    }
    
    return rgb;
}

void fragment() {
	vec2 pixel_pos = UV * card_size;
	
	// Calculate anti-aliasing width
	float aa_width = fwidth(pixel_pos.x) + fwidth(pixel_pos.y);
	aa_width = max(aa_width, 0.5);
	
	// Apply border/glass insets to get inner area (matches base_card logic)
	float padding_pixels = 5.0;
	float effective_inset = max(0.0, total_inset_pixels - padding_pixels);
	
	vec2 inner_size = card_size - vec2(effective_inset * 2.0);
	vec2 inner_offset = vec2(effective_inset);
	
	// Check if we're inside the card shape using SDF
	float dist = rounded_rect_sdf_pixels(pixel_pos, card_size, corner_radius_pixels);
	float edge_alpha = 1.0 - smoothstep(-aa_width, 0.0, dist);
	
	if (edge_alpha <= 0.0) {
		discard;
	}
	
	// Calculate inner UV (inside the border)
	vec2 inner_pixel_pos = pixel_pos - inner_offset;
	vec2 inner_uv = inner_pixel_pos / inner_size;
	
	if (inner_uv.x < 0.0 || inner_uv.x > 1.0 || inner_uv.y < 0.0 || inner_uv.y > 1.0) {
		discard;
	}
	
	// Apply aspect ratio transform (center and scale)
	vec2 tex_uv = (inner_uv - 0.5) * uv_transform_scale + 0.5 + uv_transform_offset;
	
	// Apply vertical offset from smart crop
	tex_uv.y -= vertical_offset;
	
	// Sample the game texture with transformed UVs
    vec4 tex_color = texture(game_texture, tex_uv);
    
    // Convert to HSL
    vec3 hsl = rgb_to_hsl(tex_color.rgb);
    
    // Apply adjustments
    hsl.x = fract(hsl.x + hue_shift);  // Shift hue (wrap around)
    hsl.y = clamp(hsl.y * saturation_scale, 0.0, 1.0);  // Scale saturation
    hsl.z = clamp(hsl.z * lightness_scale, 0.0, 1.0);   // Scale lightness
    
    // Convert back to RGB
    vec3 adjusted_color = hsl_to_rgb(hsl);
    
    // Output with edge alpha and effect alpha
    COLOR = vec4(adjusted_color, tex_color.a * edge_alpha * effect_alpha);
}
