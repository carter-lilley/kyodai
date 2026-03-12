shader_type canvas_item;
render_mode blend_premul_alpha;

// CafeOS - TRUE 3D Alpha Extrusion with Flat Shading

uniform sampler2D icon_atlas : source_color, repeat_disable, filter_linear_mipmap_anisotropic;
uniform float time_scale : hint_range(0.0, 2.0) = 0.5;
uniform float orbit_radius : hint_range(1.0, 5.0) = 2.358;
uniform float icon_scale : hint_range(0.1, 1.0) = 0.7;
uniform float orbit_speed : hint_range(0.05, 1.0) = 0.15;
uniform int num_icons : hint_range(5, 30) = 21;
uniform vec3 light_direction = vec3(1.0, 1.0, 0.0);

uniform float rotation_speed : hint_range(0.0, 2.0) = 0.3;

// 3D Extrusion & Raymarching Settings
uniform float extrusion_depth : hint_range(0.001, 0.1) = 0.03;
uniform int max_ray_steps : hint_range(16, 256) = 128;
uniform float ray_step_size : hint_range(0.0001, 0.01) = 0.002;
uniform float alpha_threshold : hint_range(0.0, 1.0) = 0.9;
uniform float edge_softness : hint_range(0.0, 1.0) = 1.0;

// Blur Settings
uniform float blur_amount : hint_range(0.0, 0.02) = 0.004;
uniform int blur_kernel_size : hint_range(1, 7) = 6;

// Lighting Settings
uniform float light_ambient : hint_range(0.0, 5.0) = 0.85;
uniform float light_diffuse : hint_range(0.0, 5.0) = 0.275;
uniform float front_face_brightness : hint_range(0.0, 2.0) = 1.0;

// Anti-aliasing / Supersampling
uniform int supersample_level : hint_range(1, 4) = 2;

// Constants (don't change)
const float ICON_SIZE = 256.0;
const float ATLAS_WIDTH = 2304.0;
const float ATLAS_HEIGHT = 2048.0;
const float ICONS_PER_ROW = 9.0;

