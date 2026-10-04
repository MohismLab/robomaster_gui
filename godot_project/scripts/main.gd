extends Node3D
## RoboMaster Tactical Net: RTS-style 3D control of the UWB RoboMaster fleet.
##
## The ROS side is the RosBridge class from the robomaster_gui GDExtension
## (src/ros_bridge.cpp). User args (after "--"):
##   --robots auto|rm_0,rm_1   auto (default): every robot seen in the pose topics, new ones
##                             appear at run time; a list: only these
##   --pose-topic /uwb_ekf/{}/pose   --cmd-topic /{}/cmd_vel
##   --anchors-topic /uwb/anchors   --origin-anchor 0   --axis-anchor 1   --floor-z -1.75
##   --display-anchors-topic ""  (optional other display frame, e.g. /uwb_viz/rm_0/anchors)
##   --spacing 0.5   --demo   --fullscreen
## Display frame: origin at A0, +x along A0 -> A1 (see ros_bridge.h).
##   --drive-kinds rm         robot kinds driven with cmd_vel ("rm,dog", "all"); others view only
##   --frame enu|axis display frame: ENU from the magnetometers (origin A0, x magnetic east,
##                    default, once the UWB<->ENU rotation is known) or A0 -> A1 as +x
##   --nav godot|ros  who drives to the goals: NavController here (cmd_vel, default)
##                    or uwb_goal_nav.py (/uwb_nav/<robot>/goal_pose); N toggles
##   --autoplay  (demo: select and order robots by itself, for a quick look)

const MANUAL_SPEED := 0.3     # [m/s]
const MANUAL_TURN := 1.0      # [rad/s]
const MANUAL_RATE := 15.0     # [Hz]
const NAV_RATE := 20.0        # [Hz]

var cfg := {
	"robots": "auto",
	"pose-topic": "/uwb_ekf/{}/pose",
	"cmd-topic": "/{}/cmd_vel",
	"anchors-topic": "/uwb/anchors",
	"display-anchors-topic": "",
	"origin-anchor": "0",
	"axis-anchor": "1",
	"floor-z": "-1.75",
	"spacing": "0.5",
	"demo": false,
	"fullscreen": false,
	"autoplay": false,
	"nav": "godot",
	"frame": "enu",
	"drive-kinds": "rm",
}

var bridge: Node
var demo := false
var ros_ok := false
var camera: RtsCamera
var hud: Hud
var units: Array[RobotUnit] = []
var unit_by_name := {}
var anchors := {}               # id -> AnchorBeacon
var selection: Array[RobotUnit] = []
var targeting := false
var manual := false
var fx_enabled := true

var _post_mat: ShaderMaterial
var _post_layer: CanvasLayer
var _glitch := 0.0
var _ambient_fx: Array[Node3D] = []
var _range_lines: MeshInstance3D
var _fence: MeshInstance3D
var _fence_key := ""
var _drag_start := Vector2.ZERO
var _left_down := false
var _dragging := false
var _manual_t := 0.0
var _manual_moving := false
var _anchors_fitted := false
var _seen_units := {}
var nav_backend := "godot"
var navs := {}                  # robot -> NavController
var heading := HeadingModel.new()
var _enu_applied = null
var _nav_acc := 0.0
var gizmo: MoveGizmo
var _right_down := false


func _ready() -> void:
	_parse_args()
	_build_environment()
	_build_floor()
	_build_city()
	_build_ambient_fx()
	_range_lines = _line_mesh(Color(1.5, 1.5, 1.5, 1))
	_fence = _line_mesh(Color(1, 1, 1, 1))

	camera = RtsCamera.new()
	add_child(camera)
	hud = Hud.new()
	add_child(hud)
	hud.unit_clicked.connect(_on_unit_clicked)
	hud.unit_double_clicked.connect(func(n):
		_select([unit_by_name[n]])
		_focus_selection())
	hud.command.connect(_on_command)
	hud.map_focus.connect(func(w): camera.focus_on(w))
	hud.map_order.connect(func(w): _order_move(w))
	_build_post_fx()
	gizmo = MoveGizmo.new()
	add_child(gizmo)

	_start_bridge()
	nav_backend = cfg["nav"]
	if demo:
		heading.path = "user://heading_demo.cfg"   # the simulated frame must not touch the real one
	if heading.load_saved():
		hud.log_msg("heading: saved UWB x-axis at %.1f° from magnetic east" % rad_to_deg(-heading.handedness * heading.theta), RmUtil.PURPLE)
	else:
		hud.log_msg("heading: UWB<->ENU unknown, learned from the first motion", RmUtil.YELLOW)
	_ensure_units(bridge.get_robot_states())
	camera.reset_view(Vector3(3.5, 0, -2.75), 5.0)

	hud.log_msg("TACTICAL NET BOOT SEQUENCE ... OK", RmUtil.CYAN)
	hud.log_msg("units: " + ("auto discovery" if cfg["robots"] == "auto" else cfg["robots"]), RmUtil.TEXT)
	if demo:
		hud.log_msg("DEMO MODE: simulated fleet, no ROS", RmUtil.YELLOW)
		hud.toast("DEMO MODE // 演示模式", RmUtil.YELLOW)
	else:
		hud.log_msg("ROS2 node /robomaster_gui online", RmUtil.LIME)
		hud.log_msg("pose  " + cfg["pose-topic"], RmUtil.TEXT_DIM)
		hud.log_msg("goal  /uwb_nav/{}/goal_pose", RmUtil.TEXT_DIM)
		hud.log_msg("beacons " + cfg["anchors-topic"], RmUtil.TEXT_DIM)
		hud.toast("LINK ESTABLISHED // 链路已建立", RmUtil.LIME)
	hud.log_msg("navigation: %s (N to switch)" % _nav_name(), RmUtil.LIME)
	hud.log_msg("press F1 for controls 按 F1 查看操作", RmUtil.MAGENTA)
	if cfg["fullscreen"]:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	if cfg["autoplay"]:
		_autoplay()
	_perf_probe()


