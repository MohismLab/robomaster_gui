class_name NavController
extends RefCounted
## Click-to-go for one holonomic robot, computed in the UWB frame and sent
## straight to /<robot>/cmd_vel (the Godot replacement of uwb_goal_nav.py).
##
## Heading = UWB-frame angle psi of the body +x axis, from (first match):
##   1. the pose orientation, while /uwb_ekf/<robot>/heading_valid (latched Bool) is true
##   2. the robot's magnetometer IMU through the shared HeadingModel
##      (psi = theta + h * yaw_enu + delta[robot])
##   3. a motion calibration alone (no IMU), valid as long as the robot does not turn
## Whenever the robot moves under a known, steady body command (navigation or manual
## drive) the motion direction seen by UWB is compared with the command, which
## learns / refines the HeadingModel. Without any heading yet, an order first drives
## calib_dist along body +x.
##
## Body frame (cmd_vel): x forward, y left. Body +y points to psi + h * 90 deg in the
## UWB frame, h = -1 because the UWB frame is mirrored (same for every robot).

enum { IDLE, CALIB, GOING }

# tunables
var max_speed := 0.3        # [m/s]
var max_accel := 0.4        # [m/s^2]
var k_p := 0.8              # [1/s]
var tolerance := 0.05       # [m]
var calib_dist := 0.25      # [m] along body +x
var calib_speed := 0.1      # [m/s]
var settle_time := 0.6      # [s] standing still before/after the calibration leg
var k_heading := 0.5        # [1/s] online heading correction
var pose_timeout := 0.5     # [s]
var imu_timeout := 0.5      # [s]
var goal_timeout := 90.0    # [s]
var avoid_radius := 0.55    # [m] keep this far from the other robots
var vel_window := 0.6       # [s]

var robot := ""
var bridge: Object
var model: HeadingModel
var state := IDLE
var goal = null             # Vector2, UWB frame
var pos := Vector2.ZERO     # UWB frame
var psi = null              # float or null, UWB frame
var yaw_enu = null          # latest IMU yaw (ENU) or null
var heading_source := "-"
var status := ""
var psi_motion = null       # heading from a calibration without IMU
var _force_calib := false

var _hist: Array = []       # [t, Vector2] per new pose
var _last_seq := -1
var _last_v := 0.0
var _goal_t := 0.0
var _stop_burst := 0
var _bad_t := 0.0
var _now := 0.0
var _calib_phase := 0       # 0 settle, 1 drive, 2 settle at the end
var _calib_start := Vector2.ZERO
var _phase_t := 0.0
var _imu_sum := Vector2.ZERO
var _cmd := Vector3.ZERO    # last body command (vx, vy, wz)
var _cmd_t := -10.0
var _cmd_since := 0.0       # time the body command direction last changed
var _log: Callable


func _init(robot_: String, bridge_: Object, model_: HeadingModel, log_fn: Callable) -> void:
	robot = robot_
	bridge = bridge_
	model = model_
	_log = log_fn


static func wrap_angle(a: float) -> float:
	return atan2(sin(a), cos(a))


func has_goal() -> bool:
	return goal != null and state != IDLE


# ---------------------------------------------------------------- commands

func order(target: Vector2) -> void:
	goal = target
	_goal_t = _now
	_bad_t = 0.0
	# make sure uwb_goal_nav.py (if running) lets go of this robot
	bridge.cancel_goal(robot)
	if state == CALIB:
		return
	if psi == null or _force_calib:
		_start_calibration()
	else:
		state = GOING


func stop(reason := "") -> void:
	if state != IDLE:
		_stop_burst = 3
	state = IDLE
	goal = null
	_last_v = 0.0
	status = reason


## forget this robot's heading correction; the next order drives the calibration leg
## leave the robot to someone else (its magnetometer calibration): stop following the
## goal without sending anything, the zero twists would fight the calibration spin
func abort_silent(reason := "") -> void:
	state = IDLE
	goal = null
	_last_v = 0.0
	_stop_burst = 0
	status = reason


