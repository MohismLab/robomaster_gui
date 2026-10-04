class_name AnchorBeacon
extends Node3D
## UWB anchor: a pylon standing on the floor up to the antenna (anchor z), with
## pulse rings, a light beam, rising data bits and a holographic label.

var anchor_id := 0
var ros_position := Vector3.ZERO
var age := 0.0
var _height := 1.0
var _mast: MeshInstance3D
var _head: Node3D
var _label: Label3D
var _light: OmniLight3D
var _rings: Array[MeshInstance3D] = []
var _beam: MeshInstance3D
var _beam_mat: ShaderMaterial
var _column: GPUParticles3D
var _head_mat: StandardMaterial3D

const COLOR := RmUtil.YELLOW
const BEAM_HEIGHT := 6.0


func setup(id: int) -> void:
	anchor_id = id
	name = "Anchor_%d" % id
	var metal := StandardMaterial3D.new()
	metal.albedo_color = Color(0.06, 0.06, 0.08)
	metal.metallic = 0.9
	metal.roughness = 0.3

	# base plate with a glowing hex ring
	var plate := MeshInstance3D.new()
	var pc := CylinderMesh.new()
	pc.top_radius = 0.16
	pc.bottom_radius = 0.2
	pc.height = 0.04
	pc.radial_segments = 6
	plate.mesh = pc
	plate.material_override = metal
	plate.position.y = 0.02
	add_child(plate)

	_mast = MeshInstance3D.new()
	var mc := CylinderMesh.new()
	mc.top_radius = 0.018
	mc.bottom_radius = 0.025
	mc.height = 1.0
	mc.radial_segments = 8
	_mast.mesh = mc
	_mast.material_override = metal
	add_child(_mast)

	# glowing rings along the mast
	var neon := StandardMaterial3D.new()
	neon.albedo_color = Color.BLACK
	neon.emission_enabled = true
	neon.emission = COLOR
	neon.emission_energy_multiplier = 2.0
	for k in 3:
		var r := MeshInstance3D.new()
		var tm := TorusMesh.new()
		tm.inner_radius = 0.028
		tm.outer_radius = 0.036
		r.mesh = tm
		r.material_override = neon
		add_child(r)
		_rings.append(r)

	# antenna head: an octahedron-ish crystal
	_head = Node3D.new()
	add_child(_head)
	_head_mat = StandardMaterial3D.new()
	_head_mat.albedo_color = Color(0.1, 0.08, 0.0)
	_head_mat.metallic = 0.3
	_head_mat.roughness = 0.2
	_head_mat.emission_enabled = true
	_head_mat.emission = COLOR
	_head_mat.emission_energy_multiplier = 2.5
	var crystal := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.0
	cm.bottom_radius = 0.07
	cm.height = 0.1
	cm.radial_segments = 4
	cm.rings = 1
	crystal.mesh = cm
	crystal.material_override = _head_mat
	crystal.position.y = 0.05
	_head.add_child(crystal)
	var crystal2 := crystal.duplicate() as MeshInstance3D
	crystal2.rotation.x = PI
	crystal2.position.y = -0.05
	_head.add_child(crystal2)

	_light = OmniLight3D.new()
	_light.light_color = COLOR
	_light.light_energy = 0.6
	_light.omni_range = 1.5
	_head.add_child(_light)

	_beam = MeshInstance3D.new()
	var bc := CylinderMesh.new()
	bc.top_radius = 0.01
	bc.bottom_radius = 0.03
	bc.height = BEAM_HEIGHT
	bc.cap_top = false
	bc.cap_bottom = false
	_beam.mesh = bc
	_beam_mat = RmUtil.shader_material("res://shaders/beam.gdshader",
			{"color": COLOR, "height": BEAM_HEIGHT, "intensity": 0.35, "speed": 0.7})
	_beam.material_override = _beam_mat
	_beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_head.add_child(_beam)
	_beam.position.y = BEAM_HEIGHT / 2.0

	# radio pulses: floor rings and rings around the antenna
	for k in 3:
		var pr := MeshInstance3D.new()
		var pm := PlaneMesh.new()
		pm.size = Vector2(3.0, 3.0)
		pr.mesh = pm
		pr.material_override = RmUtil.shader_material("res://shaders/pulse_ring.gdshader",
				{"color": COLOR, "period": 3.0, "offset": k / 3.0, "intensity": 0.9, "width": 0.015})
		pr.position.y = 0.01
		pr.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(pr)
	var hp := MeshInstance3D.new()
	var hpm := PlaneMesh.new()
	hpm.size = Vector2(1.2, 1.2)
	hp.mesh = hpm
	hp.material_override = RmUtil.shader_material("res://shaders/pulse_ring.gdshader",
			{"color": COLOR, "period": 1.2, "intensity": 1.5, "width": 0.03, "hex": 1.0})
	hp.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_head.add_child(hp)

	_column = Fx.rising_column(COLOR, 0.25, 0.5, 40)
	add_child(_column)

	_label = Label3D.new()
	_label.font = RmUtil.font(true)
	_label.font_size = 36
	_label.outline_size = 10
	_label.outline_modulate = Color(0, 0, 0, 0.85)
	_label.modulate = COLOR
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.fixed_size = true
	_label.pixel_size = 0.0008
	add_child(_label)


func apply(d: Dictionary) -> void:
	ros_position = d["position"]
	age = d.get("age", 0.0)
	position = RmUtil.ros_to_godot(Vector3(ros_position.x, ros_position.y, 0.0))
	_height = maxf(ros_position.z, 0.2)
	_mast.mesh.height = _height
	_mast.position.y = _height / 2.0
	for k in _rings.size():
		_rings[k].position.y = _height * (0.25 + 0.25 * k)
	_head.position.y = _height
	_label.position.y = _height + 0.3
	_label.text = "◆ A%d\n%.2f %.2f %.2f" % [anchor_id, ros_position.x, ros_position.y, ros_position.z]


func antenna_position() -> Vector3:
	return global_position + Vector3(0, _height, 0)


func _process(delta: float) -> void:
	var t := Time.get_ticks_msec() / 1000.0
	_head.rotation.y += delta * 1.2
	var stale := age > 5.0
	var c := Color(0.5, 0.3, 0.1) if stale else COLOR
	_head_mat.emission = c
	_head_mat.emission_energy_multiplier = 1.2 + 1.0 * pow(0.5 + 0.5 * sin(t * 5.0 + anchor_id), 4.0)
	_light.light_energy = 0.5 + 0.3 * sin(t * 5.0 + anchor_id)
	for k in _rings.size():
		_rings[k].position.y = fmod(_height * (k / 3.0) + t * 0.3, _height)
	_beam.visible = not stale
	_column.emitting = not stale
