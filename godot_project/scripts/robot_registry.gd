class_name RobotRegistry
## Robot kinds by name prefix: "<prefix>_<id>" (rm_3, dog_0, fly_12, ...).
## A new kind = a RobotUnit subclass + one line in KINDS.

const KINDS := {
	"rm": preload("res://scripts/robomaster_unit.gd"),
	"dog": preload("res://scripts/dog_unit.gd"),
	"fly": preload("res://scripts/drone_unit.gd"),
}
const FALLBACK := preload("res://scripts/generic_unit.gd")

## base hue of each kind, so rm_0 / dog_0 / fly_0 do not share a color
const HUES := {
	"rm": -1.0,     # RmUtil.TEAM_COLORS palette
	"dog": 0.08,
	"fly": 0.55,
}


static func prefix_of(robot: String) -> String:
	var k := robot.rfind("_")
	return robot.substr(0, k) if k > 0 and robot.substr(k + 1).is_valid_int() else robot


static func create(robot: String) -> RobotUnit:
	var script: GDScript = KINDS.get(prefix_of(robot), FALLBACK)
	return script.new()