func reset_heading() -> void:
	model.reset(robot)
	psi_motion = null
	_force_calib = true


## body command sent by someone else (manual drive), used to learn the heading
func note_body_cmd(vx: float, vy: float, wz: float) -> void:
	_set_cmd(Vector3(vx, vy, wz))


func _set_cmd(c: Vector3) -> void:
	var v := Vector2(c.x, c.y)
	var old := Vector2(_cmd.x, _cmd.y)
	if v.length() < 1e-3 or old.length() < 1e-3 or absf(wrap_angle(v.angle() - old.angle())) > deg_to_rad(15.0) \
			or absf(c.z) > 0.05:
		_cmd_since = _now
	_cmd = c
	_cmd_t = _now


func _send(vx: float, vy: float, wz: float) -> void:
	_set_cmd(Vector3(vx, vy, wz))
	bridge.send_cmd_vel(robot, vx, vy, wz)


func _start_calibration() -> void:
	state = CALIB
	_calib_phase = 0
	_phase_t = _now
	_imu_sum = Vector2.ZERO
	_log.call("%s: no heading yet, driving %.2f m along body +x" % [robot, calib_dist])


# ---------------------------------------------------------------- estimation

func _mean_pos(window: float) -> Vector2:
	var s := Vector2.ZERO
	var n := 0
	for h in _hist:
		if _now - h[0] <= window:
			s += h[1]
			n += 1
	return s / n if n > 0 else pos


func _velocity() -> Variant:
	if _hist.size() < 2:
		return null
	var a = _hist[0]
	var b = _hist[-1]
	if b[0] - a[0] < 0.5 * vel_window:
		return null
	return (b[1] - a[1]) / (b[0] - a[0])


func _update_heading(s: Dictionary) -> void:
	var imu_ok: bool = s.get("has_imu", false) and s.get("imu_age", 1e9) < imu_timeout
	yaw_enu = s["imu_yaw"] if imu_ok else null
	if s.get("has_orientation", false):
		psi = s["uwb_yaw"]
		heading_source = "EKF"
	elif imu_ok and model.knows(robot):
		psi = model.psi(robot, yaw_enu)
		heading_source = "IMU"
	elif psi_motion != null:
		psi = psi_motion
		heading_source = "MOTION"
	else:
		psi = null
		heading_source = "-"


## motion seen by UWB vs. a steady body command -> heading measurement
## returns the error against the current heading estimate (or null)
func _observe_motion(dt: float) -> Variant:
	if _now - _cmd_t > 0.3 or _now - _cmd_since < vel_window or absf(_cmd.z) > 0.05:
		return null
	var body := Vector2(_cmd.x, _cmd.y)
	var v_obs = _velocity()
	if v_obs == null or v_obs.length() < 0.06 or body.length() < 0.05:
		return null
	# body vector at angle b moves the robot along psi + h * b in the UWB frame
	var psi_meas := wrap_angle(v_obs.angle() - model.handedness * body.angle())
	var err = null
	if psi != null:
		err = wrap_angle(psi_meas - psi)
		if absf(err) > deg_to_rad(60.0):
			return err   # far off: let the caller decide (mirror guard), do not learn from it
	if heading_source == "EKF":
		return err
	if yaw_enu != null:
		var first: bool = model.theta == null
		var new_robot := not model.knows(robot)
		model.observe(robot, psi_meas, yaw_enu, k_heading, dt)
		if first:
			_log.call("%s: magnetic frame locked from motion (UWB x-axis at %.1f° from east)" % [
				robot, rad_to_deg(-model.handedness * model.theta)])
		elif new_robot:
			_log.call("%s: IMU heading measured from motion (correction %.1f°)" % [
				robot, rad_to_deg(model.delta[robot])])
	elif psi_motion != null:
		psi_motion = wrap_angle(psi_motion + clampf(k_heading * dt, 0.0, 1.0) * err)
	return err


# ---------------------------------------------------------------- control

