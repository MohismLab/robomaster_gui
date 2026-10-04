@abstract
class_name RobotUnit
extends Node3D
## Abstract base of every robot kind in the scene: pose following, signal / offline
## handling and the RTS decorations (selection ring, hologram rim, underglow, spark
## trail, labels, path ribbon, navigation goal).
##
## A robot kind subclasses it and implements _build_body() (the model under _body,
## x forward, y up, floor at y = 0); optional overrides: _animate(), kind_can_drive(), can_fly(),
## kind_tag(), hover_height(), ring_size(), label_height(). Kinds are mapped to robot
## names in RobotRegistry.

const PATH_POINTS := 160
const SIGNAL_TIMEOUT := 1.5
const OFFLINE_AFTER := 5.0        # [s] without a valid pose -> robot is offline (hidden)
const JUMP := 0.5                 # [m] a pose step larger than this is a relocation, not motion

var robot_name := ""
var index := 0
var color := RmUtil.CYAN
var selected := false
var hovered := false
var has_pose := false
var status := ""
var age := 1e9
var has_goal := false
var goal := Vector3.ZERO          # Godot coordinates, on the floor
var ros_position := Vector3.ZERO  # last ROS position, for the HUD
var yaw := 0.0
var speed := 0.0
var manual := false
var height := 0.0                 # raw UWB height above the floor (flying robots)
var drive_allowed := true
var calibrating := false          # magnetometer calibration spinning the robot: no orders

## name / status text above the robots (HUD toggle "LABELS", key L), off by default
static var show_labels := false

var _target := Vector3.ZERO
var _vel := Vector3.ZERO
var _flash := 0.0
var _path: Array[Vector3] = []
var _was_ok := false
var _nav_goal := false            # the navigator reports a goal
var _order_hold := 0.0            # keep a local order visible until the navigator answers

var _body: Node3D                 # model root, lifted by hover_height()
var _rim_mat: ShaderMaterial
var _ring_mat: ShaderMaterial
var _light: OmniLight3D
var _trail: GPUParticles3D
var _orbit: GPUParticles3D
var _burst: GPUParticles3D
var _label: Label3D
var _sub_label: Label3D
var _fx: Node3D                   # world-space children (path, goal)
var _lines: MeshInstance3D
var _goal_root: Node3D
var _goal_ring_mat: ShaderMaterial
var _goal_burst: GPUParticles3D


func setup(name_: String, index_: int) -> void:
	robot_name = name_
	index = index_
	color = RmUtil.robot_color(name_)
	name = "Robot_" + name_
	_rim_mat = RmUtil.shader_material("res://shaders/hologram_rim.gdshader", {"rim_color": color})
	_body = Node3D.new()
	add_child(_body)
	_build_body()
	_build_decorations()
	_build_world_fx()
	visible = false


# ---------------------------------------------------------------- robot kind API

## build the model under _body: x forward, y up, floor at y = 0
@abstract func _build_body() -> void


## per-frame animation (wheels, legs, rotors); speed / yaw / height are up to date
func _animate(_delta: float) -> void:
	pass


## driven with /<robot>/cmd_vel (navigation, manual drive)? the kind must support it
## and it must be enabled (--drive-kinds, off until a robot's control interface is known)
func can_drive() -> bool:
	return drive_allowed and kind_can_drive()


## the kind moves on the floor and takes a body twist on cmd_vel
func kind_can_drive() -> bool:
	return true


## does it take 3D move orders (x, y, altitude) on /uwb_nav/<robot>/goal_pose?
func can_fly() -> bool:
	return false


func kind_tag() -> String:
	return "BOT"


## height of _body above the floor
func hover_height() -> float:
	return 0.0


func ring_size() -> float:
	return 0.8


func label_height() -> float:
	return 0.42


## dark metal with the hologram rim of the robot's color
func hull_material(albedo := Color(0.09, 0.1, 0.13)) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = albedo
	m.metallic = 0.85
	m.roughness = 0.32
	m.rim_enabled = true
	m.rim = 0.4
	m.next_pass = _rim_mat
	return m


