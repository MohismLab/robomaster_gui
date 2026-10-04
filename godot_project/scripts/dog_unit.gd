class_name DogUnit
extends RobotUnit
## Quadruped (dog_<id>): the Bigdog model of mohism_robotic/05_quadruped
## (robot-Bigdog-A.SLDASM, quadruped.wbt), meshes in assets/models/bigdog.
## Per leg: hip roll (x), thigh pitch (y), knee pitch (y), fixed foot; the legs trot
## (diagonal pairs) with the walking speed. Driven like the RoboMaster with
## /<robot>/cmd_vel (x forward, y left, yaw rate).

# URDF/Webots robot frame (x forward, y left, z up): body origin 0.329 m above the
# floor in the zero (standing) pose
const BODY_HEIGHT := 0.329
# joint origins from robot-Bigdog-A.SLDASM.urdf: hip, thigh, knee, foot
const LEGS := {
	"fr": [Vector3(0.1393, -0.061, 0), Vector3(0.065, -0.0115, 0), Vector3(-0.1247, -0.0572, -0.14861), Vector3(0.11222, -0.0163, -0.14758)],
	"fl": [Vector3(0.1393, 0.061, 0), Vector3(0.065, 0.0115, 0), Vector3(-0.1247, 0.0572, -0.14861), Vector3(0.11238, 0.0163, -0.14746)],
	"br": [Vector3(-0.1393, -0.061, 0), Vector3(-0.065, -0.0115, 0), Vector3(-0.1247, -0.0572, -0.14861), Vector3(0.1122, -0.0163, -0.14759)],
	"bl": [Vector3(-0.1393, 0.061, 0), Vector3(-0.065, 0.0115, 0), Vector3(-0.1247, 0.0572, -0.14861), Vector3(0.1122, 0.0163, -0.1476)],
}

static var _meshes := {}

var _model: Node3D
var _legs: Array = []         # [hip, thigh, knee, phase]
var _gait := 0.0


static func _mesh(n: String) -> Mesh:
	if not _meshes.has(n):
		_meshes[n] = load("res://assets/models/bigdog/%s.obj" % n)
	return _meshes[n]


func kind_tag() -> String:
	return "DOG"


func ring_size() -> float:
	return 0.9


func label_height() -> float:
	return 0.6


func _part(parent: Node3D, mesh_name: String, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = _mesh(mesh_name)
	mi.material_override = mat
	parent.add_child(mi)


func _joint(parent: Node3D, pos: Vector3) -> Node3D:
	var j := Node3D.new()
	j.position = pos
	parent.add_child(j)
	return j


func _build_body() -> void:
	var hull := hull_material(Color(0.22, 0.23, 0.27))   # Webots: light grey 0.75
	var dark := hull_material(Color(0.07, 0.07, 0.09))
	_model = Node3D.new()
	_model.position.y = BODY_HEIGHT
	_model.rotation.x = -PI / 2.0   # URDF z-up -> Godot y-up
	_body.add_child(_model)
	_part(_model, "body", hull)
	for leg in LEGS:
		var o: Array = LEGS[leg]
		var hip := _joint(_model, o[0])
		_part(hip, leg + "_1", dark)
		var thigh := _joint(hip, o[1])
		_part(thigh, leg + "_2", hull)
		var knee := _joint(thigh, o[2])
		_part(knee, leg + "_3", dark)
		var foot := _joint(knee, o[3])
		_part(foot, leg + "_4", emissive_material(color, 1.5))
		# trot: front-right with back-left
		var phase := 0.0 if leg in ["fr", "bl"] else PI
		_legs.append([hip, thigh, knee, phase])


func _animate(delta: float) -> void:
	var walk := clampf(speed / 0.3, 0.0, 1.0)
	_gait += delta * (1.5 + 9.0 * walk)
	var t := Time.get_ticks_msec() / 1000.0
	for l in _legs:
		var a: float = _gait + l[3]
		var lift := maxf(sin(a), 0.0) * walk
		l[1].rotation.y = cos(a) * 0.35 * walk          # thigh swings fore / aft
		l[2].rotation.y = -0.5 * lift                    # knee folds while the foot is in the air
		l[0].rotation.x = 0.03 * sin(t * 1.3 + a) * (1.0 - walk)   # idle sway
	_model.position.y = BODY_HEIGHT + 0.004 * sin(t * 2.0) + 0.012 * walk * absf(cos(_gait))
