shader_type canvas_item;

// WiiU Menu - TRUE 3D Alpha Extrusion (Solid Volumes)

uniform sampler2D icon_atlas : source_color, repeat_disable, filter_linear;
uniform float time_scale : hint_range(0.0, 2.0) = 0.5;
uniform float orbit_radius : hint_range(1.0, 5.0) = 2.5;
uniform float icon_scale : hint_range(0.1, 1.0) = 0.4;
uniform float orbit_speed : hint_range(0.05, 1.0) = 0.15;
uniform int num_icons : hint_range(5, 30) = 15;
uniform vec3 light_direction = vec3(0.5, 0.5, 1.0);
uniform vec4 background_color : source_color = vec4(0.1, 0.1, 0.15, 1.0);
uniform float rotation_speed : hint_range(0.0, 2.0) = 0.3;

const float ICON_SIZE = 128.0;
const float ATLAS_WIDTH = 1152.0;
const float ATLAS_HEIGHT = 1024.0;
const float ICONS_PER_ROW = 9.0;
const float EXTRUSION_DEPTH = 0.05;
const int MAX_STEPS = 128;
const float STEP_SIZE = 0.003;
const int MAX_HITS = 30;
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

// Bilinear sampled height
float get_height_smooth(int icon_index, vec2 uv) {
    vec2 texel = uv * ICON_SIZE;
    vec2 texel_floor = floor(texel);
    vec2 texel_frac = texel - texel_floor;
    
    vec2 uv00 = (texel_floor) / ICON_SIZE;
    vec2 uv10 = (texel_floor + vec2(1.0, 0.0)) / ICON_SIZE;
    vec2 uv01 = (texel_floor + vec2(0.0, 1.0)) / ICON_SIZE;
    vec2 uv11 = (texel_floor + vec2(1.0, 1.0)) / ICON_SIZE;
    
    float h00 = get_height(icon_index, uv00);
    float h10 = get_height(icon_index, uv10);
    float h01 = get_height(icon_index, uv01);
    float h11 = get_height(icon_index, uv11);
    
    float h0 = mix(h00, h10, texel_frac.x);
    float h1 = mix(h01, h11, texel_frac.x);
    
    return mix(h0, h1, texel_frac.y);
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

mat3 rotate_x(float angle) {
    float c = cos(angle), s = sin(angle);
    return mat3(
        vec3(1.0, 0.0, 0.0),
        vec3(0.0, c, -s),
        vec3(0.0, s, c)
    );
}

mat3 rotate_y(float angle) {
    float c = cos(angle), s = sin(angle);
    return mat3(
        vec3(c, 0.0, s),
        vec3(0.0, 1.0, 0.0),
        vec3(-s, 0.0, c)
    );
}

mat3 rotate_z(float angle) {
    float c = cos(angle), s = sin(angle);
    return mat3(
        vec3(c, -s, 0.0),
        vec3(s, c, 0.0),
        vec3(0.0, 0.0, 1.0)
    );
}

void fragment() {
    vec2 uv = UV * 2.0 - 1.0;
    float aspect = (1.0 / SCREEN_PIXEL_SIZE).x / (1.0 / SCREEN_PIXEL_SIZE).y;
    uv.x *= aspect;
    
    vec3 camera_pos = vec3(0.0, 0.0, -4.0);
    vec3 ray_dir = normalize(vec3(uv, 1.5));
    
    vec3 final_color = background_color.rgb;
    float final_alpha = 0.0;
    
    float time = TIME * orbit_speed * time_scale;
    vec3 light = normalize(light_direction);
    
    // Store hits
    float hit_t[MAX_HITS];
    vec3 hit_normal[MAX_HITS];
    vec3 hit_color[MAX_HITS];
    int hit_count = 0;
    
    for (int i = 0; i < num_icons && i < 12 && hit_count < MAX_HITS; i++) {
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
        
        // Transform ray to local space
        vec3 local_ray_origin = vec3(
            dot(camera_pos - icon_center, icon_right),
            dot(camera_pos - icon_center, icon_up),
            dot(camera_pos - icon_center, icon_normal)
        );
        vec3 local_ray_dir = vec3(
            dot(ray_dir, icon_right),
            dot(ray_dir, icon_up),
            dot(ray_dir, icon_normal)
        );
        
        // Bounding box
        vec3 box_min = vec3(-scale * 0.5, -scale * 0.5, -EXTRUSION_DEPTH);
        vec3 box_max = vec3(scale * 0.5, scale * 0.5, 0.0);
        
        vec3 inv_rd = 1.0 / local_ray_dir;
        vec3 t1 = (box_min - local_ray_origin) * inv_rd;
        vec3 t2 = (box_max - local_ray_origin) * inv_rd;
        vec3 t_near = min(t1, t2);
        vec3 t_far = max(t1, t2);
        float t_start = max(max(t_near.x, t_near.y), t_near.z);
        float t_end = min(min(t_far.x, t_far.y), t_far.z);
        
        if (t_end <= max(t_start, 0.0)) continue;
        
        // Raymarch - find first solid surface
        float t = max(t_start, 0.0);
        bool found_hit = false;
        vec3 hit_local;
        vec2 hit_uv;
        
        for (int step = 0; step < MAX_STEPS; step++) {
            vec3 pos = local_ray_origin + local_ray_dir * t;
            vec2 uv_local = vec2(pos.x / scale + 0.5, pos.y / scale + 0.5);
            
            if (uv_local.x >= 0.0 && uv_local.x <= 1.0 && 
                uv_local.y >= 0.0 && uv_local.y <= 1.0) {
                
                float height = get_height_smooth(icon_index, uv_local);
                
                // Check if we're inside the solid volume
                if (pos.z >= -height && pos.z <= 0.0) {
                    // Found the entry point - this is our surface
                    found_hit = true;
                    hit_local = pos;
                    hit_uv = uv_local;
                    break;
                }
            }
            
            t += STEP_SIZE;
            if (t > t_end) break;
        }
        
        // Render the solid front surface
        if (found_hit && hit_count < MAX_HITS) {
            vec4 col = sample_icon(icon_index, clamp(hit_uv, 0.0, 1.0));
            
            if (col.a > ALPHA_THRESHOLD) {
                // Calculate normal
                vec3 normal = calc_normal(icon_index, hit_uv, scale, icon_right, icon_up, icon_normal);
                
                vec3 world_pos = icon_center + icon_right * hit_local.x + icon_up * hit_local.y + icon_normal * hit_local.z;
                
                hit_t[hit_count] = length(world_pos - camera_pos);
                hit_normal[hit_count] = normal;
                hit_color[hit_count] = col.rgb;
                hit_count++;
            }
        }
    }
    
    // Sort by depth
    for (int i = 0; i < hit_count - 1; i++) {
        for (int j = i + 1; j < hit_count; j++) {
            if (hit_t[j] > hit_t[i]) {
                float temp_t = hit_t[i];
                hit_t[i] = hit_t[j];
                hit_t[j] = temp_t;
                
                vec3 temp_norm = hit_normal[i];
                hit_normal[i] = hit_normal[j];
                hit_normal[j] = temp_norm;
                
                vec3 temp_col = hit_color[i];
                hit_color[i] = hit_color[j];
                hit_color[j] = temp_col;
            }
        }
    }
    
    // Composite - treat as solid objects
    for (int i = 0; i < hit_count && final_alpha < 0.99; i++) {
        vec3 normal = hit_normal[i];
        vec3 col = hit_color[i];
        
        float NdotL = max(0.0, dot(normal, light));
        float diffuse = 0.3 + 0.7 * NdotL;
        
        vec3 view_dir = -ray_dir;
        vec3 half_vec = normalize(light + view_dir);
        float specular = pow(max(0.0, dot(normal, half_vec)), 32.0) * 0.3;
        
        vec3 lit = col * diffuse + vec3(specular);
        
        // Solid compositing - full opacity where we hit
        final_color = mix(final_color, lit, 1.0 - final_alpha);
        final_alpha = 1.0; // Block everything behind
    }
    
    COLOR = vec4(final_color, 1.0);
}