func emissive_material(c: Color, energy := 3.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color.BLACK
	m.emission_enabled = true
	m.emission = c
	m.emission_energy_multiplier = energy
	return m


func _add_cylinder(parent: Node3D, pos: Vector3, radius: float, h: float, mat: Material,
		radius_top := -1.0) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var c := CylinderMesh.new()
	c.top_radius = radius if radius_top < 0.0 else radius_top
	c.bottom_radius = radius
	c.height = h
	mi.mesh = c
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)
	return mi


func _add_box(parent: Node3D, pos: Vector3, size: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	mi.mesh = b
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)
	return mi


func _build_decorations() -> void:
	var ring := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(ring_size(), ring_size())
	ring.mesh = plane
	_ring_mat = RmUtil.shader_material("res://shaders/selection_ring.gdshader", {"color": color})
	ring.material_override = _ring_mat
	ring.position.y = 0.006
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(ring)

	_light = OmniLight3D.new()
	_light.light_color = color
	_light.light_energy = 1.2
	_light.omni_range = 0.9
	_light.position.y = 0.03
	add_child(_light)

	_trail = Fx.trail(color)
	_trail.position.y = 0.03
	add_child(_trail)
	_orbit = Fx.orbit_sparks(color, 0.36)
	_orbit.position.y = 0.02
	_orbit.emitting = false
	add_child(_orbit)
	_burst = Fx.burst(color, 80, 1.6, 0.04)
	_burst.position.y = 0.15
	add_child(_burst)

	_label = Label3D.new()
	_label.text = robot_name.to_upper()
	_label.font = RmUtil.font(true)
	_label.font_size = 40
	_label.outline_size = 10
	_label.outline_modulate = Color(0, 0, 0, 0.85)
	_label.modulate = color.lightened(0.2)
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.fixed_size = true
	_label.pixel_size = 0.001
	_label.position.y = label_height()
	add_child(_label)
	_sub_label = Label3D.new()
	_sub_label.font = RmUtil.font()
	_sub_label.font_size = 26
	_sub_label.outline_size = 8
	_sub_label.outline_modulate = Color(0, 0, 0, 0.85)
	_sub_label.modulate = RmUtil.TEXT
	_sub_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_sub_label.no_depth_test = true
	_sub_label.fixed_size = true
	_sub_label.pixel_size = 0.001
	_sub_label.position.y = label_height()
	_sub_label.offset = Vector2(0, -34)
	add_child(_sub_label)


func _build_world_fx() -> void:
	_fx = Node3D.new()
	_fx.top_level = true
	add_child(_fx)
	_lines = MeshInstance3D.new()
	_lines.mesh = ImmediateMesh.new()
	var lm := StandardMaterial3D.new()
	lm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	lm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	lm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	lm.cull_mode = BaseMaterial3D.CULL_DISABLED
	lm.vertex_color_use_as_albedo = true
	lm.albedo_color = Color(2.5, 2.5, 2.5, 1)
	_lines.material_override = lm
	_lines.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_fx.add_child(_lines)

	# goal: beam, looping hex pulses and a spark vortex
	_goal_root = Node3D.new()
	_goal_root.visible = false
	_fx.add_child(_goal_root)
	var beam := MeshInstance3D.new()
	var bc := CylinderMesh.new()
	bc.top_radius = 0.06
	bc.bottom_radius = 0.12
	bc.height = 2.5
	bc.cap_top = false
	bc.cap_bottom = false
	beam.mesh = bc
	beam.material_override = RmUtil.shader_material("res://shaders/beam.gdshader",
			{"color": color, "height": 2.5, "intensity": 1.2})
	beam.position.y = 1.25
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_goal_root.add_child(beam)
	for k in 2:
		var pr := MeshInstance3D.new()
		var pm := PlaneMesh.new()
		pm.size = Vector2(1.0, 1.0)
		pr.mesh = pm
		pr.material_override = RmUtil.shader_material("res://shaders/pulse_ring.gdshader",
				{"color": color, "period": 1.6, "offset": k * 0.5, "hex": 1.0, "intensity": 3.0})
		pr.position.y = 0.008
		pr.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_goal_root.add_child(pr)
	var mark := MeshInstance3D.new()
	var mp := PlaneMesh.new()
	mp.size = Vector2(0.5, 0.5)
	mark.mesh = mp
	_goal_ring_mat = RmUtil.shader_material("res://shaders/selection_ring.gdshader",
			{"color": color, "selected": 1.0, "segments": 8.0})
	mark.material_override = _goal_ring_mat
	mark.position.y = 0.01
	_goal_root.add_child(mark)
	_goal_root.add_child(Fx.vortex(color, 0.35))
	_goal_burst = Fx.burst(color, 120, 2.5, 0.05)
	_fx.add_child(_goal_burst)


