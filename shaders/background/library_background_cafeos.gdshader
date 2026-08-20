shader_type canvas_item;

// CafeOS - TRUE 3D Alpha Extrusion with Flat Shading

uniform sampler2D icon_atlas : source_color, repeat_disable, filter_linear_mipmap;
uniform float time_scale : hint_range(0.0, 2.0) = 0.5;
uniform float orbit_radius : hint_range(1.0, 5.0) = 2.358;
uniform float icon_scale : hint_range(0.1, 1.0) = 0.7;
uniform float orbit_speed : hint_range(0.05, 1.0) = 0.15;
uniform int num_icons : hint_range(5, 30) = 21;
uniform vec3 light_direction = vec3(1.0, 1.0, 0.0);

uniform float rotation_speed : hint_range(0.0, 2.0) = 0.3;

// 3D Extrusion & Raymarching Settings
uniform float extrusion_depth : hint_range(0.001, 0.1) = 0.03;
uniform int max_ray_steps : hint_range(16, 256) = 16;
uniform float ray_step_size : hint_range(0.0001, 0.01) = 0.002;
uniform float alpha_threshold : hint_range(0.0, 1.0) = 0.9;
uniform float edge_softness : hint_range(0.0, 1.0) = 1.0;

// Blur Settings (implemented as capped LOD bias, not a re-raymarch kernel)
uniform float blur_amount : hint_range(0.0, 0.02) = 0.004;
uniform int blur_kernel_size : hint_range(1, 7) = 6;  // UNUSED (kept for preset compat)

// Weighted silhouette test: pixels below alpha_threshold stay fully culled
// (matching the original hard cutoff), fading in only above it.
float hit_weight(float alpha) {
    return smoothstep(alpha_threshold,
                      alpha_threshold + max(edge_softness * 0.1, 0.01), alpha);
}

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

