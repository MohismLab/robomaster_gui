// Wet, reflective floor with a neon grid (1 m UWB grid, 5 m major lines),
// a slow radar wave from the origin and axis lines (red x, green y as in RViz).
shader_type spatial;
render_mode cull_disabled;

uniform vec4 base_color : source_color = vec4(0.008, 0.01, 0.022, 1.0);
uniform vec4 minor_color : source_color = vec4(0.0, 0.94, 1.0, 1.0);
uniform vec4 major_color : source_color = vec4(1.0, 0.16, 0.43, 1.0);
uniform float minor_step = 1.0;
uniform float major_step = 5.0;
uniform float glow = 1.1;
uniform float fade_dist = 45.0;
uniform vec2 wave_origin = vec2(0.0);

varying vec3 wpos;

float grid_line(vec2 p, float step_size, float width) {
	vec2 q = p / step_size;
	vec2 g = abs(fract(q - 0.5) - 0.5) / max(fwidth(q), vec2(1e-4));
	return 1.0 - min(min(g.x, g.y) / width, 1.0);
}

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = wpos.xz;
	float minor = grid_line(p, minor_step, 1.0);
	float sub = grid_line(p, minor_step * 0.25, 0.8) * 0.08;
	float major = grid_line(p, major_step, 1.6);

	float d = length(p - wave_origin);
	float wave = pow(0.5 + 0.5 * sin(d * 0.9 - TIME * 2.2), 24.0);
	float sweep_ring = smoothstep(0.35, 0.0, abs(d - mod(TIME * 6.0, 60.0))) * 0.8;

	// random flickering cells, like a data floor
	vec2 cell = floor(p / minor_step);
	float flick = step(0.985, hash(cell + floor(TIME * 0.7))) * 0.035;

	vec2 aw = max(fwidth(p), vec2(1e-4));
	float axis_x = (1.0 - min(abs(p.y) / (aw.y * 1.5), 1.0)) * step(0.0, p.x);   // ROS +x = Godot +x
	float axis_y = (1.0 - min(abs(p.x) / (aw.x * 1.5), 1.0)) * step(p.y, 0.0);   // ROS +y = Godot -z

	float fade = 1.0 - smoothstep(fade_dist * 0.25, fade_dist, length(p - CAMERA_POSITION_WORLD.xz));

	vec3 e = minor_color.rgb * (minor * (0.3 + 0.8 * wave + sweep_ring) + sub + flick);
	e += major_color.rgb * major * (0.6 + 0.4 * wave);
	e += vec3(1.0, 0.15, 0.2) * axis_x * 1.5 + vec3(0.2, 1.0, 0.4) * axis_y * 1.5;

	ALBEDO = base_color.rgb;
	METALLIC = 0.7;
	ROUGHNESS = 0.22 + 0.1 * hash(floor(p * 2.0));
	SPECULAR = 0.8;
	EMISSION = e * glow * fade;
}