## per-frame update from the ROS state dictionary (RosBridge.get_robot_states()[name])
func apply_state(s: Dictionary) -> void:
	age = s.get("age", 1e9)
	calibrating = s.get("calibrating", false)
	height = s.get("height", 0.0)
	status = s.get("status", "")
	var hp: bool = s.get("has_pose", false)
	if hp:
		ros_position = s["position"]
		var t := RmUtil.ros_to_godot(Vector3(ros_position.x, ros_position.y, 0.0))
		var jumped := has_pose and t.distance_to(_target) > JUMP
		_target = t
		yaw = s.get("yaw", 0.0)
		var ok := age < SIGNAL_TIMEOUT
		if not has_pose or jumped or (ok and not _was_ok):
			# first pose, relocation (tag rebooted, EKF reset) or signal back: no slide,
			# no trail line across the arena
			position = _target
			_vel = Vector3.ZERO
			_path.clear()
			_flash = 1.0
			_burst.restart()
		_was_ok = ok
	has_pose = hp
	visible = is_online()
	var hg: bool = s.get("has_goal", false)
	if hg:
		var g: Vector3 = s["goal"]
		goal = RmUtil.ros_to_godot(Vector3(g.x, g.y, 0.0))
		_order_hold = 0.0
	elif _nav_goal:
		# goal dropped by the navigator: reached (or cancelled)
		_goal_burst.global_position = goal + Vector3(0, 0.1, 0)
		_goal_burst.restart()
	_nav_goal = hg
	has_goal = hg or _order_hold > 0.0


func set_selected(v: bool) -> void:
	if v and not selected:
		_burst.restart()
		_flash = 1.0
	selected = v


## local order feedback before the navigator answers
func show_order(target: Vector3) -> void:
	goal = target
	has_goal = true
	_order_hold = 2.0
	_goal_root.visible = true
	_goal_burst.global_position = target + Vector3(0, 0.05, 0)
	_goal_burst.restart()
	_flash = 0.8


func clear_order() -> void:
	_order_hold = 0.0
	has_goal = _nav_goal


## powered off / out of range for a while: hidden from the scene, list and map
func is_online() -> bool:
	return has_pose and age < OFFLINE_AFTER


func signal_ok() -> bool:
	return has_pose and age < SIGNAL_TIMEOUT


