class_name HeadingModel
extends RefCounted
## Robot heading in the UWB frame from the robots' magnetometer IMUs.
##
## The IMU yaw is ENU (from magnetic east, counter-clockwise). The UWB frame is
## rotated and mirrored against ENU, the same for every robot:
##     psi_uwb = theta + h * yaw_enu + delta[robot]
## theta: UWB angle of magnetic east (shared), h: UWB handedness (-1 mirrored),
## delta: small per-robot residual (IMU mounting / calibration error).
##
## A magnetometer alone cannot tell where the UWB axes point, so theta comes from
## seeing a robot move (motion direction in UWB vs. its IMU yaw). Once known it is
## saved to user://heading.cfg and loaded at the next start, which gives the ENU
## display frame and all headings right away.

const PATH := "user://heading.cfg"
const K_THETA := 0.05      # [1/s] how fast the shared theta follows the robots

var handedness := -1.0
var theta = null           # float or null
var delta := {}            # robot -> float
var _dirty := false
var _save_t := 0.0


static func wrap_angle(a: float) -> float:
	return atan2(sin(a), cos(a))


func load_saved() -> bool:
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return false
	if cfg.get_value("frame", "handedness", handedness) != handedness:
		return false   # saved for another handedness, ignore
	theta = cfg.get_value("frame", "theta", null)
	var d = cfg.get_value("frame", "delta", {})
	if d is Dictionary:
		delta = d
	return theta != null


func save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("frame", "handedness", handedness)
	cfg.set_value("frame", "theta", theta)
	cfg.set_value("frame", "delta", delta)
	cfg.set_value("frame", "saved", Time.get_datetime_string_from_system())
	cfg.save(PATH)
	_dirty = false


## save at most every 5 s while things change
func tick(dt: float) -> void:
	_save_t -= dt
	if _dirty and _save_t <= 0.0:
		_save_t = 5.0
		save()


func psi(robot: String, yaw_enu: float) -> Variant:
	if theta == null:
		return null
	return wrap_angle(theta + handedness * yaw_enu + delta.get(robot, 0.0))


## a measured UWB heading psi_obs of a robot whose IMU read yaw_enu
## first: sets theta; afterwards: pulls delta[robot] (fast, gain k) and theta (slow)
func observe(robot: String, psi_obs: float, yaw_enu: float, k: float, dt: float) -> void:
	var t_obs := wrap_angle(psi_obs - handedness * yaw_enu)
	if theta == null:
		theta = t_obs
		delta[robot] = 0.0
	else:
		var e := wrap_angle(t_obs - theta - delta.get(robot, 0.0))
		delta[robot] = wrap_angle(delta.get(robot, 0.0) + clampf(k * dt, 0.0, 1.0) * e)
		# keep the residuals centred: move theta towards the mean of theta + delta
		var m := 0.0
		for r in delta:
			m += delta[r]
		m /= maxf(delta.size(), 1)
		var step := clampf(K_THETA * dt, 0.0, 1.0) * m
		theta = wrap_angle(theta + step)
		for r in delta:
			delta[r] -= step
	_dirty = true


## a one-shot calibration result: set delta[robot] exactly (theta first if unknown)
func calibrate(robot: String, psi_obs: float, yaw_enu: float) -> void:
	var t_obs := wrap_angle(psi_obs - handedness * yaw_enu)
	if theta == null:
		theta = t_obs
	delta[robot] = wrap_angle(t_obs - theta)
	_dirty = true
	_save_t = 0.0


func reset(robot := "") -> void:
	if robot == "":
		theta = null
		delta.clear()
	else:
		delta.erase(robot)
	_dirty = true
