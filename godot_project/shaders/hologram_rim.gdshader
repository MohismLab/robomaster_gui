// Additive fresnel rim + scan bands, drawn as next_pass over the robot body.
shader_type spatial;
render_mode blend_add, unshaded, depth_draw_never, cull_back, shadows_disabled;

uniform vec4 rim_color : source_color = vec4(0.0, 0.94, 1.0, 1.0);
uniform float rim_power = 2.2;
uniform float strength = 1.0;
uniform float selected = 0.0;
uniform float flash = 0.0;

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float fres = pow(1.0 - clamp(abs(dot(NORMAL, VIEW)), 0.0, 1.0), rim_power);
	float lines = smoothstep(0.6, 1.0, sin(wpos.y * 300.0 - TIME * 10.0)) * 0.25;
	float band = smoothstep(0.012, 0.0, abs(fract(wpos.y * 6.0 - TIME * 0.8) - 0.5) - 0.48);
	float k = fres * strength * (1.0 + selected) + (lines + band * 1.5) * (0.25 + selected) + flash * 1.2;
	ALBEDO = rim_color.rgb * k;
}
