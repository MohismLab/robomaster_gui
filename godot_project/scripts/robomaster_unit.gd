class_name RoboMasterUnit
extends RobotUnit
## RoboMaster S1 (rm_<id>): the Webots model of Robomaster-S1.wbt (robot "agent0"),
## mecanum wheels spinning with the speed, LDS-01 lidar head with its scan plane.

const WHEEL_RADIUS := 0.06
# Webots robot frame: origin 0.0759 m above the floor (wheel radius 0.06 + anchor z -0.0167)
const BODY_HEIGHT := 0.0759
# wheel anchors from the HingeJoints of agent0; left wheels are the mirrored mesh (rotation z = pi)
const WHEELS := [
	[Vector3(0.1166, -0.108057, -0.0167), false],   # front right
	[Vector3(-0.1166, -0.108057, -0.0167), false],  # back right
	[Vector3(0.1166, 0.108057, -0.0167), true],     # front left
	[Vector3(-0.1166, 0.108057, -0.0167), true],    # back left
]

static var _chassis_mesh: Mesh
static var _wheel_mesh: Mesh

var _model: Node3D
var _spinners: Array[Node3D] = []
var _lidar_head: Node3D
var _scan: MeshInstance3D
var _wheel_angle := 0.0


func kind_tag() -> String:
	return "RM"


func _build_body() -> void:
	if _chassis_mesh == null:
		_chassis_mesh = load("res://assets/models/chassis.obj")
		_wheel_mesh = load("res://assets/models/wheel.obj")
	_model = Node3D.new()
	_model.position.y = BODY_HEIGHT
	_model.rotation.x = -PI / 2.0   # Webots z-up -> Godot y-up
	_body.add_child(_model)

	var body := hull_material()
	var chassis := MeshInstance3D.new()
	chassis.mesh = _chassis_mesh
	chassis.material_override = body
	_model.add_child(chassis)

	var wheel_mat := StandardMaterial3D.new()
	wheel_mat.albedo_color = Color(0.05, 0.05, 0.07)
	wheel_mat.metallic = 0.6
	wheel_mat.roughness = 0.45
	wheel_mat.emission_enabled = true
	wheel_mat.emission = color * 0.15
	wheel_mat.next_pass = _rim_mat
	for w in WHEELS:
		var pivot := Node3D.new()
		pivot.position = w[0]
		_model.add_child(pivot)
		var spinner := Node3D.new()
		pivot.add_child(spinner)
		_spinners.append(spinner)
		var mi := MeshInstance3D.new()
		mi.mesh = _wheel_mesh
		mi.material_override = wheel_mat
		if w[1]:
			mi.rotation.z = PI
		spinner.add_child(mi)

	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.02, 0.02, 0.03)
	dark.metallic = 0.4
	dark.roughness = 0.5
	# Jetson Orin (Orin.dae is ~300 MB, drawn as its box)
	_add_box(_model, Vector3(-0.02, 0.0, 0.075), Vector3(0.11, 0.11, 0.045), dark)
	var vent := StandardMaterial3D.new()
	vent.albedo_color = Color.BLACK
	vent.emission_enabled = true
	vent.emission = color
	vent.emission_energy_multiplier = 3.0
	_add_box(_model, Vector3(-0.02, 0.0, 0.0985), Vector3(0.09, 0.006, 0.002), vent)
	_add_box(_model, Vector3(-0.076, 0.0, 0.075), Vector3(0.002, 0.08, 0.008), vent)
	# JetBot camera, front
	_add_box(_model, Vector3(0.07, 0.0, 0.07), Vector3(0.025, 0.03, 0.025), dark)
	var lens := StandardMaterial3D.new()
	lens.albedo_color = Color.BLACK
	lens.emission_enabled = true
	lens.emission = RmUtil.MAGENTA
	lens.emission_energy_multiplier = 5.0
	_add_box(_model, Vector3(0.0835, 0.0, 0.07), Vector3(0.002, 0.012, 0.012), lens)
	# LDS-01 lidar: base + spinning head with a red laser dot
	var base := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.037
	cyl.bottom_radius = 0.037
	cyl.height = 0.012
	base.mesh = cyl
	base.material_override = dark
	base.rotation.x = PI / 2.0
	base.position = Vector3(0, 0, 0.104)
	_model.add_child(base)
	_lidar_head = Node3D.new()
	_lidar_head.position = Vector3(0, 0, 0.122)
	_model.add_child(_lidar_head)
	var head := MeshInstance3D.new()
	var hc := CylinderMesh.new()
	hc.top_radius = 0.03
	hc.bottom_radius = 0.034
	hc.height = 0.024
	head.mesh = hc
	head.material_override = dark
	head.rotation.x = PI / 2.0
	_lidar_head.add_child(head)
	_add_box(_lidar_head, Vector3(0.031, 0, 0), Vector3(0.004, 0.01, 0.008), lens)
	# lidar scan plane: a faint rotating wedge
	_scan = MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(1.2, 0.002)
	q.center_offset = Vector3(0.6, 0, 0)
	_scan.mesh = q
	var sm := StandardMaterial3D.new()
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	sm.cull_mode = BaseMaterial3D.CULL_DISABLED
	sm.albedo_texture = RmUtil.gradient([Color(1, 0.2, 0.3, 0.9), Color(1, 0.2, 0.3, 0.0)], [0.0, 1.0])
	sm.albedo_color = Color(3, 3, 3, 0.6)
	_scan.material_override = sm
	_scan.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_scan.rotation.x = PI / 2.0
	_lidar_head.add_child(_scan)


func _animate(delta: float) -> void:
	_wheel_angle += speed * delta / WHEEL_RADIUS
	for s in _spinners:
		s.rotation.y = _wheel_angle
	_lidar_head.rotation.z += delta * 2.0 * TAU
