class_name HeadingModel
extends RefCounted
## Robot heading in the UWB frame from the robots' magnetometer IMUs.
##
## The IMU yaw is ENU (from magnetic east, counter-clockwise). The UWB frame is
## rotated and mirrored against ENU, the same for every robot:
##     psi_uwb = theta + h * yaw_enu + delta[robot]
## theta: UWB angle of magnetic east (shared reference, set by the first robot seen
## moving), h: UWB handedness (-1 mirrored), delta: per-robot correction (IMU mounting,
## e.g. the dogs' IMU sits differently, plus calibration error). A robot without its
## own delta has no heading yet: it is measured once (calibration leg or the first
## steady motion) and then refined on its own, never from the other robots.
##
## A magnetometer alone cannot tell where the UWB axes point, so theta comes from
## seeing a robot move (motion direction in UWB vs. its IMU yaw). Once known it is
## saved to user://heading.cfg and loaded at the next start, which gives the ENU
## display frame and all headings right away.

var path := "user://heading.cfg"   # demo mode uses its own file

var handedness := -1.0
var theta = null           # float or null
var delta := {}            # robot -> float
var _dirty := false
var _save_t := 0.0


static func wrap_angle(a: float) -> float:
	return atan2(sin(a), cos(a))


func load_saved() -> bool:
	var cfg := ConfigFile.new()
	if cfg.load(path) != OK:
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
	cfg.save(path)
	_dirty = false


## save at most every 5 s while things change
func tick(dt: float) -> void:
	_save_t -= dt
	if _dirty and _save_t <= 0.0:
		_save_t = 5.0
		save()


func psi(robot: String, yaw_enu: float) -> Variant:
	if theta == null or not delta.has(robot):
		return null
	return wrap_angle(theta + handedness * yaw_enu + delta[robot])


func knows(robot: String) -> bool:
	return theta != null and delta.has(robot)


## a measured UWB heading psi_obs of a robot whose IMU read yaw_enu: the first one
## sets theta, a robot's first one sets its delta, later ones refine its delta (gain k)
func observe(robot: String, psi_obs: float, yaw_enu: float, k: float, dt: float) -> void:
	var t_obs := wrap_angle(psi_obs - handedness * yaw_enu)
	if theta == null:
		theta = t_obs
		delta[robot] = 0.0
	elif not delta.has(robot):
		delta[robot] = wrap_angle(t_obs - theta)
	else:
		var e := wrap_angle(t_obs - theta - delta[robot])
		delta[robot] = wrap_angle(delta[robot] + clampf(k * dt, 0.0, 1.0) * e)
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
