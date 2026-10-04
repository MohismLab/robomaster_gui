class_name Fx
## Factory for the glowing GPU particle systems used all over the scene.

static var _dot: Texture2D
static var _square: Texture2D


## soft round glow sprite
static func dot_texture() -> Texture2D:
	if _dot == null:
		var g := Gradient.new()
		g.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0.35), Color(1, 1, 1, 0)])
		g.offsets = PackedFloat32Array([0.0, 0.25, 1.0])
		var t := GradientTexture2D.new()
		t.gradient = g
		t.fill = GradientTexture2D.FILL_RADIAL
		t.fill_from = Vector2(0.5, 0.5)
		t.fill_to = Vector2(1.0, 0.5)
		t.width = 64
		t.height = 64
		_dot = t
	return _dot


## hard-edged pixel, for "data" bits
static func square_texture() -> Texture2D:
	if _square == null:
		var img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
		img.fill(Color(1, 1, 1, 1))
		for i in 8:
			img.set_pixel(i, 0, Color(1, 1, 1, 0.4))
			img.set_pixel(0, i, Color(1, 1, 1, 0.4))
		_square = ImageTexture.create_from_image(img)
	return _square


static func sprite_mesh(size: float, energy := 3.0, square := false, stretch := 1.0) -> QuadMesh:
	var q := QuadMesh.new()
	q.size = Vector2(size, size * stretch)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.vertex_color_use_as_albedo = true
	m.albedo_color = Color(energy, energy, energy, 1.0)
	m.albedo_texture = square_texture() if square else dot_texture()
	m.disable_receive_shadows = true
	m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	if stretch == 1.0:
		m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	q.material = m
	return q


static func _particles(amount: int, lifetime: float, mat: ParticleProcessMaterial, mesh: Mesh) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = amount
	p.lifetime = lifetime
	p.process_material = mat
	p.draw_pass_1 = mesh
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return p


static func fade_ramp(c: Color, c2 = null) -> GradientTexture1D:
	var end: Color = c if c2 == null else c2
	return RmUtil.gradient([Color(c, 0.0), Color(c, 1.0), Color(end, 0.7), Color(end, 0.0)],
			[0.0, 0.1, 0.6, 1.0])


## slow floating data motes over the whole arena
static func ambient_motes(extents: Vector3) -> GPUParticles3D:
	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	m.emission_box_extents = extents
	m.direction = Vector3(0, 1, 0)
	m.spread = 25.0
	m.initial_velocity_min = 0.05
	m.initial_velocity_max = 0.25
	m.gravity = Vector3(0, 0.02, 0)
	m.turbulence_enabled = true
	m.turbulence_noise_strength = 0.6
	m.turbulence_noise_scale = 6.0
	m.scale_min = 0.4
	m.scale_max = 1.4
	m.color_ramp = RmUtil.gradient([Color(0, 0.94, 1, 0), Color(0, 0.94, 1, 0.9), Color(1, 0.16, 0.43, 0.8), Color(1, 0.16, 0.43, 0)],
			[0.0, 0.2, 0.75, 1.0])
	var p := _particles(500, 9.0, m, sprite_mesh(0.025, 1.6, true))
	p.visibility_aabb = AABB(-extents * 1.5, extents * 3.0)
	p.preprocess = 9.0
	return p


## neon rain: thin streaks aligned to their velocity
static func rain(extents: Vector3) -> GPUParticles3D:
	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	m.emission_box_extents = extents
	m.direction = Vector3(0.15, -1, 0.05)
	m.spread = 2.0
	m.initial_velocity_min = 9.0
	m.initial_velocity_max = 13.0
	m.gravity = Vector3(0, -4, 0)
	m.color_ramp = RmUtil.gradient([Color(0.5, 0.8, 1, 0), Color(0.5, 0.8, 1, 0.35), Color(0.9, 0.4, 1, 0.25), Color(0.9, 0.4, 1, 0)],
			[0.0, 0.15, 0.8, 1.0])
	var p := _particles(1200, 1.3, m, sprite_mesh(0.008, 1.2, true, 18.0))
	p.transform_align = GPUParticles3D.TRANSFORM_ALIGN_Z_BILLBOARD_Y_TO_VELOCITY
	p.visibility_aabb = AABB(-extents * 2.0 - Vector3(0, 20, 0), extents * 4.0 + Vector3(0, 40, 0))
	p.preprocess = 2.0
	return p


## splashes where the rain hits the floor
static func splashes(extents: Vector3) -> GPUParticles3D:
	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	m.emission_box_extents = Vector3(extents.x, 0.01, extents.z)
	m.direction = Vector3(0, 1, 0)
	m.spread = 60.0
	m.initial_velocity_min = 0.3
	m.initial_velocity_max = 0.8
	m.gravity = Vector3(0, -6, 0)
	m.scale_min = 0.5
	m.scale_max = 1.0
	m.color_ramp = fade_ramp(Color(0.6, 0.9, 1.0))
	var p := _particles(500, 0.35, m, sprite_mesh(0.02, 1.2))
	p.visibility_aabb = AABB(-extents - Vector3(0, 1, 0), extents * 2.0 + Vector3(0, 2, 0))
	return p