## RMGUI_PROFILE=1: print frame timings once per second
func _perf_probe() -> void:
	if OS.get_environment("RMGUI_PROFILE") == "":
		return
	var rid := get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(rid, true)
	while is_inside_tree():
		await get_tree().create_timer(1.0).timeout
		print("PROF fps %d process %.2fms render_cpu %.2fms render_gpu %.2fms draws %d objs %d" % [
				Engine.get_frames_per_second(), Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
				RenderingServer.viewport_get_measured_render_time_cpu(rid),
				RenderingServer.viewport_get_measured_render_time_gpu(rid),
				Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
				Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)])


func _autoplay() -> void:
	var tree := get_tree()
	# a Homeworld-style 3D order for the drone, with the gizmo shown for a moment
	await tree.create_timer(1.0).timeout
	var fly := units.filter(func(u): return u.can_fly())
	if not fly.is_empty():
		_select(units.filter(func(u): return u.can_fly() or u.robot_name.begins_with("dog_")))
		camera.focus_on(fly[0].position, 3.0)
		var p: Vector3 = fly[0].position + Vector3(1.0, 0, 0.6)
		gizmo.begin(p, fly[0].height, true)
		for k in 20:
			await tree.process_frame
			gizmo.add_altitude(0.05)
		await tree.create_timer(1.2).timeout
		var alt: float = gizmo.altitude
		gizmo.end()
		_order_move(p, alt)
		await tree.create_timer(2.0).timeout
	while is_inside_tree():
		await tree.create_timer(1.5).timeout
		_select(units.slice(0, 2))
		await tree.create_timer(0.8).timeout
		_order_move(RmUtil.ros_to_godot(Vector3(randf_range(3.0, 7.0), randf_range(-2.0, 3.0), 0)))
		await tree.create_timer(4.0).timeout
		_select([units[-1]])
		await tree.create_timer(0.5).timeout
		_order_move(RmUtil.ros_to_godot(Vector3(randf_range(3.0, 7.0), randf_range(-2.0, 3.0), 0)))
		await tree.create_timer(4.0).timeout


func _parse_args() -> void:
	var args := OS.get_cmdline_user_args()
	var i := 0
	while i < args.size():
		var a := args[i]
		if a.begins_with("--"):
			var key := a.substr(2)
			if key in ["demo", "fullscreen", "autoplay"]:
				cfg[key] = true
			elif i + 1 < args.size():
				cfg[key] = args[i + 1]
				i += 1
		i += 1


func _start_bridge() -> void:
	demo = cfg["demo"]
	if not demo:
		if ClassDB.class_exists("RosBridge"):
			bridge = ClassDB.instantiate("RosBridge")
			var auto: bool = cfg["robots"] == "auto"
			bridge.set("robots", PackedStringArray() if auto else _robot_list())
			bridge.set("auto_discover", auto)
			bridge.set("pose_topic_format", cfg["pose-topic"])
			bridge.set("cmd_topic_format", cfg["cmd-topic"])
			bridge.set("anchors_topic", cfg["anchors-topic"])
			bridge.set("display_anchors_topic", cfg["display-anchors-topic"])
			bridge.set("origin_anchor", int(cfg["origin-anchor"]))
			bridge.set("axis_anchor", int(cfg["axis-anchor"]))
			bridge.set("floor_z", float(cfg["floor-z"]))
			add_child(bridge)
			ros_ok = bridge.start()
			if not ros_ok:
				bridge.queue_free()
				bridge = null
		if bridge == null:
			push_warning("RosBridge (robomaster_gui GDExtension) unavailable, starting demo mode")
			demo = true
	if demo:
		bridge = DemoBridge.new()
		bridge.robots = PackedStringArray(["rm_0", "rm_1", "rm_2", "dog_0", "fly_0"]) if cfg["robots"] == "auto" else _robot_list()
		add_child(bridge)
		bridge.start()


func _nav_log(m: String) -> void:
	print("[nav] ", m)
	hud.log_msg(m, RmUtil.LIME)


func _nav_name() -> String:
	return "GODOT → cmd_vel" if nav_backend == "godot" else "ROS uwb_goal_nav"


func _robot_list() -> PackedStringArray:
	var out := PackedStringArray()
	for n in cfg["robots"].split(",", false):
		out.append(n.strip_edges())
	return out


