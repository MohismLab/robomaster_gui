class_name MoveGizmo
extends Node3D
## Homeworld-style move order: hold the right mouse button, the target follows the
## mouse on the floor; with Shift held, dragging up / down sets the altitude (for
## flying robots) - a pillar from the floor ring up to the 3D target marker. Lines
## run from every selected unit to the target. Release to order.

const MAX_ALT := 5.0

var active := false
var ground := Vector3.ZERO      # target on the floor (Godot)
var altitude := 0.0             # [m] above the floor
var use_altitude := false

var _ring: MeshInstance3D
var _ring_mat: ShaderMaterial
var _pillar: MeshInstance3D
var _marker: MeshInstance3D
var _label: Label3D
var _lines: MeshInstance3D


func _ready() -> void:
	visible = false
	top_level = true
	_ring = MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(0.9, 0.9)
	_ring.mesh = pm
	_ring_mat = RmUtil.shader_material("res://shaders/selection_ring.gdshader",
			{"color": RmUtil.CYAN, "selected": 1.0, "segments": 12.0, "intensity": 2.5})
	_ring.material_override = _ring_mat
	_ring.position.y = 0.012
	add_child(_ring)

	_pillar = MeshInstance3D.new()
	var c := CylinderMesh.new()
	c.top_radius = 0.012
	c.bottom_radius = 0.012
	c.height = 1.0
	c.cap_top = false
	c.cap_bottom = false
	_pillar.mesh = c
	_pillar.material_override = RmUtil.glow_material(RmUtil.CYAN, 2.5)
	add_child(_pillar)

	_marker = MeshInstance3D.new()
	var s := SphereMesh.new()
	s.radius = 0.07
	s.height = 0.14
	s.radial_segments = 12
	s.rings = 6
	_marker.mesh = s
	_marker.material_override = RmUtil.glow_material(RmUtil.MAGENTA, 3.0)
	add_child(_marker)

	_label = Label3D.new()
	_label.font = RmUtil.font(true)
	_label.font_size = 32
	_label.outline_size = 8
	_label.outline_modulate = Color(0, 0, 0, 0.85)
	_label.modulate = RmUtil.CYAN
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.fixed_size = true
	_label.pixel_size = 0.001
	add_child(_label)

	_lines = MeshInstance3D.new()
	_lines.mesh = ImmediateMesh.new()
	_lines.material_override = RmUtil.glow_material(Color.WHITE, 1.5)
	_lines.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_lines)


func begin(p: Vector3, alt: float, with_altitude: bool) -> void:
	active = true
	visible = true
	ground = Vector3(p.x, 0, p.z)
	altitude = clampf(alt, 0.0, MAX_ALT)
	use_altitude = with_altitude


func end() -> void:
	active = false
	visible = false


func set_ground(p: Vector3) -> void:
	ground = Vector3(p.x, 0, p.z)


func add_altitude(d: float) -> void:
	altitude = clampf(altitude + d, 0.0, MAX_ALT)


## target in 3D (altitude only when it applies)
func target() -> Vector3:
	return ground + Vector3(0, altitude if use_altitude else 0.0, 0)


func update(units: Array) -> void:
	if not active:
		return
	var t := Time.get_ticks_msec() / 1000.0
	position = Vector3.ZERO
	_ring.position = ground + Vector3(0, 0.012, 0)
	_ring.rotation.y = t * 0.8
	var h := altitude if use_altitude else 0.0
	_pillar.visible = use_altitude and h > 0.02
	_pillar.scale.y = maxf(h, 0.01)
	_pillar.position = ground + Vector3(0, h / 2.0, 0)
	_marker.visible = use_altitude
	_marker.position = ground + Vector3(0, h, 0)
	_marker.scale = Vector3.ONE * (1.0 + 0.15 * sin(t * 6.0))
	_label.position = ground + Vector3(0, h + 0.25, 0)
	var ros := RmUtil.godot_to_ros(ground)
	_label.text = ("%.2f, %.2f  H %.2fm" % [ros.x, ros.y, h]) if use_altitude else ("%.2f, %.2f" % [ros.x, ros.y])

	# dashed lines unit -> target (flying units to the 3D marker)
	var im: ImmediateMesh = _lines.mesh
	im.clear_surfaces()
	var verts := PackedVector3Array()
	for u in units:
		var a: Vector3 = u.global_position + Vector3(0, u.hover_height() + 0.05, 0)
		var b := ground + Vector3(0, h if u.has_method("can_fly") and u.can_fly() else 0.01, 0)
		var n := int(a.distance_to(b) / 0.1)
		for k in range(0, n, 2):
			verts.append(a.lerp(b, float(k) / n))
			verts.append(a.lerp(b, float(k + 1) / n))
	if not verts.is_empty():
		im.surface_begin(Mesh.PRIMITIVE_LINES)
		for v in verts:
			im.surface_set_color(Color(RmUtil.CYAN, 0.7))
			im.surface_add_vertex(v)
		im.surface_end()