## sparks thrown behind a moving robot (world space so they stay behind)
static func trail(color: Color) -> GPUParticles3D:
	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	m.emission_box_extents = Vector3(0.14, 0.01, 0.1)
	m.direction = Vector3(0, 1, 0)
	m.spread = 70.0
	m.initial_velocity_min = 0.05
	m.initial_velocity_max = 0.35
	m.gravity = Vector3(0, -0.4, 0)
	m.damping_min = 0.5
	m.damping_max = 1.5
	m.scale_min = 0.5
	m.scale_max = 1.2
	m.scale_curve = RmUtil.curve([Vector2(0, 1), Vector2(1, 0)])
	m.color_ramp = fade_ramp(Color(1, 1, 1).lerp(color, 0.4), color)
	var p := _particles(160, 1.1, m, sprite_mesh(0.03, 4.0))
	p.local_coords = false
	p.visibility_aabb = AABB(Vector3(-4, -1, -4), Vector3(8, 3, 8))
	return p


## sparks orbiting a selected robot
static func orbit_sparks(color: Color, radius: float) -> GPUParticles3D:
	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	m.emission_ring_axis = Vector3(0, 1, 0)
	m.emission_ring_radius = radius
	m.emission_ring_inner_radius = radius * 0.95
	m.emission_ring_height = 0.02
	m.direction = Vector3(0, 1, 0)
	m.spread = 5.0
	m.initial_velocity_min = 0.05
	m.initial_velocity_max = 0.25
	m.gravity = Vector3.ZERO
	m.orbit_velocity_min = 0.25
	m.orbit_velocity_max = 0.45
	m.scale_curve = RmUtil.curve([Vector2(0, 0.2), Vector2(0.2, 1), Vector2(1, 0)])
	m.color_ramp = fade_ramp(color)
	var p := _particles(48, 1.4, m, sprite_mesh(0.035, 4.0))
	p.visibility_aabb = AABB(Vector3(-1, -0.5, -1), Vector3(2, 2, 2))
	return p


## one-shot explosion of sparks (selection, orders, arrival)
static func burst(color: Color, amount := 64, speed := 2.0, size := 0.05) -> GPUParticles3D:
	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	m.emission_sphere_radius = 0.05
	m.direction = Vector3(0, 1, 0)
	m.spread = 180.0
	m.initial_velocity_min = speed * 0.3
	m.initial_velocity_max = speed
	m.gravity = Vector3(0, -3.0, 0)
	m.damping_min = 1.0
	m.damping_max = 3.0
	m.scale_curve = RmUtil.curve([Vector2(0, 1), Vector2(1, 0)])
	m.color_ramp = fade_ramp(Color.WHITE, color)
	var p := _particles(amount, 0.9, m, sprite_mesh(size, 5.0))
	p.one_shot = true
	p.explosiveness = 0.95
	p.emitting = false
	p.local_coords = false
	p.visibility_aabb = AABB(Vector3(-3, -1, -3), Vector3(6, 4, 6))
	return p


## glowing digits/bits rising in a column (anchors, goals)
static func rising_column(color: Color, radius: float, speed: float, amount := 60) -> GPUParticles3D:
	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	m.emission_ring_axis = Vector3(0, 1, 0)
	m.emission_ring_radius = radius
	m.emission_ring_inner_radius = radius * 0.2
	m.emission_ring_height = 0.05
	m.direction = Vector3(0, 1, 0)
	m.spread = 4.0
	m.initial_velocity_min = speed * 0.6
	m.initial_velocity_max = speed
	m.gravity = Vector3.ZERO
	m.orbit_velocity_min = 0.05
	m.orbit_velocity_max = 0.15
	m.scale_min = 0.6
	m.scale_max = 1.3
	m.color_ramp = fade_ramp(color)
	var p := _particles(amount, 2.5, m, sprite_mesh(0.04, 4.0, true))
	p.visibility_aabb = AABB(Vector3(-2, -1, -2), Vector3(4, 8, 4))
	p.preprocess = 2.5
	return p


## sparks spiralling down onto a target point
static func vortex(color: Color, radius: float) -> GPUParticles3D:
	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	m.emission_ring_axis = Vector3(0, 1, 0)
	m.emission_ring_radius = radius
	m.emission_ring_inner_radius = radius * 0.9
	m.emission_ring_height = 0.6
	m.direction = Vector3(0, -1, 0)
	m.spread = 10.0
	m.initial_velocity_min = 0.1
	m.initial_velocity_max = 0.3
	m.gravity = Vector3.ZERO
	m.radial_accel_min = -0.8
	m.radial_accel_max = -0.4
	m.orbit_velocity_min = 0.4
	m.orbit_velocity_max = 0.7
	m.color_ramp = fade_ramp(color)
	var p := _particles(70, 1.6, m, sprite_mesh(0.035, 4.0))
	p.visibility_aabb = AABB(Vector3(-1.5, -1, -1.5), Vector3(3, 3, 3))
	return p