## create units + navigation for robots the bridge knows but we do not yet
func _ensure_units(states: Dictionary) -> void:
	var added := PackedStringArray()
	for name in states:
		if unit_by_name.has(name):
			continue
		var u := RobotRegistry.create(name)
		add_child(u)
		u.setup(name, units.size())
		var kinds: PackedStringArray = cfg["drive-kinds"].split(",", false)
		u.drive_allowed = demo or "all" in kinds or RobotRegistry.prefix_of(name) in kinds
		units.append(u)
		unit_by_name[name] = u
		navs[name] = NavController.new(name, bridge, heading, _nav_log)
		added.append(name)
	if added.is_empty():
		return
	units.sort_custom(func(a, b): return a.robot_name.naturalnocasecmp_to(b.robot_name) < 0)
	hud.set_units(units)
	hud.log_msg("robots discovered: " + ", ".join(added), RmUtil.CYAN)


func _exit_tree() -> void:
	for n in navs.values():
		if n.state != NavController.IDLE and bridge:
			bridge.send_cmd_vel(n.robot, 0.0, 0.0, 0.0)
	if bridge and bridge.has_method("stop"):
		for u in units:
			if u.manual:
				bridge.send_cmd_vel(u.robot_name, 0.0, 0.0, 0.0)
		bridge.stop()


# ---------------------------------------------------------------- scene

func _build_environment() -> void:
	var env := Environment.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.01, 0.005, 0.03)
	sky_mat.sky_horizon_color = Color(0.25, 0.04, 0.3)
	sky_mat.ground_bottom_color = Color(0.0, 0.0, 0.01)
	sky_mat.ground_horizon_color = Color(0.2, 0.03, 0.25)
	sky_mat.sun_angle_max = 0.0
	sky_mat.sky_energy_multiplier = 0.8
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.25, 0.2, 0.4)
	env.ambient_light_energy = 0.5
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.0
	env.glow_enabled = true
	env.glow_intensity = 0.55
	env.glow_strength = 0.9
	env.glow_bloom = 0.0
	env.glow_hdr_threshold = 1.1
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SCREEN
	env.set_glow_level(0, 0.0)
	env.set_glow_level(1, 1.0)
	env.set_glow_level(2, 0.8)
	env.set_glow_level(3, 0.6)
	env.set_glow_level(4, 0.4)
	env.set_glow_level(5, 0.3)
	env.ssr_enabled = true
	env.ssr_max_steps = 48
	env.ssr_fade_in = 0.15
	env.ssr_fade_out = 2.0
	env.ssr_depth_tolerance = 0.3
	env.fog_enabled = true
	env.fog_light_color = Color(0.12, 0.03, 0.18)
	env.fog_density = 0.008
	env.fog_sky_affect = 0.5
	env.adjustment_enabled = true
	env.adjustment_contrast = 1.08
	env.adjustment_saturation = 1.25
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var moon := DirectionalLight3D.new()
	moon.light_color = Color(0.55, 0.5, 1.0)
	moon.light_energy = 0.35
	moon.shadow_enabled = true
	moon.directional_shadow_max_distance = 30.0
	moon.rotation = Vector3(deg_to_rad(-55), deg_to_rad(35), 0)
	add_child(moon)
	for d in [[Vector3(-12, 6, 8), RmUtil.MAGENTA], [Vector3(14, 6, -12), RmUtil.CYAN]]:
		var l := OmniLight3D.new()
		l.position = d[0]
		l.light_color = d[1]
		l.light_energy = 0.8
		l.omni_range = 30.0
		add_child(l)


func _build_floor() -> void:
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(240, 240)
	ground.mesh = pm
	ground.material_override = RmUtil.shader_material("res://shaders/grid_floor.gdshader")
	add_child(ground)


## megastructures around the arena
func _build_city() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 2077
	var city := Node3D.new()
	city.name = "City"
	add_child(city)
	var signs := ["墨家", "UWB", "零号", "ロボ", "机甲", "NEON", "电子", "2077", "龍"]
	for k in 90:
		var ang := rng.randf() * TAU
		var dist := rng.randf_range(28.0, 85.0)
		var h := rng.randf_range(5.0, 12.0) + pow(rng.randf(), 3.0) * 40.0
		var w := rng.randf_range(3.0, 8.0)
		var d := rng.randf_range(3.0, 8.0)
		var b := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(w, h, d)
		b.mesh = bm
		var edge: Color = [RmUtil.MAGENTA, RmUtil.CYAN, RmUtil.PURPLE][k % 3]
		b.material_override = RmUtil.shader_material("res://shaders/building.gdshader",
				{"seed": float(k), "top_y": h, "edge_color": edge})
		b.position = Vector3(cos(ang) * dist + 3.5, h / 2.0, sin(ang) * dist - 2.75)
		b.rotation.y = rng.randf_range(-0.3, 0.3)
		b.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		city.add_child(b)
		if k % 6 == 0:
			# holographic sign on the face towards the arena
			var s := Label3D.new()
			s.text = signs[(k / 6) % signs.size()]
			s.font = RmUtil.font(true)
			s.font_size = 256
			s.pixel_size = 0.012
			s.modulate = Color(edge.r * 3.0, edge.g * 3.0, edge.b * 3.0)
			s.outline_size = 0
			s.shaded = false
			s.double_sided = true
			var to_center := Vector3(3.5, 0, -2.75) - b.position
			to_center.y = 0
			s.position = b.position + to_center.normalized() * (maxf(w, d) / 2.0 + 0.3)
			s.position.y = minf(h * 0.7, 16.0)
			city.add_child(s)
			s.look_at(s.position - to_center, Vector3.UP)


