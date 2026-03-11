shader_type canvas_item;

// WiiU Menu - TRUE 3D Alpha Extrusion with Flat Shading

uniform sampler2D icon_atlas : source_color, repeat_disable, filter_linear;
uniform float time_scale : hint_range(0.0, 2.0) = 0.5;
uniform float orbit_radius : hint_range(1.0, 5.0) = 2.5;
uniform float icon_scale : hint_range(0.1, 1.0) = 0.4;
uniform float orbit_speed : hint_range(0.05, 1.0) = 0.15;
uniform int num_icons : hint_range(5, 30) = 15;
uniform vec3 light_direction = vec3(0.7, -0.7, 0.0);
uniform vec4 background_color : source_color = vec4(0.1, 0.1, 0.15, 1.0);
uniform float rotation_speed : hint_range(0.0, 2.0) = 0.3;

const float ICON_SIZE = 128.0;
const float ATLAS_WIDTH = 1152.0;
const float ATLAS_HEIGHT = 1024.0;
const float ICONS_PER_ROW = 9.0;
const float EXTRUSION_DEPTH = 0.05;
const int MAX_STEPS = 64;
const float STEP_SIZE = 0.004;
const float ALPHA_THRESHOLD = 0.1;

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
    float col = mod(float(icon_index), ICONS_PER_ROW);
    vec2 pixel_pos = vec2(
        col * ICON_SIZE + uv.x * ICON_SIZE,
        row * (ICON_SIZE + 1.0) + uv.y * ICON_SIZE
    );
    return texture(icon_atlas, pixel_pos / vec2(ATLAS_WIDTH, ATLAS_HEIGHT));
}

float get_height(int icon_index, vec2 uv) {
    return sample_icon(icon_index, uv).a * EXTRUSION_DEPTH;
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

// Render a single ray sample
vec3 render_ray(vec2 uv, float aspect) {
    vec3 camera_pos = vec3(0.0, 0.0, -4.0);
    vec3 ray_dir = normalize(vec3(uv, 1.5));
    
    float time = TIME * orbit_speed * time_scale;
    vec3 light = normalize(light_direction);
    
    float closest_t = 9999.0;
    vec3 closest_normal;
    vec3 closest_color;
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
        
        float scale = icon_scale;
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
        
        vec3 box_min = vec3(-scale * 0.5, -scale * 0.5, -EXTRUSION_DEPTH);
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
        bool was_inside = false;
        vec2 prev_uv = vec2(0.0);
        
        for (int step = 0; step < MAX_STEPS; step++) {
            vec3 pos = local_origin + local_dir * t;
            vec2 uv_local = vec2(pos.x / scale + 0.5, pos.y / scale + 0.5);
            
            bool in_uv = uv_local.x >= 0.0 && uv_local.x <= 1.0 && 
                        uv_local.y >= 0.0 && uv_local.y <= 1.0;
            
            bool inside = false;
            float height = 0.0;
            
            if (in_uv) {
                height = get_height_smooth(icon_index, uv_local);
                inside = pos.z >= -height && pos.z <= 0.0;
            }
            
            // Entry point
            if (inside && !was_inside) {
                vec4 col = sample_icon(icon_index, clamp(uv_local, 0.0, 1.0));
                
                if (col.a > ALPHA_THRESHOLD) {
                    vec3 world_pos = icon_center + icon_right * pos.x + icon_up * pos.y + icon_normal * pos.z;
                    float world_t = length(world_pos - camera_pos);
                    
                    if (world_t < closest_t) {
                        closest_t = world_t;
                        closest_normal = calc_normal(icon_index, uv_local, scale, icon_right, icon_up, icon_normal);
                        closest_color = col.rgb;
                        hit = true;
                    }
                    break;
                }
            }
            
            was_inside = inside;
            prev_uv = uv_local;
            t += STEP_SIZE;
            if (t > t_end) break;
        }
    }
    
    if (hit) {
        float NdotL = max(0.0, dot(closest_normal, light));
        float diffuse = 0.3 + 0.7 * NdotL;
        return closest_color * diffuse;
    }
    
    return background_color.rgb;
}

void fragment() {
    vec2 uv = UV * 2.0 - 1.0;
    float aspect = (1.0 / SCREEN_PIXEL_SIZE).x / (1.0 / SCREEN_PIXEL_SIZE).y;
    
    // 2x2 supersampling for anti-aliasing
    vec2 pixel_offset = vec2(SCREEN_PIXEL_SIZE.x * aspect, SCREEN_PIXEL_SIZE.y);
    
    vec3 col00 = render_ray(uv + vec2(-0.5, -0.5) * pixel_offset, aspect);
    vec3 col01 = render_ray(uv + vec2(-0.5, 0.5) * pixel_offset, aspect);
    vec3 col10 = render_ray(uv + vec2(0.5, -0.5) * pixel_offset, aspect);
    vec3 col11 = render_ray(uv + vec2(0.5, 0.5) * pixel_offset, aspect);
    
    vec3 final_color = (col00 + col01 + col10 + col11) * 0.25;
    
    COLOR = vec4(final_color, 1.0);
}
