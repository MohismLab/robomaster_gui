// Expanding ring on a flat quad. Loops every `period` s, or plays once when
// progress >= 0 (driven from GDScript).
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;

uniform vec4 color : source_color = vec4(0.0, 0.94, 1.0, 1.0);
uniform float intensity = 2.5;
uniform float period = 2.5;
uniform float offset = 0.0;
uniform float progress = -1.0;
uniform float width = 0.05;
uniform float hex = 0.0;

void fragment() {
	vec2 uv = UV * 2.0 - 1.0;
	float t = progress >= 0.0 ? progress : fract(TIME / period + offset);
	float r = length(uv);
	if (hex > 0.5) {
		// hexagon distance
		vec2 q = abs(uv);
		r = max(q.x * 0.866 + q.y * 0.5, q.y) * 1.08;
	}
	float ring = smoothstep(t - width, t, r) * smoothstep(t + width * 0.3, t, r);
	float trail = smoothstep(t - width * 4.0, t, r) * step(r, t) * 0.08;
	float fade = (1.0 - t) * (1.0 - t);
	ALBEDO = color.rgb * intensity * (ring + trail) * fade;
}