func _build_ambient_fx() -> void:
	var center := Vector3(3.5, 0, -2.75)
	var motes := Fx.ambient_motes(Vector3(14, 2.5, 12))
	motes.position = center + Vector3(0, 2.5, 0)
	var rain := Fx.rain(Vector3(18, 0.5, 16))
	rain.position = center + Vector3(0, 14, 0)
	var splash := Fx.splashes(Vector3(16, 0, 14))
	splash.position = center + Vector3(0, 0.02, 0)
	for p in [motes, rain, splash]:
		add_child(p)
		_ambient_fx.append(p)
	# flying traffic lanes above the city
	for lane in [[Vector3(-70, 16, -40), 1.0, RmUtil.MAGENTA], [Vector3(70, 22, 30), -1.0, RmUtil.CYAN],
			[Vector3(-70, 28, 45), 1.0, RmUtil.YELLOW]]:
		var m := ParticleProcessMaterial.new()
		m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
		m.emission_box_extents = Vector3(1, 0.3, 2)
		m.direction = Vector3(lane[1], 0, 0)
		m.spread = 0.0
		m.initial_velocity_min = 8.0
		m.initial_velocity_max = 14.0
		m.gravity = Vector3.ZERO
		m.color = lane[2]
		var p := GPUParticles3D.new()
		p.amount = 40
		p.lifetime = 14.0
		p.preprocess = 14.0
		p.process_material = m
		p.draw_pass_1 = Fx.sprite_mesh(0.25, 2.5)
		p.position = lane[0]
		p.visibility_aabb = AABB(Vector3(-200, -5, -10), Vector3(400, 10, 20))
		add_child(p)
		_ambient_fx.append(p)


