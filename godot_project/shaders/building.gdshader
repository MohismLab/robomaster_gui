// Background megastructure: dark tower with random lit windows, neon roof edge
// and a vertical light strip. Pure decoration around the arena.
shader_type spatial;

uniform vec4 base : source_color = vec4(0.02, 0.022, 0.04, 1.0);
uniform vec4 win_a : source_color = vec4(0.0, 0.94, 1.0, 1.0);
uniform vec4 win_b : source_color = vec4(1.0, 0.16, 0.43, 1.0);
uniform vec4 edge_color : source_color = vec4(1.0, 0.16, 0.43, 1.0);
uniform float seed = 0.0;
uniform float top_y = 10.0;

varying vec3 wpos;
varying vec3 wnorm;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(41.3, 289.1)) + seed * 13.7) * 43758.5453);
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnorm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	// horizontal coordinate along the face
	float u = abs(wnorm.x) > 0.5 ? wpos.z : wpos.x;
	vec2 cell = vec2(floor(u / 0.9), floor(wpos.y / 1.2));
	vec2 f = vec2(fract(u / 0.9), fract(wpos.y / 1.2));
	float window = step(0.2, f.x) * step(f.x, 0.8) * step(0.25, f.y) * step(f.y, 0.75);
	float h = hash(cell);
	float lit = step(0.72, h) * (0.7 + 0.3 * sin(TIME * (0.5 + h * 3.0) + h * 40.0));
	vec3 wc = mix(win_a.rgb, win_b.rgb, step(0.86, h));
	float side = 1.0 - step(0.9, abs(wnorm.y));
	float roof = smoothstep(0.25, 0.0, abs(wpos.y - top_y)) * 3.0;
	float strip = smoothstep(0.08, 0.0, abs(fract(u / 7.0 + seed) - 0.5)) * 1.5 * (0.6 + 0.4 * sin(wpos.y * 0.8 - TIME * 3.0 + seed));

	ALBEDO = base.rgb;
	ROUGHNESS = 0.35;
	METALLIC = 0.6;
	EMISSION = (wc * window * lit * 2.2 + edge_color.rgb * (roof + strip)) * side;
}
