class_name RmUtil
## Shared palette, fonts and ROS <-> Godot coordinate conversion.
##
## ROS / Webots: x forward, y left, z up.  Godot: x right, y up, -z forward.
## Mapping (x, y, z)_ros -> (x, z, -y)_godot is a proper rotation, so a ROS yaw
## is directly Godot's rotation.y.

const CYAN := Color("00f0ff")
const MAGENTA := Color("ff2a6d")
const YELLOW := Color("fcee0a")
const LIME := Color("05ffa1")
const PURPLE := Color("b967ff")
const ORANGE := Color("ff9e2c")
const BG := Color(0.012, 0.016, 0.04)
const PANEL_BG := Color(0.02, 0.03, 0.07, 0.82)
const TEXT := Color(0.82, 0.95, 1.0)
const TEXT_DIM := Color(0.45, 0.6, 0.72)

const TEAM_COLORS := [Color("00f0ff"), Color("ff2a6d"), Color("05ffa1"), Color("b967ff"), Color("fcee0a")]

static var _fonts := {}


static func ros_to_godot(p: Vector3) -> Vector3:
	return Vector3(p.x, p.z, -p.y)


static func godot_to_ros(p: Vector3) -> Vector3:
	return Vector3(p.x, -p.z, p.y)


static func team_color(i: int) -> Color:
	return TEAM_COLORS[i % TEAM_COLORS.size()]


## stable color per robot name "<prefix>_<id>": rm uses the neon palette for id < 5,
## every other case golden-angle hues from the kind's base hue (RobotRegistry.HUES);
## unknown names: hue from a hash
static func robot_color(name: String) -> Color:
	var prefix := RobotRegistry.prefix_of(name)
	var id := name.substr(prefix.length() + 1).to_int() if prefix != name else -1
	var base: float = RobotRegistry.HUES.get(prefix, -2.0)
	if base == -1.0 and id >= 0 and id < TEAM_COLORS.size():
		return TEAM_COLORS[id]
	if base < 0.0:
		base = 0.13 if base == -1.0 else float(absi(prefix.hash()) % 1000) / 1000.0
	var h := fmod(base + maxi(id, 0) * 0.618034, 1.0)
	return Color.from_hsv(h, 0.8, 1.0)


static func font(bold := false) -> Font:
	var key := "b" if bold else "r"
	if not _fonts.has(key):
		var f := SystemFont.new()
		f.font_names = PackedStringArray(["JetBrains Mono", "Fira Code", "Source Code Pro", "Ubuntu Mono",
				"DejaVu Sans Mono", "Noto Sans Mono CJK SC", "WenQuanYi Micro Hei Mono", "monospace"])
		f.font_weight = 700 if bold else 500
		f.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
		f.multichannel_signed_distance_field = true
		_fonts[key] = f
	return _fonts[key]


## Label / theme setters that only touch the control when the value changes
## (a theme override or text change every frame forces re-layout).
static func set_text(l: Label, text: String) -> void:
	if l.text != text:
		l.text = text


static func set_font_color(c: Control, color: Color) -> void:
	if not c.has_theme_color_override("font_color") or c.get_theme_color("font_color") != color:
		c.add_theme_color_override("font_color", color)


static func make_label(text: String, size := 14, color := TEXT, bold := false) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", font(bold))
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


static func shader_material(path: String, params := {}) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load(path)
	for k in params:
		m.set_shader_parameter(k, params[k])
	return m


## a glowing unshaded material for particles / small props
static func glow_material(color: Color, energy := 3.0, billboard := false) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.vertex_color_use_as_albedo = true
	m.albedo_color = Color(color.r * energy, color.g * energy, color.b * energy, color.a)
	m.disable_receive_shadows = true
	m.no_depth_test = false
	if billboard:
		m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	return m


static func gradient(colors: Array, offsets: Array) -> GradientTexture1D:
	var g := Gradient.new()
	g.colors = PackedColorArray(colors)
	g.offsets = PackedFloat32Array(offsets)
	var t := GradientTexture1D.new()
	t.gradient = g
	return t


static func curve(points: Array) -> CurveTexture:
	var c := Curve.new()
	for p in points:
		c.add_point(p)
	var t := CurveTexture.new()
	t.curve = c
	return t


static func fmt_vec(p: Vector3) -> String:
	return "%+6.2f %+6.2f" % [p.x, p.y]