## one control step; s = RosBridge.get_robot_states()[robot], others = UWB positions
func tick(s: Dictionary, dt: float, others: Array) -> void:
	_now += dt
	if not s.get("has_pose", false):
		return
	pos = s["uwb_position"]
	var seq: int = s.get("seq", 0)
	if seq != _last_seq:
		_last_seq = seq
		_hist.append([_now, pos])
	while _hist.size() > 2 and _now - _hist[0][0] > maxf(vel_window, settle_time):
		_hist.pop_front()
	_update_heading(s)
	var fresh: bool = s.get("age", 1e9) < pose_timeout

	if s.get("calibrating", false):
		if state != IDLE:
			abort_silent("MAG CALIB")
			_log.call("%s: magnetometer calibration running, navigation dropped" % robot)
		return

	var err = null
	if state != CALIB:
		err = _observe_motion(dt)
		_update_heading(s)
	if state != IDLE and not fresh:
		stop("UWB LOST")
		_log.call("%s: UWB pose lost, stopping" % robot)
	match state:
		CALIB:
			_calibrate(s)
		GOING:
			_go(dt, others, err)
	if _stop_burst > 0:
		_stop_burst -= 1
		_send(0.0, 0.0, 0.0)


func _calibrate(s: Dictionary) -> void:
	status = "CALIB"
	match _calib_phase:
		0:
			if _now - _phase_t >= settle_time:
				_calib_start = _mean_pos(settle_time * 0.8)
				_calib_phase = 1
		1:
			if yaw_enu != null:
				_imu_sum += Vector2.from_angle(yaw_enu)
			if _mean_pos(0.25).distance_to(_calib_start) < calib_dist:
				_send(calib_speed, 0.0, 0.0)
			else:
				_stop_burst = 3
				_calib_phase = 2
				_phase_t = _now
		2:
			if _now - _phase_t < settle_time:
				return
			var psi_obs := (_mean_pos(settle_time * 0.8) - _calib_start).angle()
			if yaw_enu != null and _imu_sum != Vector2.ZERO:
				model.calibrate(robot, psi_obs, _imu_sum.angle())
				psi_motion = null
				_log.call("%s: calibrated, body x at %.1f° in UWB (UWB x-axis at %.1f° from east)" % [
					robot, rad_to_deg(psi_obs), rad_to_deg(-model.handedness * model.theta)])
			else:
				psi_motion = psi_obs
				_log.call("%s: calibrated, body x at %.1f° (no IMU, do not rotate)" % [robot, rad_to_deg(psi_obs)])
			_force_calib = false
			_update_heading(s)
			state = GOING if goal != null else IDLE


func _go(dt: float, others: Array, err) -> void:
	if psi == null:
		_start_calibration()
		return
	var e: Vector2 = goal - pos
	var dist := e.length()
	if dist < tolerance:
		stop("ARRIVED")
		_log.call("%s: goal reached (%.1f cm)" % [robot, dist * 100.0])
		return
	if _now - _goal_t > goal_timeout:
		stop("TIMEOUT")
		_log.call("%s: goal timeout" % robot)
		return

	# a heading far off for a while (bad theta, magnetic disturbance): recalibrate
	if err != null and absf(err) > deg_to_rad(100.0):
		_bad_t += dt
		if _bad_t > 1.5:
			_log.call("%s: moving %.0f° off the command, recalibrating" % [robot, rad_to_deg(err)])
			reset_heading()
			var g = goal
			stop("HEADING ERROR")
			goal = g
			_start_calibration()
			return
	elif err != null:
		_bad_t = maxf(_bad_t - dt, 0.0)

	var v := minf(minf(max_speed, k_p * dist), _last_v + max_accel * dt)
	_last_v = v
	var w := e / dist * v
	# keep away from the other robots
	for o in others:
		var d: Vector2 = pos - o
		var r := d.length()
		if r < avoid_radius and r > 1e-3:
			w += d / r * max_speed * (avoid_radius - r) / avoid_radius
	w = w.limit_length(max_speed)

	var c := cos(psi)
	var s := sin(psi)
	var h := model.handedness
	_send(w.x * c + w.y * s, h * (-w.x * s + w.y * c), 0.0)
	status = "%.2fm" % dist