vec4 sample_icon(int icon_index, vec2 uv, float lod_bias) {
    float row = floor(float(icon_index) / ICONS_PER_ROW);
    float icon_col = mod(float(icon_index), ICONS_PER_ROW);
    vec2 pixel_pos = vec2(
        icon_col * ICON_SIZE + uv.x * ICON_SIZE,
        row * (ICON_SIZE + 1.0) + uv.y * ICON_SIZE
    );
    vec4 col = textureLod(icon_atlas, pixel_pos / vec2(ATLAS_WIDTH, ATLAS_HEIGHT), lod_bias);
    // Premultiply alpha to fix dark halos from transparent black pixels
    return vec4(col.rgb * col.a, col.a);
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

// Optimized render_ray: analytic front-face intersection per icon (one sample)
// plus a short depth-slab march for extrusion side walls (<= max_ray_steps).
vec4 render_ray(vec2 uv, float aspect, float lod_bias) {
    vec3 camera_pos = vec3(0.0, 0.0, -4.0);
    vec3 ray_dir = normalize(vec3(uv.x * aspect, uv.y, 1.5));

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

        float t0 = max(t_start, 0.0);
        bool icon_hit = false;

        // --- Analytic front face (z = 0 plane): one sample, one alpha test ---
        if (abs(local_dir.z) > 1e-5) {
            float t_plane = -local_origin.z / local_dir.z;
            if (t_plane >= t0 && t_plane <= t_end) {
                vec3 pos = local_origin + local_dir * t_plane;
                vec2 uv_local = pos.xy / scale + 0.5;
                if (uv_local.x >= 0.0 && uv_local.x <= 1.0 &&
                    uv_local.y >= 0.0 && uv_local.y <= 1.0) {
                    vec4 col = sample_icon(icon_index, uv_local, lod_bias);
                    float w = hit_weight(col.a);
                    if (w > 0.0) {
                        float world_t = length(icon_center + icon_right * pos.x + icon_up * pos.y - camera_pos);
                        if (world_t < closest_t) {
                            closest_t = world_t;
                            closest_normal = icon_normal;
                            closest_color = col.rgb * w;
                            closest_alpha = col.a * w;
                            hit = true;
                        }
                        icon_hit = true;
                    }
                }
            }
        }

        // --- Extrusion side walls: short march through the depth slab only ---
        if (icon_hit) continue;

        float slab_start = t0;
        float slab_end = t_end;
        if (abs(local_dir.z) > 1e-5) {
            float tz0 = -local_origin.z / local_dir.z;
            float tzd = -(local_origin.z + extrusion_depth) / local_dir.z;
            slab_start = max(t0, min(tz0, tzd));
            slab_end = min(t_end, max(tz0, tzd));
        }
        if (slab_end <= slab_start) continue;

        float slab_len = slab_end - slab_start;
        int steps = clamp(int(ceil(slab_len / ray_step_size)), 1, max_ray_steps);
        float step_size = slab_len / float(steps);
        float t = slab_start;

        for (int s = 0; s < steps; s++) {
            vec3 pos = local_origin + local_dir * t;
            vec2 uv_local = pos.xy / scale + 0.5;

            if (uv_local.x >= 0.0 && uv_local.x <= 1.0 &&
                uv_local.y >= 0.0 && uv_local.y <= 1.0) {
                vec4 col = sample_icon(icon_index, uv_local, lod_bias);
                float height = col.a * extrusion_depth;
                if (pos.z >= -height && pos.z <= 0.0) {
                    float w = hit_weight(col.a);
                    if (w > 0.0) {
                        vec3 world_pos = icon_center + icon_right * pos.x + icon_up * pos.y + icon_normal * pos.z;
                        float world_t = length(world_pos - camera_pos);
                        if (world_t < closest_t) {
                            closest_t = world_t;
                            // Flat-shaded wall normal from the dominant axis
                            closest_normal = abs(pos.x) > abs(pos.y) ? icon_right * sign(pos.x) : icon_up * sign(pos.y);
                            closest_color = col.rgb * w;
                            closest_alpha = col.a * w;
                            hit = true;
                        }
                        break;
                    }
                }
            }
            t += step_size;
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
    float aspect = (1.0 / SCREEN_PIXEL_SIZE).x / (1.0 / SCREEN_PIXEL_SIZE).y;

    // Calculate pixel size for supersampling
    vec2 pixel_size = SCREEN_PIXEL_SIZE * 2.0; // UV range is -1 to 1

    // Premultiplied accumulation of icon rays; composited over layers beneath
    vec4 final_color = vec4(0.0);

    if (blur_amount > 0.0) {
        // Depth-of-field: 6x6 kernel of (now cheap, analytic) rays with proper
        // premultiplied blending to avoid dark fringes. Same offsets/width as
        // the original blur; affordable now that each ray costs ~2 fetches.
        float kernel_half = float(blur_kernel_size - 1) / 2.0;
        float kernel_samples = float(blur_kernel_size * blur_kernel_size);
        for (float x = -kernel_half; x <= kernel_half; x += 1.0) {
            for (float y = -kernel_half; y <= kernel_half; y += 1.0) {
                vec2 offset = vec2(x, y) * blur_amount * 0.5;
                vec4 sample = render_ray(uv + offset, aspect, 0.0);
                final_color += vec4(sample.rgb * sample.a, sample.a);
            }
        }
        final_color /= kernel_samples;
    } else if (supersample_level <= 1) {
        // No blur, no supersampling - single sharp sample
        vec4 sample0 = render_ray(uv, aspect, 0.0);
        final_color = vec4(sample0.rgb * sample0.a, sample0.a);
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
            vec4 sample = render_ray(sample_uv, aspect, 0.0);
            final_color += vec4(sample.rgb * sample.a, sample.a);
        }
        final_color /= 4.0;
    } else if (supersample_level == 3) {
        // 3x3 supersampling (9 samples)
        for (float x = -1.0; x <= 1.0; x += 1.0) {
            for (float y = -1.0; y <= 1.0; y += 1.0) {
                vec2 sample_uv = uv + vec2(x, y) * pixel_size / 3.0;
                vec4 sample = render_ray(sample_uv, aspect, 0.0);
                final_color += vec4(sample.rgb * sample.a, sample.a);
            }
        }
        final_color /= 9.0;
    } else {
        // 4x4 supersampling (16 samples)
        for (float x = -1.5; x <= 1.5; x += 1.0) {
            for (float y = -1.5; y <= 1.5; y += 1.0) {
                vec2 sample_uv = uv + vec2(x, y) * pixel_size / 4.0;
                vec4 sample = render_ray(sample_uv, aspect, 0.0);
                final_color += vec4(sample.rgb * sample.a, sample.a);
            }
        }
        final_color /= 16.0;
    }

    // Un-premultiply and output with alpha so icons composite over the
    // layers beneath (transparent where no icon was hit).
    float out_a = clamp(final_color.a, 0.0, 1.0);
    vec3 out_rgb = final_color.rgb / max(final_color.a, 1e-4);
    COLOR = vec4(clamp(out_rgb, vec3(0.0), vec3(1.0)), out_a);
}
