// Vertical light beam on an open cylinder (anchors, goals): fades upward,
// glowing edges, energy stripes flowing up.
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;

uniform vec4 color : source_color = vec4(0.0, 0.94, 1.0, 1.0);
uniform float intensity = 1.5;
uniform float height = 3.0;
uniform float speed = 1.5;
uniform float stripes = 14.0;

varying float h;

void vertex() {
	h = clamp(VERTEX.y / height + 0.5, 0.0, 1.0);
}

void fragment() {
	float edge = pow(1.0 - clamp(abs(dot(NORMAL, VIEW)), 0.0, 1.0), 1.5);
	float flow = 0.55 + 0.45 * sin(h * stripes * 6.28318 - TIME * speed * 6.0);
	float fade = pow(1.0 - h, 1.8) * smoothstep(0.0, 0.03, h);
	ALBEDO = color.rgb * intensity * (0.25 + edge) * flow * fade;
}
