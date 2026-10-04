class_name TacticalMap
extends Control
## Top-down radar of the arena (ROS x right, y up, like RViz's top view).
## Left click: move the camera there.  Right click: order the selection there.

signal focus_requested(world: Vector3)
signal order_requested(world: Vector3)

var units: Array = []
var anchors: Array = []
var view_poly := PackedVector3Array()

var _center := Vector2.ZERO   # ROS xy at the middle of the map
var _scale := 20.0            # px per meter
var _sweep := 0.0
var _blips := {}              # unit name -> fade time of the last sweep hit


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true


var _redraw_t := 0.0


func _process(delta: float) -> void:
	_sweep = fmod(_sweep + delta * 1.6, TAU)
	_redraw_t -= delta
	if _redraw_t <= 0.0 and is_visible_in_tree():
		_redraw_t = 1.0 / 30.0
		_fit()
		queue_redraw()


## fit anchors + robots with some margin
func _fit() -> void:
	var pts: Array[Vector2] = []
	for a in anchors:
		pts.append(Vector2(a.ros_position.x, a.ros_position.y))
	for u in units:
		if u.is_online():
			pts.append(Vector2(u.ros_position.x, u.ros_position.y))
	if pts.is_empty():
		pts = [Vector2(-3, -3), Vector2(3, 3)]
	var r := Rect2(pts[0], Vector2.ZERO)
	for p in pts:
		r = r.expand(p)
	r = r.grow(1.0)
	var target_scale := minf(size.x / maxf(r.size.x, 2.0), size.y / maxf(r.size.y, 2.0)) * 0.9
	_center = _center.lerp(r.get_center(), 0.08)
	_scale = lerpf(_scale, target_scale, 0.08)


func world_to_map(ros_xy: Vector2) -> Vector2:
	return size / 2.0 + Vector2(ros_xy.x - _center.x, -(ros_xy.y - _center.y)) * _scale


func map_to_world(p: Vector2) -> Vector3:
	var d := (p - size / 2.0) / _scale
	var ros := Vector3(_center.x + d.x, _center.y - d.y, 0.0)
	return RmUtil.ros_to_godot(ros)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			focus_requested.emit(map_to_world(mb.position))
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			order_requested.emit(map_to_world(mb.position))
			accept_event()


func _godot_to_map(p: Vector3) -> Vector2:
	var r := RmUtil.godot_to_ros(p)
	return world_to_map(Vector2(r.x, r.y))


func _draw() -> void:
	var font := RmUtil.font()
	var c := size / 2.0
	var R := size.length() / 2.0

	# 1 m grid
	var step := 1.0 if _scale > 12.0 else 5.0
	var origin := world_to_map(Vector2.ZERO)
	var gx := fmod(origin.x, step * _scale)
	while gx < size.x:
		draw_line(Vector2(gx, 0), Vector2(gx, size.y), Color(RmUtil.CYAN, 0.07), 1.0)
		gx += step * _scale
	var gy := fmod(origin.y, step * _scale)
	while gy < size.y:
		draw_line(Vector2(0, gy), Vector2(size.x, gy), Color(RmUtil.CYAN, 0.07), 1.0)
		gy += step * _scale
	draw_line(origin, origin + Vector2(_scale, 0), Color(1, 0.2, 0.3, 0.8), 2.0)
	draw_line(origin, origin - Vector2(0, _scale), Color(0.2, 1, 0.4, 0.8), 2.0)

	# range rings and sweep
	for k in range(1, 4):
		draw_arc(c, R * k / 3.5, 0, TAU, 64, Color(RmUtil.CYAN, 0.08), 1.0)
	for k in 24:
		var a := _sweep - k * 0.03
		draw_line(c, c + Vector2(cos(a), sin(a)) * R, Color(RmUtil.CYAN, 0.18 * (1.0 - k / 24.0)), 2.0)

	# arena = polygon through the anchors
	if anchors.size() >= 3:
		var pts := PackedVector2Array()
		var sorted := anchors.duplicate()
		var mid := Vector2.ZERO
		for a in sorted:
			mid += Vector2(a.ros_position.x, a.ros_position.y)
		mid /= sorted.size()
		sorted.sort_custom(func(a, b):
			return atan2(a.ros_position.y - mid.y, a.ros_position.x - mid.x) < atan2(b.ros_position.y - mid.y, b.ros_position.x - mid.x))
		for a in sorted:
			pts.append(world_to_map(Vector2(a.ros_position.x, a.ros_position.y)))
		draw_colored_polygon(pts, Color(RmUtil.YELLOW, 0.04))
		pts.append(pts[0])
		draw_polyline(pts, Color(RmUtil.YELLOW, 0.5), 1.5)

	# camera view
	if view_poly.size() == 4:
		var vp := PackedVector2Array()
		for p in view_poly:
			vp.append(_godot_to_map(p))
		vp.append(vp[0])
		draw_polyline(vp, Color(1, 1, 1, 0.35), 1.0)

	for a in anchors:
		var p := world_to_map(Vector2(a.ros_position.x, a.ros_position.y))
		var d := 6.0
		draw_colored_polygon(PackedVector2Array([p + Vector2(0, -d), p + Vector2(d, 0), p + Vector2(0, d), p + Vector2(-d, 0)]),
				Color(RmUtil.YELLOW, 0.9))
		draw_string(font, p + Vector2(8, 4), "A%d" % a.anchor_id, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, RmUtil.YELLOW)

	var t := Time.get_ticks_msec() / 1000.0
	for u in units:
		if not u.is_online():
			continue
		var p := world_to_map(Vector2(u.ros_position.x, u.ros_position.y))
		if u.has_goal:
			var g := _godot_to_map(u.goal)
			draw_dashed_line(p, g, Color(u.color, 0.7), 1.5, 5.0)
			draw_line(g + Vector2(-5, -5), g + Vector2(5, 5), u.color, 2.0)
			draw_line(g + Vector2(-5, 5), g + Vector2(5, -5), u.color, 2.0)
		# blip brightens when the sweep passes over it
		var ang := fposmod((p - c).angle(), TAU)
		if absf(angle_difference(ang, _sweep)) < 0.08:
			_blips[u.robot_name] = t
		var glow := clampf(1.0 - (t - _blips.get(u.robot_name, -10.0)) / 1.5, 0.0, 1.0)
		draw_circle(p, 10.0 + glow * 6.0, Color(u.color, 0.12 + glow * 0.25))
		var col: Color = u.color if u.signal_ok() else RmUtil.ORANGE
		var dir := Vector2(cos(u.yaw), -sin(u.yaw))
		var nrm := Vector2(-dir.y, dir.x)
		draw_colored_polygon(PackedVector2Array([p + dir * 8, p - dir * 5 + nrm * 5, p - dir * 2, p - dir * 5 - nrm * 5]), col)
		if u.selected:
			draw_arc(p, 11.0, t * 2.0, t * 2.0 + TAU * 0.75, 24, Color.WHITE, 1.5)
		draw_string(font, p + Vector2(10, -8), u.robot_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, u.color)

	draw_string(font, Vector2(6, size.y - 6), "%.0f px/m" % _scale, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, RmUtil.TEXT_DIM)
