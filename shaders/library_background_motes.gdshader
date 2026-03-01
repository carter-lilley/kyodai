shader_type canvas_item;

const float MATH_PI = float(3.14159265359);

void Rotate(inout vec2 p, float a) {
	p = cos(a) * p + sin(a) * vec2(p.y, -p.x);
}

float Circle(vec2 p, float r) {
    return (length(p / r) - 1.0) * r;
}

float Rand(vec2 c) {
	return fract(sin(dot(c.xy, vec2(12.9898, 78.233))) * 43758.5453);
}

float saturate(float x) {
	return clamp(x, 0.0, 1.0);
}

void BokehLayer(inout vec3 color, vec2 p, vec3 c) {
    float wrap = 450.0;
    if (mod(floor(p.y / wrap + 0.5), 2.0) == 0.0) {
        p.x += wrap * 0.5;
    }
    
    vec2 p2 = mod(p + 0.5 * wrap, wrap) - 0.5 * wrap;
    vec2 cell = floor(p / wrap + 0.5);
    float cellR = Rand(cell);
    
    c *= fract(cellR * 3.33 + 3.33);
    float radius = mix(10.0, 7.0, fract(cellR * 7.77 + 7.77));
    p2.x *= mix(0.9, 1.1, fract(cellR * 11.13 + 11.13));
    p2.y *= mix(0.9, 1.1, fract(cellR * 17.17 + 17.17));
    
    float sdf = Circle(p2, radius);
    float circle = 1.0 - smoothstep(0.0, 1.0, sdf * 0.04);
    float glow = exp(-sdf * 0.025) * 0.3 * (1.0 - circle);
    color += vec3(0.0, c.g, 0.0) * (circle + glow);
}

void fragment() {
    vec2 uv = UV;
    vec2 p = (2.0 * FRAGCOORD.xy - (1.0 / SCREEN_PIXEL_SIZE).xy) / (1.0 / SCREEN_PIXEL_SIZE).x * 1000.0;
    
    // background - pure black
    vec3 color = vec3(0.0, 0.0, 0.0);
    
    float time = TIME / 5.0;
    
    Rotate(p, 0.2 + time * 0.03);
    BokehLayer(color, p + vec2(-50.0 * time + 0.0 + Rand(vec2(1.0, 2.0)) * 200.0, 0.0), 3.0 * vec3(0.4, 0.1, 0.2));
    Rotate(p, 0.3 - time * 0.05);
    BokehLayer(color, p + vec2(-70.0 * time + 33.0 + Rand(vec2(3.0, 4.0)) * 200.0, -33.0), 3.5 * vec3(0.6, 0.4, 0.2));
    Rotate(p, 0.5 + time * 0.07);
    BokehLayer(color, p + vec2(-60.0 * time + 55.0 + Rand(vec2(5.0, 6.0)) * 200.0, 55.0), 3.0 * vec3(0.4, 0.3, 0.2));
    Rotate(p, 0.9 - time * 0.03);
    BokehLayer(color, p + vec2(-25.0 * time + 77.0 + Rand(vec2(7.0, 8.0)) * 200.0, 77.0), 3.0 * vec3(0.4, 0.2, 0.1));
    Rotate(p, 0.0 + time * 0.05);
    BokehLayer(color, p + vec2(-15.0 * time + 99.0 + Rand(vec2(9.0, 10.0)) * 200.0, 99.0), 3.0 * vec3(0.2, 0.0, 0.4));
    
    COLOR = vec4(color, 1.0);
}
