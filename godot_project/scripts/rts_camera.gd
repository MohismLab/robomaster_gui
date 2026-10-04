class_name RtsCamera
extends Node3D
## RTS camera rig: orbits a focus point on the floor.
##   WASD / arrows / screen edge   pan          wheel        zoom
##   middle drag                   rotate/tilt  Q / E        rotate
##   R                             reset view

var focus := Vector3.ZERO
var yaw := deg_to_rad(-30.0)
var pitch := deg_to_rad(-55.0)
var distance := 9.0
var edge_scroll := true
var keyboard_enabled := true

var _target_focus := Vector3.ZERO
var _target_distance := 9.0
var _target_yaw := yaw
var _target_pitch := pitch
var _rotating := false
var _shake := 0.0
var camera: Camera3D

const MIN_DIST := 0.8
const MAX_DIST := 45.0
const EDGE := 6


func _ready() -> void:
	camera = Camera3D.new()
	camera.fov = 50.0
	camera.near = 0.03
	camera.far = 400.0
	add_child(camera)
	camera.make_current()
	_target_focus = focus
	_apply()


func reset_view(center := Vector3.ZERO, extent := 6.0) -> void:
	_target_focus = center
	_target_distance = clampf(extent * 1.6, 3.0, MAX_DIST)
	_target_yaw = deg_to_rad(-30.0)
	_target_pitch = deg_to_rad(-55.0)


func focus_on(p: Vector3, dist := -1.0) -> void:
	_target_focus = Vector3(p.x, 0, p.z)
	if dist > 0.0:
		_target_distance = dist


func shake(amount := 0.05) -> void:
	_shake = maxf(_shake, amount)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_target_distance = clampf(_target_distance * 0.88, MIN_DIST, MAX_DIST)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_target_distance = clampf(_target_distance / 0.88, MIN_DIST, MAX_DIST)
		elif mb.button_index == MOUSE_BUTTON_MIDDLE:
			_rotating = mb.pressed
	elif event is InputEventMouseMotion and _rotating:
		var mm := event as InputEventMouseMotion
		_target_yaw -= mm.relative.x * 0.006
		_target_pitch = clampf(_target_pitch - mm.relative.y * 0.004, deg_to_rad(-88.0), deg_to_rad(-12.0))


func _process(delta: float) -> void:
	var move := Vector2.ZERO
	if keyboard_enabled:
		if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
			move.y -= 1
		if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
			move.y += 1
		if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
			move.x -= 1
		if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
			move.x += 1
		if Input.is_key_pressed(KEY_Q):
			_target_yaw += delta * 1.5
		if Input.is_key_pressed(KEY_E):
			_target_yaw -= delta * 1.5
	if edge_scroll and DisplayServer.window_is_focused() and not _rotating:
		var vp := get_viewport()
		var m := vp.get_mouse_position()
		var size := vp.get_visible_rect().size
		if m.x >= 0 and m.y >= 0 and m.x <= size.x and m.y <= size.y:
			if m.x < EDGE:
				move.x -= 1
			elif m.x > size.x - EDGE:
				move.x += 1
			if m.y < EDGE:
				move.y -= 1
			elif m.y > size.y - EDGE:
				move.y += 1
	if move != Vector2.ZERO:
		var fast := 2.5 if Input.is_key_pressed(KEY_SHIFT) else 1.0
		var speed := _target_distance * 0.9 * fast
		var fwd := Vector3(-sin(_target_yaw), 0, -cos(_target_yaw))
		var right := Vector3(cos(_target_yaw), 0, -sin(_target_yaw))
		_target_focus += (right * move.x + fwd * move.y).normalized() * speed * delta

	var k := 1.0 - exp(-10.0 * delta)
	focus = focus.lerp(_target_focus, k)
	distance = lerpf(distance, _target_distance, k)
	yaw = lerp_angle(yaw, _target_yaw, k)
	pitch = lerpf(pitch, _target_pitch, k)
	_shake = maxf(_shake - delta * 0.3, 0.0)
	_apply()


func _apply() -> void:
	var b := Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, pitch)
	position = focus
	basis = Basis.IDENTITY
	camera.transform = Transform3D(b, b * Vector3(0, 0, distance))
	if _shake > 0.0:
		camera.position += Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)) * _shake * distance * 0.05


## floor point under a screen position (y = 0 plane), or null
func ground_point(screen: Vector2) -> Variant:
	var o := camera.project_ray_origin(screen)
	var d := camera.project_ray_normal(screen)
	if absf(d.y) < 1e-5:
		return null
	var t := -o.y / d.y
	if t < 0.0:
		return null
	return o + d * t


## floor footprint of the view (4 corners), for the minimap
func footprint() -> PackedVector3Array:
	var size := get_viewport().get_visible_rect().size
	var out := PackedVector3Array()
	for s in [Vector2(0, 0), Vector2(size.x, 0), Vector2(size.x, size.y), Vector2(0, size.y)]:
		var p = ground_point(s)
		if p == null:
			var o := camera.project_ray_origin(s)
			var d := camera.project_ray_normal(s)
			d.y = minf(d.y, -0.05)
			p = o + d * (-o.y / d.y)
		out.append(p)
	return out
