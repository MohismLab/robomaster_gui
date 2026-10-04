class_name DroneUnit
extends RobotUnit
## Multirotor (fly_<id>): the 3DR Iris of mohism_robotic/03_quadrotor (Iris.proto,
## iris_empty.wbt), meshes in assets/models/iris. Four propellers spinning, navigation
## lights and an altitude line to the floor. Height from the raw UWB z. Takes 3D move
## orders (Homeworld style, MoveGizmo) as /uwb_nav/<robot>/goal_pose with z = UWB height
## for its own flight stack; never driven with cmd_vel.

# Iris.proto propellers (Webots x forward, y left, z up) and spin direction
const PROPS := [
	[Vector3(0.13, -0.22, 0.023), "ccw", true],    # m1, front right (blue)
	[Vector3(-0.13, 0.20, 0.023), "ccw", false],   # m2, back left
	[Vector3(0.13, 0.22, 0.023), "cw", true],      # m3, front left (blue)
	[Vector3(-0.13, -0.20, 0.023), "cw", false],   # m4, back right
]

static var _scenes := {}

var _model: Node3D
var _rotors: Array = []       # [Node3D, direction]
var _spin := 0.0
var _alt_line: MeshInstance3D
var _ground := 0.0            # lift so the landing gear stands on the floor


static func _scene(n: String) -> PackedScene:
	if not _scenes.has(n):
		_scenes[n] = load("res://assets/models/iris/%s.dae" % n)
	return _scenes[n]


func kind_tag() -> String:
	return "FLY"


func can_drive() -> bool:
	return false


func can_fly() -> bool:
	return true


func hover_height() -> float:
	return height if height > 0.12 else 0.0


func ring_size() -> float:
	return 1.0


func label_height() -> float:
	return 0.4


static func _webots_to_godot(p: Vector3) -> Vector3:
	return Vector3(p.x, p.z, -p.y)


## material on every mesh of an imported scene; drop the cameras / lights the
## Collada files carry
static func _override(n: Node, mat: Material) -> void:
	if n is MeshInstance3D:
		n.material_override = mat
	for c in n.get_children():
		if c is Camera3D or c is Light3D:
			n.remove_child(c)
			c.free()
		else:
			_override(c, mat)


static func _aabb(n: Node, xf: Transform3D, box: Array) -> void:
	if n is MeshInstance3D and n.mesh:
		var b: AABB = (xf * n.transform) * n.mesh.get_aabb()
		box[0] = b if box[0] == null else box[0].merge(b)
	var x2: Transform3D = xf * n.transform if n is Node3D else xf
	for c in n.get_children():
		_aabb(c, x2, box)


func _build_body() -> void:
	_model = Node3D.new()
	_body.add_child(_model)
	# the Collada importer already turns the Z_UP meshes into Godot's y-up
	var frame := _scene("iris").instantiate()
	_override(frame, hull_material(Color(0.05, 0.05, 0.06)))
	_model.add_child(frame)
	var blue := hull_material(Color(0.0, 0.05, 0.4))
	var black := hull_material(Color(0.02, 0.02, 0.02))
	for p in PROPS:
		var r := Node3D.new()
		r.position = _webots_to_godot(p[0])
		_model.add_child(r)
		var prop := _scene("iris_prop_" + p[1]).instantiate()
		_override(prop, blue if p[2] else black)
		r.add_child(prop)
		# motion-blur disc, shown while spinning fast
		var disc := _add_cylinder(r, Vector3(0, 0.005, 0), 0.12, 0.002, emissive_material(color, 0.5))
		disc.transparency = 0.75
		disc.name = "blur"
		_rotors.append([r, 1.0 if p[1] == "ccw" else -1.0])
		_add_box(_model, r.position + Vector3(0, -0.02, 0), Vector3(0.015, 0.015, 0.015),
				emissive_material(Color(0.1, 1.0, 0.3) if p[2] else Color(1.0, 0.1, 0.15), 6.0))
	var box := [null]
	_aabb(_model, Transform3D.IDENTITY, box)
	if box[0] != null:
		_ground = -box[0].position.y
	_model.position.y = _ground
	# altitude line (robot space, floor up to the body)
	_alt_line = MeshInstance3D.new()
	var c := CylinderMesh.new()
	c.top_radius = 0.004
	c.bottom_radius = 0.004
	c.height = 1.0
	_alt_line.mesh = c
	_alt_line.material_override = emissive_material(color, 2.0)
	_alt_line.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_alt_line)


func _animate(delta: float) -> void:
	var flying := height > 0.12
	_spin += delta * (70.0 if flying else 4.0)
	for r in _rotors:
		r[0].rotation.y = _spin * r[1]
		r[0].get_node("blur").visible = flying
	var t := Time.get_ticks_msec() / 1000.0
	if flying:
		_model.position.y = _ground + 0.01 * sin(t * 3.0 + index)
		var v := global_transform.basis.inverse() * _vel
		_model.rotation.z = clampf(-v.x * 0.4, -0.3, 0.3)
		_model.rotation.x = clampf(v.z * 0.4, -0.3, 0.3)
	else:
		_model.position.y = _ground
		_model.rotation = Vector3.ZERO
	var h := _body.position.y
	_alt_line.visible = h > 0.15
	_alt_line.scale.y = maxf(h, 0.01)
	_alt_line.position.y = h / 2.0