func _line_mesh(albedo: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = ImmediateMesh.new()
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.vertex_color_use_as_albedo = true
	m.albedo_color = albedo
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi


func _build_post_fx() -> void:
	_post_layer = CanvasLayer.new()
	_post_layer.layer = 10
	add_child(_post_layer)
	var rect := ColorRect.new()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_post_mat = RmUtil.shader_material("res://shaders/post_fx.gdshader")
	rect.material = _post_mat
	_post_layer.add_child(rect)


func glitch(amount := 0.6) -> void:
	_glitch = maxf(_glitch, amount)


# ---------------------------------------------------------------- per frame

## navigation control loop at a fixed NAV_RATE, independent of the render frame rate
func _physics_process(delta: float) -> void:
	_nav_acc += delta
	if _nav_acc < 1.0 / NAV_RATE:
		return
	var dt := _nav_acc
	_nav_acc = 0.0
	var states: Dictionary = bridge.get_robot_states()
	for name in navs:
		if not states.has(name):
			continue
		var others := []
		for o in navs:
			if o != name and states.has(o) and states[o]["has_pose"]:
				others.append(states[o]["uwb_position"])
		navs[name].tick(states[name], dt, others)
	heading.tick(dt)
	_apply_enu()


## switch the display to ENU once the UWB<->ENU rotation is known (and follow it)
func _apply_enu() -> void:
	if cfg["frame"] != "enu" or heading.theta == null or not bridge.has_method("set_enu_rotation"):
		return
	if _enu_applied == null or absf(angle_difference(_enu_applied, heading.theta)) > deg_to_rad(0.5):
		var first: bool = _enu_applied == null
		_enu_applied = heading.theta
		bridge.set_enu_rotation(heading.theta, heading.handedness)
		if first:
			_anchors_fitted = false   # refit the camera to the rotated arena


func _process(delta: float) -> void:
	var states: Dictionary = bridge.get_robot_states()
	if Engine.get_process_frames() % 30 == 0:
		_ensure_units(states)
	for u in units:
		if states.has(u.robot_name):
			var s: Dictionary = states[u.robot_name]
			var nav: NavController = navs.get(u.robot_name)
			if nav:
				if nav.psi != null:
					# show the estimated heading: map body +x from the UWB to the display frame
					var p: Vector2 = s["uwb_position"]
					var a: Vector2 = bridge.to_display_xy(p)
					var b: Vector2 = bridge.to_display_xy(p + Vector2.from_angle(nav.psi))
					s["yaw"] = (b - a).angle()
				if nav_backend == "godot":
					s["has_goal"] = nav.has_goal()
					if nav.goal != null:
						var g: Vector2 = bridge.to_display_xy(nav.goal)
						s["goal"] = Vector3(g.x, g.y, 0.0)
					s["status"] = (nav.status + " [" + nav.heading_source + "]") if nav.state != NavController.IDLE else ""
			u.apply_state(s)
		if u.has_pose and not _seen_units.has(u.robot_name):
			_seen_units[u.robot_name] = true
			hud.log_msg("%s: pose acquired (%.2f, %.2f)" % [u.robot_name, u.ros_position.x, u.ros_position.y], u.color)
		elif not u.signal_ok() and _seen_units.get(u.robot_name, false) and u.has_pose:
			_seen_units[u.robot_name] = false
			hud.log_msg("%s: SIGNAL LOST" % u.robot_name, RmUtil.ORANGE)
			glitch(0.4)
		elif u.signal_ok() and _seen_units.get(u.robot_name) == false:
			_seen_units[u.robot_name] = true
			hud.log_msg("%s: signal restored" % u.robot_name, RmUtil.LIME)
	# robots that went offline leave the selection
	var online := selection.filter(func(u): return u.is_online())
	if online.size() != selection.size():
		_select(online)
	_update_anchors()
	_update_frame_info()
	_update_hover()
	_update_manual(delta)
	_draw_range_lines()
	_draw_fence()

	var mode := "◢ COMMAND · NAV %s ◣" % ("GODOT" if nav_backend == "godot" else "ROS")
	if manual:
		mode = "◢ MANUAL DRIVE 手动驾驶 · IJKL/UO ◣"
	elif targeting:
		mode = "◢ SELECT TARGET 选择目标点 ◣"
	var manual_info := ""
	if manual:
		manual_info = "MANUAL ▸ I/K 前后  J/L 平移  U/O 旋转  Shift 加速  ·  M 退出" + ("   ▶ DRIVING" if _manual_moving else "")
	hud.targeting = targeting
	var stats: Dictionary = bridge.get_stats()
	hud.update_status(selection, mode, stats, ros_ok, demo, manual_info)
	hud.minimap.view_poly = camera.footprint()
	gizmo.update(selection)

	_glitch = maxf(_glitch - delta * 1.5, 0.0)
	var g := _glitch
	if randf() < 0.002:
		g = maxf(g, 0.3)
	_post_mat.set_shader_parameter("glitch", g)


var _frame_info := ""


func _update_frame_info() -> void:
	if demo or not bridge.has_method("get_frame_info"):
		return
	var info: String = bridge.get_frame_info()
	if info != _frame_info:
		_frame_info = info
		hud.log_msg("frame: " + info, RmUtil.PURPLE)


func _update_anchors() -> void:
	var list: Array = bridge.get_anchors()
	var added := false
	for d in list:
		var id: int = d["id"]
		var a: AnchorBeacon = anchors.get(id)
		if a == null:
			a = AnchorBeacon.new()
			add_child(a)
			a.setup(id)
			anchors[id] = a
			added = true
			var p: Vector3 = d["position"]
			hud.log_msg("beacon A%d online (%.2f, %.2f, %.2f)" % [id, p.x, p.y, p.z], RmUtil.YELLOW)
		a.apply(d)
	if added:
		hud.set_anchors(anchors.values())
	elif not anchors.is_empty() and Engine.get_process_frames() % 30 == 0:
		hud.set_anchors(anchors.values())
	if not _anchors_fitted and anchors.size() >= 3:
		_anchors_fitted = true
		var r := _arena_rect()
		camera.reset_view(r.get_center(), maxf(r.size.x, r.size.y))


## Godot-space bounding box of the anchors, as center x/z + size
func _arena_rect() -> AABB:
	var vals := anchors.values()
	var box := AABB(vals[0].position, Vector3.ZERO)
	for a in vals:
		box = box.expand(a.position)
	return box


func _sorted_anchor_ring() -> Array:
	var vals := anchors.values()
	if vals.size() < 3:
		return []
	var mid := Vector3.ZERO
	for a in vals:
		mid += a.position
	mid /= vals.size()
	vals.sort_custom(func(a, b):
		return atan2(a.position.z - mid.z, a.position.x - mid.x) < atan2(b.position.z - mid.z, b.position.x - mid.x))
	return vals


## holographic fence along the polygon of anchors
func _draw_fence() -> void:
	var ring := _sorted_anchor_ring()
	var im: ImmediateMesh = _fence.mesh
	var key := ""
	for a in ring:
		key += str(a.position)
	if key == _fence_key:
		return
	_fence_key = key
	im.clear_surfaces()
	if ring.is_empty():
		return
	im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	var hgt := 0.35
	for i in ring.size():
		var a: Vector3 = ring[i].position
		var b: Vector3 = ring[(i + 1) % ring.size()].position
		var lo := Color(RmUtil.YELLOW, 0.15)
		var hi := Color(RmUtil.YELLOW, 0.0)
		for v in [[a, lo], [b, lo], [b + Vector3(0, hgt, 0), hi], [a, lo], [b + Vector3(0, hgt, 0), hi], [a + Vector3(0, hgt, 0), hi]]:
			im.surface_set_color(v[1])
			im.surface_add_vertex(v[0] + Vector3(0, 0.005, 0))
		# bright floor strip
		var dir := (b - a).normalized()
		var side := Vector3(-dir.z, 0, dir.x) * 0.015
		var c := Color(RmUtil.YELLOW, 0.45)
		for v in [a + side, a - side, b + side, b + side, a - side, b - side]:
			im.surface_set_color(c)
			im.surface_add_vertex(v + Vector3(0, 0.01, 0))
	im.surface_end()


## anchor -> robot ranging lines with data packets flowing along them
func _draw_range_lines() -> void:
	var im: ImmediateMesh = _range_lines.mesh
	im.clear_surfaces()
	if anchors.is_empty():
		return
	var t := Time.get_ticks_msec() / 1000.0
	var any := false
	for u in units:
		if u.has_pose and u.signal_ok():
			any = true
	if not any:
		return
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for a in anchors.values():
		var pa: Vector3 = a.antenna_position()
		for u in units:
			if not u.has_pose or not u.signal_ok():
				continue
			var pu: Vector3 = u.position + Vector3(0, 0.2, 0)
			var al := 0.22 if u.selected else 0.08
			im.surface_set_color(Color(RmUtil.YELLOW, al))
			im.surface_add_vertex(pa)
			im.surface_set_color(Color(u.color, al))
			im.surface_add_vertex(pu)
			# packet
			var f := fmod(t * 0.7 + a.anchor_id * 0.27 + u.index * 0.41, 1.0)
			var p0 := pa.lerp(pu, f)
			var p1 := pa.lerp(pu, minf(f + 0.05, 1.0))
			im.surface_set_color(Color(1, 1, 1, 0.9 if u.selected else 0.5))
			im.surface_add_vertex(p0)
			im.surface_set_color(Color(u.color, 0.9))
			im.surface_add_vertex(p1)
	im.surface_end()


# ---------------------------------------------------------------- selection

func _unit_screen_radius(u: RobotUnit) -> float:
	var cam := camera.camera
	var d := cam.global_position.distance_to(u.global_position)
	var h := get_viewport().get_visible_rect().size.y
	return maxf(0.3 * h / (2.0 * tan(deg_to_rad(cam.fov) / 2.0) * maxf(d, 0.01)), 22.0)


func _pick_unit(screen: Vector2) -> RobotUnit:
	var cam := camera.camera
	var best: RobotUnit = null
	var best_d := INF
	for u in units:
		if not u.is_online():
			continue
		var wp := u.global_position + Vector3(0, 0.08, 0)
		if cam.is_position_behind(wp):
			continue
		var d := cam.unproject_position(wp).distance_to(screen)
		if d < _unit_screen_radius(u) and d < best_d:
			best = u
			best_d = d
	return best


func _update_hover() -> void:
	var m := get_viewport().get_mouse_position()
	var h: RobotUnit = null if hud.is_over_ui() else _pick_unit(m)
	for u in units:
		u.hovered = u == h


func _select(list: Array, additive := false) -> void:
	var new_sel: Array[RobotUnit] = []
	if additive:
		new_sel = selection.duplicate()
		for u in list:
			if u in new_sel:
				new_sel.erase(u)
			else:
				new_sel.append(u)
	else:
		for u in list:
			new_sel.append(u)
	if new_sel == selection:
		return
	selection = new_sel
	var names := PackedStringArray()
	for u in units:
		var s := u in selection
		if s and manual and not u.selected:
			bridge.cancel_goal(u.robot_name)
		if not s and u.manual:
			bridge.send_cmd_vel(u.robot_name, 0.0, 0.0, 0.0)
		u.set_selected(s)
		u.manual = manual and s
		if s:
			names.append(u.robot_name)
	bridge.publish_selection(names)
	if not selection.is_empty():
		hud.log_msg("selected: " + ", ".join(names), RmUtil.CYAN)


func _on_unit_clicked(n: String, additive: bool) -> void:
	_select([unit_by_name[n]], additive)


func _focus_selection() -> void:
	var list := selection if not selection.is_empty() else units
	var c := Vector3.ZERO
	var n := 0
	for u in list:
		if u.has_pose:
			c += u.position
			n += 1
	if n > 0:
		camera.focus_on(c / n, 2.5 if n == 1 else 4.0)


# ---------------------------------------------------------------- orders

## altitude < 0: flying robots keep their height
func _order_move(target: Vector3, altitude := -1.0) -> void:
	var robots := selection.filter(func(u): return u.is_online() and (u.can_drive() or u.can_fly()))
	if robots.size() < selection.size():
		var skipped := PackedStringArray()
		for u in selection:
			if not u in robots:
				skipped.append(u.robot_name)
		hud.log_msg("not driven (offline / no floor navigation): " + ", ".join(skipped), RmUtil.ORANGE)
	if robots.is_empty():
		hud.toast("NO UNIT SELECTED // 未选择单位", RmUtil.ORANGE)
		glitch(0.3)
		return
	if manual:
		_set_manual(false)
	var goal := RmUtil.godot_to_ros(target)
	var n := robots.size()
	var spacing := float(cfg["spacing"])
	# same formation as uwb_fleet.py: a circle around the click, keeping the robots'
	# angular order so their paths do not cross
	var radius := 0.0 if n == 1 else spacing / (2.0 * sin(PI / n))
	var angle_of := func(u): return atan2(u.ros_position.y - goal.y, u.ros_position.x - goal.x)
	robots.sort_custom(func(a, b): return angle_of.call(a) < angle_of.call(b))
	var start: float = angle_of.call(robots[0])
	for k in n:
		var u: RobotUnit = robots[k]
		var a := start + TAU * k / n
		var gx := goal.x + radius * cos(a)
		var gy := goal.y + radius * sin(a)
		if u.can_fly():
			var h := altitude if altitude >= 0.0 else u.height
			bridge.send_goal_3d(u.robot_name, gx, gy, h)
		else:
			_send_goal(u, Vector2(gx, gy))
		u.show_order(RmUtil.ros_to_godot(Vector3(gx, gy, 0)))
	_spawn_click_fx(Vector3(target.x, 0, target.z))
	var names := PackedStringArray()
	for u in robots:
		names.append(u.robot_name)
	var alt_txt := "  H %.2fm" % altitude if altitude >= 0.0 and robots.any(func(u): return u.can_fly()) else ""
	hud.log_msg("MOVE (%.2f, %.2f)%s → %s" % [goal.x, goal.y, alt_txt, ", ".join(names)], RmUtil.LIME)
	hud.toast("ORDER ▸ MOVE  (%.2f, %.2f)" % [goal.x, goal.y], RmUtil.CYAN)
	glitch(0.25)
	camera.shake(0.03)


## g in the display frame
func _send_goal(u: RobotUnit, g: Vector2) -> void:
	if nav_backend == "godot":
		navs[u.robot_name].order(bridge.to_uwb_xy(g))
	else:
		bridge.send_goal(u.robot_name, g.x, g.y, 0.0)


func _order_stop() -> void:
	if selection.is_empty():
		return
	for u in selection:
		navs[u.robot_name].stop("STOPPED")
		bridge.cancel_goal(u.robot_name)
		bridge.send_cmd_vel(u.robot_name, 0.0, 0.0, 0.0)
		u.clear_order()
	hud.log_msg("STOP → %d unit(s)" % selection.size(), RmUtil.MAGENTA)
	hud.toast("■ STOP 全部停止", RmUtil.MAGENTA)
	glitch(0.5)


func _spawn_click_fx(p: Vector3) -> void:
	var root := Node3D.new()
	add_child(root)
	root.position = p
	for k in 2:
		var ring := MeshInstance3D.new()
		var pm := PlaneMesh.new()
		pm.size = Vector2(1.6 + k * 1.2, 1.6 + k * 1.2)
		ring.mesh = pm
		var mat := RmUtil.shader_material("res://shaders/pulse_ring.gdshader",
				{"color": RmUtil.CYAN if k == 0 else RmUtil.MAGENTA, "progress": 0.0, "intensity": 2.0, "width": 0.06, "hex": float(k)})
		ring.material_override = mat
		ring.position.y = 0.015
		root.add_child(ring)
		var tw := create_tween()
		tw.tween_method(func(v): mat.set_shader_parameter("progress", v), 0.0, 1.0, 0.7 + k * 0.3)
	var b := Fx.burst(RmUtil.CYAN, 90, 3.0, 0.05)
	root.add_child(b)
	b.emitting = true
	var b2 := Fx.rising_column(RmUtil.MAGENTA, 0.15, 1.5, 30)
	b2.one_shot = true
	b2.preprocess = 0.0
	root.add_child(b2)
	get_tree().create_timer(2.6).timeout.connect(root.queue_free)


# ---------------------------------------------------------------- manual drive

func _set_manual(v: bool) -> void:
	if v and selection.is_empty():
		hud.toast("SELECT A UNIT FIRST // 请先选择单位", RmUtil.ORANGE)
		return
	manual = v
	targeting = false
	for u in units:
		var m := v and u.selected
		if m and not u.manual:
			navs[u.robot_name].stop()
			bridge.cancel_goal(u.robot_name)
			u.clear_order()
		if u.manual and not m:
			bridge.send_cmd_vel(u.robot_name, 0.0, 0.0, 0.0)
		u.manual = m
	hud.log_msg("manual drive " + ("ON" if v else "OFF"), RmUtil.YELLOW)
	hud.toast("◈ MANUAL DRIVE ENGAGED 手动驾驶" if v else "MANUAL DRIVE OFF", RmUtil.YELLOW)
	glitch(0.3)


func _update_manual(delta: float) -> void:
	if not manual:
		return
	var vx := 0.0
	var vy := 0.0
	var wz := 0.0
	if Input.is_key_pressed(KEY_I):
		vx += 1
	if Input.is_key_pressed(KEY_K):
		vx -= 1
	if Input.is_key_pressed(KEY_J):
		vy += 1
	if Input.is_key_pressed(KEY_L):
		vy -= 1
	if Input.is_key_pressed(KEY_U):
		wz += 1
	if Input.is_key_pressed(KEY_O):
		wz -= 1
	var boost := 2.0 if Input.is_key_pressed(KEY_SHIFT) else 1.0
	var moving := vx != 0 or vy != 0 or wz != 0
	_manual_t -= delta
	if moving and _manual_t <= 0.0:
		_manual_t = 1.0 / MANUAL_RATE
		var v := Vector2(vx, vy).normalized() * MANUAL_SPEED * boost
		for u in selection:
			if not u.can_drive():
				continue
			bridge.send_cmd_vel(u.robot_name, v.x, v.y, wz * MANUAL_TURN * boost)
			navs[u.robot_name].note_body_cmd(v.x, v.y, wz * MANUAL_TURN * boost)
	elif not moving and _manual_moving:
		for u in selection:
			bridge.send_cmd_vel(u.robot_name, 0.0, 0.0, 0.0)
			navs[u.robot_name].note_body_cmd(0.0, 0.0, 0.0)
	_manual_moving = moving


# ---------------------------------------------------------------- input

func _on_command(cmd: String) -> void:
	match cmd:
		"move":
			if not selection.is_empty():
				targeting = true
		"stop":
			_order_stop()
		"manual":
			_set_manual(not manual)
		"focus":
			_focus_selection()
		"all":
			_select(units)
		"help":
			hud.toggle_help()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				if targeting:
					var p = camera.ground_point(mb.position)
					targeting = false
					if p != null:
						_order_move(p)
					return
				if mb.double_click:
					var u := _pick_unit(mb.position)
					if u:
						_select([u])
						_focus_selection()
					return
				_left_down = true
				_dragging = false
				_drag_start = mb.position
			elif _left_down:
				_left_down = false
				var additive := mb.shift_pressed or mb.ctrl_pressed
				if _dragging:
					_dragging = false
					hud.box_active = false
					var r := Rect2(_drag_start, mb.position - _drag_start).abs()
					var picked: Array = []
					for u in units:
						if u.is_online() and not camera.camera.is_position_behind(u.global_position) \
								and r.has_point(camera.camera.unproject_position(u.global_position)):
							picked.append(u)
					if additive:
						for u in selection:
							if not u in picked:
								picked.append(u)
					_select(picked)
				else:
					var u := _pick_unit(mb.position)
					if u:
						_select([u], additive)
					elif not additive:
						_select([])
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			if targeting:
				targeting = false
				return
			# Homeworld-style: hold to place, Shift + drag up/down for the altitude, release
			var p = camera.ground_point(mb.position)
			if p != null and not selection.is_empty():
				var flyers := selection.filter(func(u): return u.is_online() and u.can_fly())
				var alt := 0.0
				for u in flyers:
					alt += u.height / flyers.size()
				gizmo.begin(p, alt, not flyers.is_empty())
				_right_down = true
		elif mb.button_index == MOUSE_BUTTON_RIGHT and not mb.pressed and _right_down:
			_right_down = false
			if gizmo.active:
				var t := gizmo.ground
				var alt := gizmo.altitude if gizmo.use_altitude else -1.0
				gizmo.end()
				_order_move(t, alt)
	elif event is InputEventMouseMotion and _right_down and gizmo.active:
		var mm := event as InputEventMouseMotion
		if mm.shift_pressed and gizmo.use_altitude:
			gizmo.add_altitude(-mm.relative.y * camera.distance * 0.0015)
		else:
			var p = camera.ground_point(mm.position)
			if p != null:
				gizmo.set_ground(p)
	elif event is InputEventMouseMotion and _left_down:
		var mm := event as InputEventMouseMotion
		if not _dragging and mm.position.distance_to(_drag_start) > 6.0:
			_dragging = true
		if _dragging:
			hud.box_active = true
			hud.box_rect = Rect2(_drag_start, mm.position - _drag_start)
	elif event is InputEventKey and event.pressed and not event.echo:
		_on_key(event as InputEventKey)


func _on_key(k: InputEventKey) -> void:
	var code := k.keycode
	if k.ctrl_pressed and code == KEY_A:
		_select(units)
		return
	if code >= KEY_1 and code <= KEY_9:
		# numbered like the cards: online robots in name order
		var i := code - KEY_1
		var online := units.filter(func(u): return u.is_online())
		if i < online.size():
			_select([online[i]], k.shift_pressed)
			if k.ctrl_pressed:
				_focus_selection()
		return
	match code:
		KEY_ESCAPE:
			if gizmo.active:
				gizmo.end()
				_right_down = false
			elif hud._help.visible:
				hud.toggle_help()
			elif targeting:
				targeting = false
			elif manual:
				_set_manual(false)
			else:
				_select([])
		KEY_SPACE, KEY_X:
			_order_stop()
		KEY_M:
			_set_manual(not manual)
		KEY_N:
			for n in navs.values():
				n.stop()
			for u in units:
				bridge.cancel_goal(u.robot_name)
			nav_backend = "ros" if nav_backend == "godot" else "godot"
			hud.log_msg("navigation: " + _nav_name(), RmUtil.LIME)
			hud.toast("NAV ▸ " + _nav_name(), RmUtil.LIME)
			glitch(0.3)
		KEY_C:
			# forget the heading of the selection, next order recalibrates
			for u in selection:
				navs[u.robot_name].reset_heading()
			hud.log_msg("heading reset: %d unit(s)" % selection.size(), RmUtil.YELLOW)
		KEY_F:
			_focus_selection()
		KEY_R:
			if anchors.size() >= 3:
				var r := _arena_rect()
				camera.reset_view(r.get_center(), maxf(r.size.x, r.size.y))
			else:
				camera.reset_view(Vector3(3.5, 0, -2.75), 5.0)
		KEY_H:
			hud.set_hud_visible(not hud._root.visible)
		KEY_P:
			fx_enabled = not fx_enabled
			for p in _ambient_fx:
				p.visible = fx_enabled
			_post_layer.visible = fx_enabled
			hud.log_msg("FX " + ("ON" if fx_enabled else "OFF"), RmUtil.TEXT_DIM)
		KEY_F1:
			hud.toggle_help()
		KEY_F2, KEY_F3, KEY_F4, KEY_F5, KEY_F6:
			hud.toggle_panel(code - KEY_F2)
		KEY_TAB:
			hud.toggle_side_panels()
		KEY_F11:
			var full := DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED if full else DisplayServer.WINDOW_MODE_FULLSCREEN)
