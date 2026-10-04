class_name GenericUnit
extends RobotUnit
## Fallback for robot names without a registered kind: a hologram puck with a
## direction arrow, driven with /<robot>/cmd_vel like a holonomic base.


func kind_tag() -> String:
	return "BOT"


func _build_body() -> void:
	_add_cylinder(_body, Vector3(0, 0.05, 0), 0.15, 0.08, hull_material())
	_add_cylinder(_body, Vector3(0, 0.095, 0), 0.12, 0.01, emissive_material(color, 1.5))
	# arrow towards +x
	var arrow := _add_cylinder(_body, Vector3(0.12, 0.1, 0), 0.04, 0.08, emissive_material(RmUtil.MAGENTA, 4.0), 0.0)
	arrow.rotation.z = -PI / 2.0
