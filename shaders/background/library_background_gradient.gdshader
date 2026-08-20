shader_type canvas_item;

uniform sampler2D gradient_texture : source_color;
uniform float gradient_angle = 180.0; // degrees, 0 = up, clockwise
uniform bool gradient_radial = false; // vignette: center -> edge

// Linear: projection normalized corner-to-corner (matches old H/V/diagonal at
// 90/180/135 degrees). Radial: t=0 at center, t=1 at corners.
float gradient_coord(vec2 uv, float angle_deg, bool radial) {
    if (radial) {
        return clamp(length(uv - 0.5) * 1.41421356, 0.0, 1.0);
    }
    float r = radians(angle_deg);
    vec2 dir = vec2(sin(r), -cos(r));
    return clamp(dot(uv - 0.5, dir) / (abs(dir.x) + abs(dir.y)) + 0.5, 0.0, 1.0);
}

void fragment() {
    float t = gradient_coord(UV, gradient_angle, gradient_radial);
    COLOR = texture(gradient_texture, vec2(t, 0.0));
}
