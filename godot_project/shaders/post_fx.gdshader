// Full-screen cyberpunk post-processing on top of everything: chromatic
// aberration, scanlines, vignette, film grain and glitch bands (glitch > 0).
shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float aberration = 0.0018;
uniform float scanlines = 0.07;
uniform float vignette = 0.45;
uniform float grain = 0.035;
uniform float glitch = 0.0;
uniform vec4 tint : source_color = vec4(0.05, 0.0, 0.08, 1.0);

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

void fragment() {
	vec2 uv = SCREEN_UV;
	float t = floor(TIME * 18.0);
	float band = floor(uv.y * 28.0);
	float bh = hash(vec2(band, t));
	float shift = (step(1.0 - glitch * 0.35, bh)) * (hash(vec2(t, band)) - 0.5) * 0.06 * glitch;
	uv.x += shift;

	vec2 dir = uv - 0.5;
	float d = length(dir);
	float ab = aberration * (0.4 + d * 2.5) + glitch * 0.008;
	vec3 col;
	col.r = texture(screen_tex, uv + dir * ab).r;
	col.g = texture(screen_tex, uv).g;
	col.b = texture(screen_tex, uv - dir * ab).b;

	col *= 1.0 - scanlines * (0.5 + 0.5 * sin(FRAGCOORD.y * 3.14159));
	col *= 1.0 - vignette * smoothstep(0.35, 0.85, d);
	col += tint.rgb * smoothstep(0.3, 0.9, d) * 0.6;
	col += (hash(uv * 512.0 + fract(TIME)) - 0.5) * grain;
	COLOR = vec4(col, 1.0);
}
