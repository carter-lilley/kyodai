shader_type canvas_item;

// OSDSYS Background Effect - Overlay Version
// Based on PS2 OSDSYS visual style with 8 orbiting particles

#define PARTICLE_COUNT 8.0

vec3 rotate_x(vec3 p, float a) {
    float c = cos(a);
    float s = sin(a);
    vec3 q = p;
    p.y = c * q.y - s * q.z;
    p.z = s * q.y + c * q.z;
    return p;
}

vec3 rotate_y(vec3 p, float a) {
    float c = cos(a);
    float s = sin(a);
    vec3 q = p;
    p.x = c * q.x + s * q.z;
    p.z = -s * q.x + c * q.z;
    return p;
}

vec3 rotate_z(vec3 p, float a) {
    float c = cos(a);
    float s = sin(a);
    vec3 q = p;
    p.x = c * q.x - s * q.y;
    p.y = s * q.x + c * q.y;
    return p;
}

vec2 orbit_position(float dir, float dist) {
    return vec2(cos(dir) * dist, sin(dir) * dist);
}

vec3 calculate_particles(vec2 uv, float time) {
    vec3 circles = vec3(0.0);
    
    for (float k = 0.0; k < PARTICLE_COUNT; k++) {
        float i = (k / 7.0) * 3.14159265359;
        float speed = k * 0.1;
        float DISTANCE = 0.2;
        
        // Draw trail by sampling previous positions
        for (float t = 0.0; t < 8.0; t++) {
            float trail_time = time - t * 0.02;
            float DIRECTION = trail_time * speed;
            
            vec3 POSITION = vec3(orbit_position(DIRECTION, DISTANCE), 0.0);
            POSITION = rotate_y(POSITION, trail_time * 1.1);
            POSITION = rotate_z(POSITION, trail_time * 2.15);
            POSITION = rotate_x(POSITION, trail_time * 0.52);
            
            float dist = length(uv - POSITION.xy);
            float intensity = clamp(1.0 - dist * 40.0, 0.0, 1.0);
            
            // Fade trail based on age
            float trail_fade = 1.0 - (t / 8.0);
            intensity *= trail_fade * 0.6;
            
            circles = max(circles, vec3(intensity));
        }
    }
    
    circles = clamp(circles, 0.0, 1.0);
    return circles;
}

void fragment() {
    vec2 uv = UV;
    vec2 suv = uv - 0.5;
    
    // Correct aspect ratio
    float aspect = (1.0 / SCREEN_PIXEL_SIZE).y / (1.0 / SCREEN_PIXEL_SIZE).x;
    suv.x /= aspect;
    
    float time = TIME;
    vec3 drawing = calculate_particles(suv, time);
    
    // Apply color curve for blue tint
    drawing = vec3(pow(drawing, vec3(2.5, 1.8, 1.0)));
    
    // Calculate alpha based on particle intensity
    float alpha = max(drawing.r, max(drawing.g, drawing.b));

    // Transparent where no particles — layers beneath show through
    COLOR = vec4(drawing, alpha);
}
