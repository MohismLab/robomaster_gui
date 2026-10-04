class_name DemoBridge
extends Node
## Offline stand-in for the RosBridge GDExtension class (same methods), used with
## --demo or when the extension / ROS 2 cannot be loaded.
##
## Mimics the real setup: the UWB frame is mirrored against the display frame
## (origin A0, +x towards A1), cmd_vel is a body-frame twist, every car has an
## IMU whose yaw (ENU) is off the UWB heading by an unknown per-car offset, and
## goals sent with send_goal are driven like uwb_goal_nav.py would.

var robots := PackedStringArray()
var _state := {}
var _anchors := [
	{"id": 0, "position": Vector3(0.0, 0.0, 1.75)},
	{"id": 1, "position": Vector3(8.134, 0.0, 1.75)},
	{"id": 2, "position": Vector3(5.633, 6.261, 1.75)},
	{"id": 3, "position": Vector3(6.493, -4.324, 1.75)},
	{"id": 4, "position": Vector3(9.565, 3.882, 1.75)},
]
var _tx := 0
var _rx := 0
var _running := false
var _t := 0.0
var _theta := randf_range(-PI, PI)
var _enu = null           # theta passed to set_enu_rotation, or null

const SPEED := 0.35
const H := -1.0   # UWB frame handedness


func start() -> bool:
	for i in robots.size():
		var psi := randf_range(-PI, PI)
		# UWB angle of magnetic east: one value for all robots, plus a small IMU error each
		var off := _theta + randf_range(-0.08, 0.08)
		_state[robots[i]] = {
			"p": Vector2(3.0 + i * 1.2, -0.5 - (i % 2) * 1.0), "psi": psi, "imu_off": off,
			"goal": null, "cmd": Vector3.ZERO, "cmd_t": -10.0, "v": Vector2.ZERO, "seq": 0,
		}
	_running = true
	return true


func stop() -> void:
	_running = false


func is_running() -> bool:
	return _running


# display <-> UWB (A0 = origin of both): a mirror (y flipped), like the real lab, or
# ENU after set_enu_rotation(): ENU yaw = H * (psi - theta)
func to_display_xy(u: Vector2) -> Vector2:
	if _enu == null:
		return Vector2(u.x, -u.y)
	var c := cos(_enu)
	var s := sin(_enu)
	return Vector2(c * u.x + s * u.y, -H * s * u.x + H * c * u.y)


func to_uwb_xy(d: Vector2) -> Vector2:
	if _enu == null:
		return Vector2(d.x, -d.y)
	var c := cos(_enu)
	var s := sin(_enu)
	# inverse of [c s; -H s, H c], determinant H
	return Vector2(H * c * d.x - s * d.y, H * s * d.x + c * d.y) / H


func set_enu_rotation(theta: float, _h: float) -> void:
	_enu = theta


func clear_enu_rotation() -> void:
	_enu = null


func is_enu() -> bool:
	return _enu != null


func is_frame_ready() -> bool:
	return true


func _process(delta: float) -> void:
	if not _running:
		return
	_t += delta
	for r in _state:
		var s: Dictionary = _state[r]
		var want := Vector2.ZERO
		if r.begins_with("fly_"):
			s["h"] = move_toward(s.get("h", 1.2), s.get("goal_h", 1.2), 0.3 * delta)
		if s["goal"] != null:
			var d: Vector2 = s["goal"] - s["p"]
			if d.length() < 0.05:
				s["goal"] = null
			else:
				want = d.normalized() * minf(SPEED, d.length() * 1.5)
		elif _t - s["cmd_t"] < 0.5:
			# body twist -> UWB frame: body +y points to psi + H * 90 deg
			var c: Vector3 = s["cmd"]
			var psi: float = s["psi"]
			want = Vector2.from_angle(psi) * c.x + Vector2.from_angle(psi + H * PI / 2.0) * c.y
			s["psi"] = wrapf(psi + H * c.z * delta, -PI, PI)
		s["v"] = (s["v"] as Vector2).move_toward(want, 1.0 * delta)
		s["p"] += s["v"] * delta
		s["seq"] += 1
		_rx += 1


func get_robot_states() -> Dictionary:
	var out := {}
	for r in _state:
		var s: Dictionary = _state[r]
		var p: Vector2 = s["p"]
		# a bit of UWB jitter
		var u := p + Vector2(sin(_t * 7.3 + p.x * 3.0), cos(_t * 6.1 + p.y * 2.0)) * 0.008
		var d := to_display_xy(u)
		var status := ""
		var goal := Vector3.ZERO
		if s["goal"] != null:
			var g := to_display_xy(s["goal"])
			goal = Vector3(g.x, g.y, 0)
			status = "%.2fm" % p.distance_to(s["goal"])
		# psi_uwb = off + H * yaw_imu  ->  yaw_imu = (psi - off) / H
		var imu_yaw := wrapf((s["psi"] - s["imu_off"]) * H, -PI, PI)
		var height: float = s.get("h", 1.2) + 0.02 * sin(_t * 2.0) if r.begins_with("fly_") else 0.0
		out[r] = {"has_pose": true, "position": Vector3(d.x, d.y, 0.0), "yaw": 0.0,
				"age": 0.05, "has_goal": s["goal"] != null, "goal": goal, "status": status,
				"uwb_position": u, "uwb_yaw": 0.0, "has_orientation": false, "seq": s["seq"], "t": _t,
				"has_imu": true, "imu_yaw": imu_yaw, "imu_age": 0.05, "mag_state": "LOCKED", "height": height}
	return out


func get_anchors() -> Array:
	var out := []
	for a in _anchors:
		out.append({"id": a["id"], "position": a["position"], "age": 0.3})
	return out


func get_stats() -> Dictionary:
	return {"rx": _rx, "tx": _tx, "running": _running}


func get_frame_info() -> String:
	return "demo: UWB frame mirrored"


func send_goal(robot: String, x: float, y: float, _yaw: float) -> void:
	if _state.has(robot):
		_state[robot]["goal"] = to_uwb_xy(Vector2(x, y))
		_tx += 1


func send_goal_3d(robot: String, x: float, y: float, height: float) -> void:
	if _state.has(robot):
		_state[robot]["goal"] = to_uwb_xy(Vector2(x, y))
		_state[robot]["goal_h"] = height
		_tx += 1


func cancel_goal(robot: String) -> void:
	if _state.has(robot):
		_state[robot]["goal"] = null
		_tx += 1


func send_cmd_vel(robot: String, vx: float, vy: float, wz: float) -> void:
	if _state.has(robot):
		_state[robot]["cmd"] = Vector3(vx, vy, wz)
		_state[robot]["cmd_t"] = _t
		_tx += 1


func publish_selection(_robots: PackedStringArray) -> void:
	_tx += 1