float hash(vec2 p) {
    return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

vec3 hash3(vec2 p) {
    return vec3(hash(p), hash(p + vec2(1.0, 0.0)), hash(p + vec2(0.0, 1.0)));
}

vec3 spherical_to_cartesian(float theta, float phi, float radius) {
    return vec3(
        radius * sin(phi) * cos(theta),
        radius * cos(phi),
        radius * sin(phi) * sin(theta)
    );
}

vec4 sample_icon(int icon_index, vec2 uv) {
    float row = floor(float(icon_index) / ICONS_PER_ROW);
    float icon_col = mod(float(icon_index), ICONS_PER_ROW);
    vec2 pixel_pos = vec2(
        icon_col * ICON_SIZE + uv.x * ICON_SIZE,
        row * (ICON_SIZE + 1.0) + uv.y * ICON_SIZE
    );
    vec4 col = texture(icon_atlas, pixel_pos / vec2(ATLAS_WIDTH, ATLAS_HEIGHT));
    // Premultiply alpha to fix dark halos from transparent black pixels
    return vec4(col.rgb * col.a, col.a);
}

float get_height(int icon_index, vec2 uv) {
    return sample_icon(icon_index, uv).a * extrusion_depth;
}

float get_height_smooth(int icon_index, vec2 uv) {
    vec2 texel = uv * ICON_SIZE;
    vec2 texel_floor = floor(texel);
    vec2 texel_frac = texel - texel_floor;
    
    vec2 uv00 = texel_floor / ICON_SIZE;
    vec2 uv10 = (texel_floor + vec2(1.0, 0.0)) / ICON_SIZE;
    vec2 uv01 = (texel_floor + vec2(0.0, 1.0)) / ICON_SIZE;
    vec2 uv11 = (texel_floor + vec2(1.0, 1.0)) / ICON_SIZE;
    
    float h00 = get_height(icon_index, uv00);
    float h10 = get_height(icon_index, uv10);
    float h01 = get_height(icon_index, uv01);
    float h11 = get_height(icon_index, uv11);
    
    return mix(mix(h00, h10, texel_frac.x), mix(h01, h11, texel_frac.x), texel_frac.y);
}

mat3 rotate_x(float angle) {
    float c = cos(angle), s = sin(angle);
    return mat3(vec3(1.0, 0.0, 0.0), vec3(0.0, c, -s), vec3(0.0, s, c));
}

mat3 rotate_y(float angle) {
    float c = cos(angle), s = sin(angle);
    return mat3(vec3(c, 0.0, s), vec3(0.0, 1.0, 0.0), vec3(-s, 0.0, c));
}

mat3 rotate_z(float angle) {
    float c = cos(angle), s = sin(angle);
    return mat3(vec3(c, -s, 0.0), vec3(s, c, 0.0), vec3(0.0, 0.0, 1.0));
}

vec3 calc_normal(int icon_index, vec2 uv, float scale,
                 vec3 icon_right, vec3 icon_up, vec3 icon_normal) {
    float eps = 1.0 / ICON_SIZE;
    
    float h_c = get_height_smooth(icon_index, uv);
    float h_r = get_height_smooth(icon_index, uv + vec2(eps, 0.0));
    float h_l = get_height_smooth(icon_index, uv - vec2(eps, 0.0));
    float h_u = get_height_smooth(icon_index, uv + vec2(0.0, eps));
    float h_d = get_height_smooth(icon_index, uv - vec2(0.0, eps));
    
    float dx = (h_r - h_l) * 0.5;
    float dy = (h_u - h_d) * 0.5;
    
    return normalize(icon_normal + icon_right * (dx / eps) + icon_up * (dy / eps));
}

// Improved render_ray with continuous alpha sampling and adaptive stepping
vec4 render_ray(vec2 uv, float aspect) {
    vec3 camera_pos = vec3(0.0, 0.0, -4.0);
    vec3 ray_dir = normalize(vec3(uv, 1.5));
    
    float time = TIME * orbit_speed * time_scale;
    vec3 light = normalize(light_direction);
    
    float closest_t = 9999.0;
    vec3 closest_normal = vec3(0.0, 0.0, 1.0);
    vec3 closest_color = vec3(0.0);
    float closest_alpha = 0.0;
    bool hit = false;
    
    for (int i = 0; i < num_icons && i < 12; i++) {
        float fi = float(i);
        vec3 seed_vec = hash3(vec2(fi, 0.0));
        
        float orbit_angle = time * (0.5 + seed_vec.x * 0.5) + fi * 6.28318 / float(num_icons);
        vec3 icon_center = spherical_to_cartesian(orbit_angle, 1.57 + sin(time * 0.3 + fi) * 0.5, orbit_radius);
        
        float rot_time = time * rotation_speed;
        mat3 rot_mat = rotate_z(seed_vec.z * 6.28318 + rot_time * 0.15) *
                      rotate_y(seed_vec.y * 6.28318 + rot_time * 0.25) *
                      rotate_x(seed_vec.x * 6.28318 + rot_time * 0.35);
        
        vec3 icon_right = rot_mat * vec3(1.0, 0.0, 0.0);
        vec3 icon_up = rot_mat * vec3(0.0, 1.0, 0.0);
        vec3 icon_normal = rot_mat * vec3(0.0, 0.0, 1.0);
        
        float size_variation = 0.6 + hash(seed_vec.xy) * 0.4;
        float scale = icon_scale * size_variation;
        int icon_index = int(floor(seed_vec.x * 72.0)) % 72;
        
        vec3 local_origin = vec3(
            dot(camera_pos - icon_center, icon_right),
            dot(camera_pos - icon_center, icon_up),
            dot(camera_pos - icon_center, icon_normal)
        );
        vec3 local_dir = vec3(
            dot(ray_dir, icon_right),
            dot(ray_dir, icon_up),
            dot(ray_dir, icon_normal)
        );
        
        vec3 box_min = vec3(-scale * 0.5, -scale * 0.5, -extrusion_depth);
        vec3 box_max = vec3(scale * 0.5, scale * 0.5, 0.0);
        
        vec3 inv_rd = 1.0 / local_dir;
        vec3 t1 = (box_min - local_origin) * inv_rd;
        vec3 t2 = (box_max - local_origin) * inv_rd;
        vec3 t_near = min(t1, t2);
        vec3 t_far = max(t1, t2);
        float t_start = max(max(t_near.x, t_near.y), t_near.z);
        float t_end = min(min(t_far.x, t_far.y), t_far.z);
        
        if (t_end <= max(t_start, 0.0)) continue;
        
        float t = max(t_start, 0.0);
        float prev_alpha = 0.0;
        vec2 prev_uv = vec2(0.0);
        
        for (int step = 0; step < max_ray_steps; step++) {
            vec3 pos = local_origin + local_dir * t;
            vec2 uv_local = vec2(pos.x / scale + 0.5, pos.y / scale + 0.5);
            
            bool in_uv = uv_local.x >= 0.0 && uv_local.x <= 1.0 && 
                        uv_local.y >= 0.0 && uv_local.y <= 1.0;
            
            if (!in_uv) {
                prev_alpha = 0.0;
                t += ray_step_size;
                if (t > t_end) break;
                continue;
            }
            
            vec4 col = sample_icon(icon_index, clamp(uv_local, 0.0, 1.0));
            float height = col.a * extrusion_depth;
            bool inside = pos.z >= -height && pos.z <= 0.0;
            
            // Check if we're entering the volume (alpha transition from low to high)
            if (inside && col.a > alpha_threshold) {
                vec3 world_pos = icon_center + icon_right * pos.x + icon_up * pos.y + icon_normal * pos.z;
                float world_t = length(world_pos - camera_pos);
                
                if (world_t < closest_t) {
                    closest_t = world_t;
                    closest_normal = calc_normal(icon_index, uv_local, scale, icon_right, icon_up, icon_normal);
                    closest_color = col.rgb;
                    closest_alpha = col.a;
                    hit = true;
                    
                    // Don't break - we want to find the closest hit across all icons
                }
            }
            
            // Adaptive step size: smaller steps when near the surface
            float dist_to_surface = abs(pos.z + height);
            float adaptive_step = mix(ray_step_size * 0.25, ray_step_size, smoothstep(0.0, 0.01, dist_to_surface));
            
            prev_alpha = col.a;
            prev_uv = uv_local;
            t += adaptive_step;
            if (t > t_end) break;
        }
    }
    
    if (hit && closest_alpha > 0.0) {
        float NdotL = max(0.0, dot(closest_normal, light));
        float diffuse = light_ambient + light_diffuse * NdotL;
        vec3 final_color = closest_color * diffuse * front_face_brightness;
        return vec4(final_color * closest_alpha, closest_alpha);
    }
    
    return vec4(0.0);
}

void fragment() {
    vec2 uv = UV * 2.0 - 1.0;
    // Stretch vertically by ~10% (divide by 1.1 = multiply by 0.909)
    uv.y *= 0.909;
    float aspect = (1.0 / SCREEN_PIXEL_SIZE).x / (1.0 / SCREEN_PIXEL_SIZE).y;
    
    // Calculate pixel size for supersampling
    vec2 pixel_size = SCREEN_PIXEL_SIZE * 2.0; // UV range is -1 to 1
    
    vec4 final_color = vec4(0.0);
    
    // Supersampling anti-aliasing
    // Sample at subpixel offsets and average
    if (supersample_level <= 1) {
        // No supersampling - single sample
        final_color = render_ray(uv, aspect);
    } else if (supersample_level == 2) {
        // 2x2 supersampling (4 samples)
        vec2 offsets[4] = vec2[](
            vec2(-0.25, -0.25),
            vec2( 0.25, -0.25),
            vec2(-0.25,  0.25),
            vec2( 0.25,  0.25)
        );
        
        for (int i = 0; i < 4; i++) {
            vec2 sample_uv = uv + offsets[i] * pixel_size;
            vec4 sample = render_ray(sample_uv, aspect);
            final_color += vec4(sample.rgb * sample.a, sample.a);
        }
        final_color /= 4.0;
    } else if (supersample_level == 3) {
        // 3x3 supersampling (9 samples)
        for (float x = -1.0; x <= 1.0; x += 1.0) {
            for (float y = -1.0; y <= 1.0; y += 1.0) {
                vec2 sample_uv = uv + vec2(x, y) * pixel_size / 3.0;
                vec4 sample = render_ray(sample_uv, aspect);
                final_color += vec4(sample.rgb * sample.a, sample.a);
            }
        }
        final_color /= 9.0;
    } else {
        // 4x4 supersampling (16 samples)
        for (float x = -1.5; x <= 1.5; x += 1.0) {
            for (float y = -1.5; y <= 1.5; y += 1.0) {
                vec2 sample_uv = uv + vec2(x, y) * pixel_size / 4.0;
                vec4 sample = render_ray(sample_uv, aspect);
                final_color += vec4(sample.rgb * sample.a, sample.a);
            }
        }
        final_color /= 16.0;
    }
    
    // Blur for out-of-focus depth-of-field effect
    vec4 blurred_color = vec4(0.0);
    float total_weight = 0.0;
    
    // Calculate kernel bounds based on blur_kernel_size
    float kernel_half = float(blur_kernel_size - 1) / 2.0;
    float kernel_samples = float(blur_kernel_size * blur_kernel_size);
    
    // Dynamic kernel sampling with proper alpha-premultiplied blending
    // This prevents dark halos by properly handling transparent regions
    for(float x = -kernel_half; x <= kernel_half; x += 1.0) {
        for(float y = -kernel_half; y <= kernel_half; y += 1.0) {
            vec2 offset = vec2(x, y) * blur_amount * 0.5;
            vec4 sample = render_ray(uv + offset, aspect);
            // Accumulate premultiplied: (RGB * A, A)
            blurred_color += vec4(sample.rgb * sample.a, sample.a);
            total_weight += sample.a;
        }
    }
    
    // Normalize by sample count (not by weight) to preserve alpha
    // This ensures transparent areas stay transparent without dark fringes
    blurred_color /= kernel_samples;
    
    // Full blur - no mixing with original
    // Output is already premultiplied: (RGB * A, A)
    final_color = blurred_color;
    
    COLOR = final_color;
}
