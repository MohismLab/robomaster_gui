// RTS selection ring on a flat quad: rotating dashes, inner ring, tick marks.
// selected = 0 -> faint team circle, 1 -> full animated ring.
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;

uniform vec4 color : source_color = vec4(0.0, 0.94, 1.0, 1.0);
uniform float intensity = 1.8;
uniform float selected = 0.0;
uniform float hover = 0.0;
uniform float segments = 18.0;

void fragment() {
	vec2 uv = UV * 2.0 - 1.0;
	float r = length(uv);
	float a = atan(uv.y, uv.x) / 6.28318 + 0.5;

	float outer = smoothstep(0.84, 0.87, r) * smoothstep(0.95, 0.91, r);
	float dash = step(0.35, fract(a * segments + TIME * 0.6));
	float inner = smoothstep(0.70, 0.72, r) * smoothstep(0.75, 0.73, r);
	float ticks = step(0.92, fract(a * 4.0 + 0.04)) * smoothstep(0.95, 0.97, r) * smoothstep(1.0, 0.98, r);
	float halo = exp(-abs(r - 0.88) * 14.0) * 0.35;
	float disc = smoothstep(0.85, 0.0, r) * 0.08;

	float idle = inner * 0.45 + disc * 0.6;
	float sel = outer * dash + inner * 0.8 + ticks * 1.5 + halo + disc;
	float v = mix(idle, sel, selected) + hover * (outer * 0.6 + halo * 0.5);
	ALBEDO = color.rgb * intensity * v;
}