func _process(delta: float) -> void:
	if not has_pose:
		_fx.visible = false
		return
	_fx.visible = true
	var prev := position
	position = position.lerp(_target, 1.0 - exp(-10.0 * delta))
	rotation.y = lerp_angle(rotation.y, yaw, 1.0 - exp(-10.0 * delta))
	if delta > 0.0:
		_vel = _vel.lerp((position - prev) / delta, 1.0 - exp(-6.0 * delta))
	if not signal_ok():
		_vel = Vector3.ZERO   # frozen at the last trusted pose
	speed = _vel.length()
	_body.position.y = lerpf(_body.position.y, hover_height(), 1.0 - exp(-8.0 * delta))
	_label.position.y = label_height() + _body.position.y
	_sub_label.position.y = _label.position.y
	_animate(delta)

	var lost := not signal_ok()
	var t := Time.get_ticks_msec() / 1000.0
	_flash = maxf(_flash - delta * 2.5, 0.0)
	_order_hold = maxf(_order_hold - delta, 0.0)
	var c := color
	if lost:
		c = RmUtil.ORANGE if fmod(t, 0.6) < 0.3 else Color(0.3, 0.05, 0.05)
	_rim_mat.set_shader_parameter("rim_color", c)
	_rim_mat.set_shader_parameter("selected", 1.0 if selected else 0.0)
	_rim_mat.set_shader_parameter("flash", _flash)
	_ring_mat.set_shader_parameter("color", c)
	_ring_mat.set_shader_parameter("selected", 1.0 if selected else 0.0)
	_ring_mat.set_shader_parameter("hover", 1.0 if hovered else 0.0)
	_light.light_color = c
	_light.light_energy = (1.2 if selected else 0.6) + 0.2 * sin(t * 4.0 + index) + _flash * 1.5
	_orbit.emitting = selected
	_trail.amount_ratio = clampf(speed / 0.25, 0.0, 1.0)
	_trail.emitting = speed > 0.02

	_label.modulate = c.lightened(0.25) if (selected or hovered) else Color(c, 0.75)
	_label.visible = show_labels
	_sub_label.visible = show_labels
	if lost:
		_sub_label.text = "⚠ SIGNAL LOST %.1fs" % age
		_sub_label.modulate = RmUtil.ORANGE
	elif calibrating:
		_sub_label.text = "⟳ MAG CALIBRATION"
		_sub_label.modulate = RmUtil.YELLOW
	elif manual:
		_sub_label.text = "◈ MANUAL"
		_sub_label.modulate = RmUtil.YELLOW
	elif status != "":
		_sub_label.text = "▶ " + status.to_upper()
		_sub_label.modulate = RmUtil.TEXT
	else:
		_sub_label.text = ""

	# path history (sampled every 2 cm)
	if not _path.is_empty() and _path[-1].distance_to(position) > JUMP:
		_path.clear()
	if signal_ok() and (_path.is_empty() or _path[-1].distance_to(position) > 0.02):
		_path.append(position)
		if _path.size() > PATH_POINTS:
			_path.pop_front()

	_goal_root.visible = has_goal
	if has_goal:
		_goal_root.position = goal
		_goal_root.rotation.y += delta * 0.8
	_draw_lines(t)


func _draw_lines(t: float) -> void:
	var im: ImmediateMesh = _lines.mesh
	im.clear_surfaces()
	var y := 0.012
	if _path.size() >= 2:
		im.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
		var n := _path.size()
		for i in n:
			var p := _path[i]
			var d := (_path[mini(i + 1, n - 1)] - _path[maxi(i - 1, 0)])
			d.y = 0.0
			var side := Vector3(-d.z, 0, d.x).normalized() * 0.018 * (float(i) / n)
			var a := pow(float(i) / n, 1.5) * (0.8 if selected else 0.45)
			im.surface_set_color(Color(color, a))
			im.surface_add_vertex(Vector3(p.x, y, p.z) + side)
			im.surface_set_color(Color(color, a))
			im.surface_add_vertex(Vector3(p.x, y, p.z) - side)
		im.surface_end()
	if has_goal:
		# dashes flowing from the robot to its goal
		var a := Vector3(position.x, y, position.z)
		var b := Vector3(goal.x, y, goal.z)
		var length := a.distance_to(b)
		if length > 0.05:
			var dir := (b - a) / length
			var side := Vector3(-dir.z, 0, dir.x) * 0.012
			var verts := PackedVector3Array()
			var dash := 0.12
			var s := fmod(t * 0.5, dash * 2.0) - dash * 2.0
			while s < length:
				var s0 := maxf(s, 0.0)
				var s1 := minf(s + dash, length)
				if s1 > s0:
					var p0 := a + dir * s0
					var p1 := a + dir * s1
					verts.append_array([p0 + side, p0 - side, p1 + side, p1 + side, p0 - side, p1 - side])
				s += dash * 2.0
			if not verts.is_empty():
				var col := Color(color, 0.9 if selected else 0.5)
				im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
				for v in verts:
					im.surface_set_color(col)
					im.surface_add_vertex(v)
				im.surface_end()
