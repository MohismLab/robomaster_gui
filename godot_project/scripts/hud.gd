class_name Hud
extends CanvasLayer
## Cyberpunk HUD: top status bar, unit roster, beacon list, system log,
## command deck, tactical map, toasts, help and the box-selection overlay.

signal unit_clicked(robot: String, additive: bool)
signal unit_double_clicked(robot: String)
signal command(cmd: String)
signal map_focus(world: Vector3)
signal map_order(world: Vector3)

var box_active := false
var box_rect := Rect2()
var targeting := false
var hovered_unit := ""

var _root: Control
var _overlay: Control
var _title: Label
var _mode_label: Label
var _status_label: Label
var _clock_label: Label
var _unit_list: VBoxContainer
var _cards := {}
var _anchor_list: VBoxContainer
var _anchor_rows := {}
var _log: RichTextLabel
var _sel_label: Label
var _sel_detail: Label
var _manual_label: Label
var _buttons := {}
var _toast: Label
var _toast_t := 0.0
var _help: Control
var minimap: TacticalMap
var _panels: Array = []          # F2..F6: units, beacons, log, map, command
var _glitch_t := 0.0
var _title_text := "ROBOMASTER // TACTICAL·NET"


# ---------------------------------------------------------------- widgets

## chamfered neon panel with a header tab
class CyberPanel extends Control:
	var title := ""
	var subtitle := ""
	var accent := RmUtil.CYAN
	var chamfer := 14.0
	var collapsible := true
	var collapsed := false
	var _scan := 0.0
	var _saved := []

	const HEADER := 24.0

	func _init(title_ := "", accent_ := RmUtil.CYAN) -> void:
		title = title_
		accent = accent_
		mouse_filter = Control.MOUSE_FILTER_STOP

	func _gui_input(event: InputEvent) -> void:
		var mb := event as InputEventMouseButton
		if collapsible and mb and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and mb.position.y < HEADER:
			set_collapsed(not collapsed)
			accept_event()

	## fold the panel to its header (keeps the edge it is anchored to)
	func set_collapsed(v: bool) -> void:
		if v == collapsed or not collapsible:
			return
		collapsed = v
		if v:
			_saved = [anchor_top, anchor_bottom, offset_top, offset_bottom]
			if anchor_top >= 1.0:
				offset_top = offset_bottom - HEADER
			else:
				anchor_bottom = anchor_top
				offset_bottom = offset_top + HEADER
		else:
			anchor_top = _saved[0]
			anchor_bottom = _saved[1]
			offset_top = _saved[2]
			offset_bottom = _saved[3]
		for c in get_children():
			if c is CanvasItem:
				c.visible = not v

	var _redraw_t := 0.0

	func _process(delta: float) -> void:
		_scan = fmod(_scan + delta * 0.35, 1.0)
		_redraw_t -= delta
		if _redraw_t <= 0.0 and is_visible_in_tree():
			_redraw_t = 1.0 / 30.0
			queue_redraw()

	func _draw() -> void:
		var w := size.x
		var h := size.y
		var c := chamfer
		var pts := PackedVector2Array([Vector2(c, 0), Vector2(w, 0), Vector2(w, h - c), Vector2(w - c, h), Vector2(0, h), Vector2(0, c)])
		draw_colored_polygon(pts, RmUtil.PANEL_BG)
		# faint inner grid
		var lines := PackedVector2Array()
		var y := 0.0
		while y < h:
			lines.append(Vector2(2, y))
			lines.append(Vector2(w - 2, y))
			y += 4.0
		draw_multiline(lines, Color(accent, 0.025))
		# scan line
		var sy := _scan * h
		draw_rect(Rect2(1, sy, w - 2, 2), Color(accent, 0.07))
		# glowing border
		var loop := pts.duplicate()
		loop.append(pts[0])
		draw_polyline(loop, Color(accent, 0.18), 5.0)
		draw_polyline(loop, Color(accent, 0.85), 1.2)
		# corner accents
		draw_line(Vector2(0, c), Vector2(c, 0), accent.lightened(0.4), 3.0)
		draw_line(Vector2(w, h - c), Vector2(w - c, h), RmUtil.MAGENTA, 3.0)
		draw_rect(Rect2(w - 34, 4, 26, 3), Color(RmUtil.MAGENTA, 0.9))
		for k in 6:
			draw_rect(Rect2(w - 80 + k * 6, 4, 3 if k % 2 == 0 else 1, 7), Color(accent, 0.6))
		if collapsed:
			return
		if collapsible:
			draw_string(RmUtil.font(true), Vector2(w - 104, 17), "▸" if collapsed else "▾",
					HORIZONTAL_ALIGNMENT_RIGHT, 20, 16, Color(accent, 0.9))
		if title != "":
			var font := RmUtil.font(true)
			var tw := font.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, 15).x
			var tab := PackedVector2Array([Vector2(c + 4, 0), Vector2(c + tw + 26, 0), Vector2(c + tw + 16, 20), Vector2(c - 6, 20)])
			draw_colored_polygon(tab, Color(accent, 0.9))
			draw_string(font, Vector2(c + 8, 15), title, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(0.02, 0.02, 0.05))
			if subtitle != "":
				draw_string(RmUtil.font(), Vector2(c + tw + 32, 14), subtitle, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(accent, 0.7))


## one robot in the roster
class UnitCard extends Control:
	signal clicked(additive: bool)
	signal double_clicked

	var robot := ""
	var color := RmUtil.CYAN
	var hotkey := 1
	var unit = null
	var compact := false
	var _hover := false

	func _init(robot_: String, color_: Color, hotkey_: int) -> void:
		robot = robot_
		color = color_
		hotkey = hotkey_
		custom_minimum_size = Vector2(0, 84)
		mouse_filter = Control.MOUSE_FILTER_STOP
		mouse_entered.connect(func(): _hover = true)
		mouse_exited.connect(func(): _hover = false)

	func _gui_input(event: InputEvent) -> void:
		var mb := event as InputEventMouseButton
		if mb and mb.pressed and mb.button_index == MOUSE_BUTTON_RIGHT:
			compact = not compact
			custom_minimum_size.y = 34 if compact else 84
			accept_event()
		elif mb and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.double_click:
				double_clicked.emit()
			else:
				clicked.emit(mb.shift_pressed or mb.ctrl_pressed)
			accept_event()

	var _redraw_t := 0.0

	func _process(delta: float) -> void:
		_redraw_t -= delta
		if _redraw_t <= 0.0 and is_visible_in_tree():
			_redraw_t = 1.0 / 15.0
			queue_redraw()

	func _draw() -> void:
		var w := size.x
		var h := size.y
		var sel: bool = unit != null and unit.selected
		var ok: bool = unit != null and unit.signal_ok()
		var t := Time.get_ticks_msec() / 1000.0
		var bg := Color(color, 0.16) if sel else (Color(color, 0.08) if _hover else Color(1, 1, 1, 0.02))
		var pts := PackedVector2Array([Vector2(0, 0), Vector2(w - 10, 0), Vector2(w, 10), Vector2(w, h), Vector2(10, h), Vector2(0, h - 10)])
		draw_colored_polygon(pts, bg)
		var loop := pts.duplicate()
		loop.append(pts[0])
		draw_polyline(loop, Color(color, 0.9 if sel else 0.3), 1.5 if sel else 1.0)
		draw_rect(Rect2(0, 0, 4, h - 10), color if ok else RmUtil.ORANGE)
		var fb := RmUtil.font(true)
		var f := RmUtil.font()
		draw_string(fb, Vector2(14, 22), "[%d] %s" % [hotkey, robot.to_upper()], HORIZONTAL_ALIGNMENT_LEFT, -1, 17, color.lightened(0.2))
		var state := "NO DATA 无信号"
		var state_col := RmUtil.TEXT_DIM
		if unit != null and unit.has_pose:
			if not ok:
				state = "SIGNAL LOST %.1fs" % unit.age
				state_col = RmUtil.ORANGE
			elif unit.calibrating:
				state = "CALIBRATING 地磁校准中"
				state_col = RmUtil.YELLOW
			elif unit.manual:
				state = "MANUAL 手动"
				state_col = RmUtil.YELLOW
			elif unit.status != "":
				state = unit.status.to_upper()
				state_col = RmUtil.LIME
			elif unit.has_goal:
				state = "ORDER SENT"
				state_col = RmUtil.LIME
			elif not unit.can_drive():
				state = "VIEW ONLY 仅显示"
				state_col = RmUtil.TEXT_DIM
			else:
				state = "IDLE 待命"
				state_col = RmUtil.TEXT
		draw_string(f, Vector2(w - 12, 22), state, HORIZONTAL_ALIGNMENT_RIGHT, w - 140, 14, state_col)
		if unit != null and unit.has_pose and not compact:
			var p: Vector3 = unit.ros_position
			draw_string(f, Vector2(14, 48), "POS  x %+6.2f  y %+6.2f" % [p.x, p.y], HORIZONTAL_ALIGNMENT_LEFT, -1, 14, RmUtil.TEXT)
			draw_string(f, Vector2(14, 70), "YAW %+6.1f°  V %.2f m/s" % [rad_to_deg(unit.yaw), unit.speed], HORIZONTAL_ALIGNMENT_LEFT, -1, 14, RmUtil.TEXT_DIM)
		# link quality bars from the message age
		var q := 0
		if unit != null and unit.has_pose:
			q = 5 if unit.age < 0.2 else (4 if unit.age < 0.4 else (3 if unit.age < 0.8 else (2 if unit.age < 1.5 else 1)))
		if compact:
			return
		for k in 5:
			var bh := 4.0 + k * 3.0
			var on := k < q
			var bc := (color if q >= 3 else RmUtil.ORANGE) if on else Color(1, 1, 1, 0.1)
			if on and q < 3 and fmod(t, 0.5) < 0.25:
				bc = Color(bc, 0.4)
			draw_rect(Rect2(w - 46 + k * 7, h - 12 - bh, 5, bh), bc)


func _ready() -> void:
	layer = 5
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)
	_build_top_bar()
	_build_left()
	_build_right()
	_build_bottom()
	_build_overlay()
	_build_help()
	_build_ambient()


func _theme_button(b: Button, accent: Color) -> void:
	for state in ["normal", "hover", "pressed", "focus", "disabled"]:
		var sb := StyleBoxFlat.new()
		sb.corner_detail = 1
		sb.corner_radius_top_left = 10
		sb.corner_radius_bottom_right = 10
		sb.border_width_left = 1
		sb.border_width_right = 1
		sb.border_width_top = 1
		sb.border_width_bottom = 2
		sb.content_margin_left = 10
		sb.content_margin_right = 10
		sb.content_margin_top = 6
		sb.content_margin_bottom = 6
		match state:
			"normal":
				sb.bg_color = Color(accent, 0.08)
				sb.border_color = Color(accent, 0.7)
			"hover":
				sb.bg_color = Color(accent, 0.28)
				sb.border_color = accent.lightened(0.3)
				sb.shadow_color = Color(accent, 0.5)
				sb.shadow_size = 8
			"pressed":
				sb.bg_color = Color(RmUtil.MAGENTA, 0.45)
				sb.border_color = RmUtil.MAGENTA
			"focus":
				sb.draw_center = false
				sb.border_color = Color(accent, 0.0)
			"disabled":
				sb.bg_color = Color(1, 1, 1, 0.03)
				sb.border_color = Color(1, 1, 1, 0.15)
		b.add_theme_stylebox_override(state, sb)
	b.add_theme_font_override("font", RmUtil.font(true))
	b.add_theme_font_size_override("font_size", 15)
	b.add_theme_color_override("font_color", accent.lightened(0.3))
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	b.add_theme_color_override("font_pressed_color", Color.WHITE)
	b.add_theme_color_override("font_disabled_color", Color(1, 1, 1, 0.3))


func _build_top_bar() -> void:
	var bar := CyberPanel.new("", RmUtil.CYAN)
	bar.chamfer = 18.0
	_root.add_child(bar)
	bar.anchor_right = 1.0
	bar.offset_left = 10
	bar.offset_right = -10
	bar.offset_top = 8
	bar.offset_bottom = 62
	_title = RmUtil.make_label(_title_text, 24, RmUtil.CYAN, true)
	_title.position = Vector2(28, 4)
	_title.add_theme_color_override("font_shadow_color", Color(RmUtil.MAGENTA, 0.8))
	_title.add_theme_constant_override("shadow_offset_x", 2)
	_title.add_theme_constant_override("shadow_offset_y", 0)
	bar.add_child(_title)
	var sub := RmUtil.make_label("墨家·UWB 战术指挥终端  //  MOHIST FLEET COMMAND  v0.1", 13, Color(RmUtil.MAGENTA, 0.9))
	sub.position = Vector2(30, 34)
	bar.add_child(sub)

	_mode_label = RmUtil.make_label("", 16, RmUtil.YELLOW, true)
	_mode_label.anchor_left = 0.5
	_mode_label.anchor_right = 0.5
	_mode_label.offset_left = -220
	_mode_label.offset_right = 220
	_mode_label.offset_top = 15
	_mode_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bar.add_child(_mode_label)

	_status_label = RmUtil.make_label("", 14, RmUtil.TEXT)
	_status_label.anchor_left = 1.0
	_status_label.anchor_right = 1.0
	_status_label.offset_left = -620
	_status_label.offset_right = -150
	_status_label.offset_top = 19
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	bar.add_child(_status_label)
	_clock_label = RmUtil.make_label("", 22, RmUtil.CYAN, true)
	_clock_label.anchor_left = 1.0
	_clock_label.anchor_right = 1.0
	_clock_label.offset_left = -140
	_clock_label.offset_right = -22
	_clock_label.offset_top = 12
	_clock_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	bar.add_child(_clock_label)


func _build_left() -> void:
	var p := CyberPanel.new("UNITS 单位", RmUtil.CYAN)
	p.subtitle = "RMB: compact"
	_root.add_child(p)
	p.offset_left = 10
	p.offset_top = 72
	p.offset_right = 330
	p.anchor_bottom = 1.0
	p.offset_bottom = -200
	var m := MarginContainer.new()
	m.set_anchors_preset(Control.PRESET_FULL_RECT)
	m.add_theme_constant_override("margin_left", 12)
	m.add_theme_constant_override("margin_right", 12)
	m.add_theme_constant_override("margin_top", 28)
	m.add_theme_constant_override("margin_bottom", 12)
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(m)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	m.add_child(scroll)
	_panels.append(p)
	_unit_list = VBoxContainer.new()
	_unit_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_unit_list.add_theme_constant_override("separation", 8)
	scroll.add_child(_unit_list)


func _build_right() -> void:
	var p := CyberPanel.new("BEACONS 基站", RmUtil.YELLOW)
	p.subtitle = "UWB anchors"
	_root.add_child(p)
	p.anchor_left = 1.0
	p.anchor_right = 1.0
	p.offset_left = -330
	p.offset_right = -10
	p.offset_top = 72
	p.offset_bottom = 300
	var m := MarginContainer.new()
	m.set_anchors_preset(Control.PRESET_FULL_RECT)
	m.add_theme_constant_override("margin_left", 14)
	m.add_theme_constant_override("margin_right", 14)
	m.add_theme_constant_override("margin_top", 28)
	m.add_theme_constant_override("margin_bottom", 10)
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(m)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	m.add_child(scroll)
	_panels.append(p)
	_anchor_list = VBoxContainer.new()
	_anchor_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_anchor_list)
	var none := RmUtil.make_label("waiting for /uwb/anchors ...", 14, RmUtil.TEXT_DIM)
	none.name = "None"
	_anchor_list.add_child(none)

	var lp := CyberPanel.new("SYS.LOG 日志", RmUtil.MAGENTA)
	_root.add_child(lp)
	lp.anchor_left = 1.0
	lp.anchor_right = 1.0
	lp.anchor_bottom = 1.0
	lp.offset_left = -330
	lp.offset_right = -10
	lp.offset_top = 310
	lp.offset_bottom = -340
	var lm := MarginContainer.new()
	lm.set_anchors_preset(Control.PRESET_FULL_RECT)
	lm.add_theme_constant_override("margin_left", 12)
	lm.add_theme_constant_override("margin_right", 10)
	lm.add_theme_constant_override("margin_top", 28)
	lm.add_theme_constant_override("margin_bottom", 10)
	lm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lp.add_child(lm)
	_panels.append(lp)
	_log = RichTextLabel.new()
	_log.bbcode_enabled = true
	_log.scroll_following = true
	_log.add_theme_font_override("normal_font", RmUtil.font())
	_log.add_theme_font_override("bold_font", RmUtil.font(true))
	_log.add_theme_font_size_override("normal_font_size", 13)
	_log.add_theme_font_size_override("bold_font_size", 13)
	_log.add_theme_color_override("default_color", RmUtil.TEXT_DIM)
	lm.add_child(_log)

	var mp := CyberPanel.new("TAC.MAP 战术地图", RmUtil.CYAN)
	_root.add_child(mp)
	mp.anchor_left = 1.0
	mp.anchor_right = 1.0
	mp.anchor_top = 1.0
	mp.anchor_bottom = 1.0
	mp.offset_left = -330
	mp.offset_right = -10
	mp.offset_top = -330
	mp.offset_bottom = -10
	_panels.append(mp)
	minimap = TacticalMap.new()
	minimap.position = Vector2(8, 24)
	minimap.size = Vector2(304, 288)
	mp.add_child(minimap)
	minimap.focus_requested.connect(func(w): map_focus.emit(w))
	minimap.order_requested.connect(func(w): map_order.emit(w))


func _build_bottom() -> void:
	var p := CyberPanel.new("COMMAND 指令", RmUtil.MAGENTA)
	_root.add_child(p)
	p.anchor_top = 1.0
	p.anchor_bottom = 1.0
	p.anchor_right = 1.0
	p.offset_left = 10
	p.offset_right = -340
	p.offset_top = -190
	p.offset_bottom = -10
	_panels.append(p)
	_sel_label = RmUtil.make_label("NO UNIT SELECTED", 20, RmUtil.TEXT, true)
	_sel_label.position = Vector2(22, 30)
	p.add_child(_sel_label)
	_sel_detail = RmUtil.make_label("", 14, RmUtil.TEXT_DIM)
	_sel_detail.position = Vector2(22, 58)
	p.add_child(_sel_detail)
	_manual_label = RmUtil.make_label("", 14, RmUtil.YELLOW)
	_manual_label.position = Vector2(22, 78)
	p.add_child(_manual_label)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.position = Vector2(20, 110)
	p.add_child(row)
	var defs := [
		["move", "⌖ MOVE 移动 [RMB]", RmUtil.CYAN],
		["stop", "■ STOP 停止 [SPACE]", RmUtil.MAGENTA],
		["manual", "◈ MANUAL 手动 [M]", RmUtil.YELLOW],
		["focus", "◎ FOCUS 聚焦 [F]", RmUtil.LIME],
		["all", "▣ ALL 全选 [^A]", RmUtil.PURPLE],
		["labels", "◇ LABELS 标签 [L]", RmUtil.CYAN],
		["help", "? HELP [F1]", RmUtil.TEXT_DIM],
	]
	for d in defs:
		var b := Button.new()
		b.text = d[1]
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(0, 44)
		_theme_button(b, d[2])
		var cmd: String = d[0]
		b.toggle_mode = cmd == "labels"
		b.pressed.connect(func(): command.emit(cmd))
		row.add_child(b)
		_buttons[cmd] = b


func _build_overlay() -> void:
	_overlay = Control.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_overlay)
	_overlay.draw.connect(_draw_overlay)
	_toast = RmUtil.make_label("", 30, RmUtil.CYAN, true)
	_toast.anchor_left = 0.5
	_toast.anchor_right = 0.5
	_toast.offset_left = -500
	_toast.offset_right = 500
	_toast.offset_top = 90
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.add_theme_color_override("font_shadow_color", Color(RmUtil.MAGENTA, 0.9))
	_toast.add_theme_constant_override("shadow_offset_x", 3)
	_toast.add_theme_constant_override("shadow_offset_y", 0)
	_toast.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	_toast.add_theme_constant_override("outline_size", 6)
	_root.add_child(_toast)


func _build_help() -> void:
	_help = CyberPanel.new("HELP 操作说明", RmUtil.LIME)
	_help.collapsible = false
	_root.add_child(_help)
	_help.anchor_left = 0.5
	_help.anchor_right = 0.5
	_help.anchor_top = 0.5
	_help.anchor_bottom = 0.5
	_help.offset_left = -380
	_help.offset_right = 380
	_help.offset_top = -330
	_help.offset_bottom = 330
	var text := RmUtil.make_label("""
  选择 SELECT
    左键单击 / 拖框            选择单位 (Shift 追加)
    1-9  /  Ctrl+A  /  Esc     按编号选择 / 全选 / 取消
    双击单位卡片  或  F        镜头聚焦所选单位

  指令 ORDERS
    右键地面 (或战术地图)      移动到目标点 (多机自动编队)
    按住右键 + Shift 上下拖动  设定无人机目标高度 (家园式三维移动)
    Space / X                  停止 (取消导航 + 零速)
    N                          导航: Godot(cmd_vel) / ROS(uwb_goal_nav)
    C                          重新标定所选单位航向
    L                          显示/隐藏机器人头顶文字
    M                          手动驾驶模式 开/关
      I K / J L / U O          前后 / 左右平移 / 旋转
      Shift                    加速

  镜头 CAMERA
    WASD / 方向键 / 屏幕边缘   平移 (Shift 加速)
    滚轮 / 中键拖动 / Q E       缩放 / 旋转俯仰 / 旋转
    R                          复位镜头

  界面 PANELS
    点击面板标题 / F2-F6        折叠 单位/基站/日志/地图/指令
    Tab                        折叠全部侧边面板
    右键单位卡片               精简显示

  其他  H 隐藏界面   P 特效开关   F1 帮助   F11 全屏
""", 15, RmUtil.TEXT)
	text.position = Vector2(18, 26)
	_help.add_child(text)
	_help.visible = false


## drifting sparks over the whole HUD
func _build_ambient() -> void:
	var p := CPUParticles2D.new()
	p.amount = 60
	p.lifetime = 8.0
	p.preprocess = 8.0
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	p.emission_rect_extents = Vector2(1000, 10)
	p.direction = Vector2(0, -1)
	p.spread = 15.0
	p.gravity = Vector2.ZERO
	p.initial_velocity_min = 15.0
	p.initial_velocity_max = 45.0
	p.scale_amount_min = 1.0
	p.scale_amount_max = 3.0
	var g := Gradient.new()
	g.colors = PackedColorArray([Color(RmUtil.CYAN, 0), Color(RmUtil.CYAN, 0.6), Color(RmUtil.MAGENTA, 0.5), Color(RmUtil.MAGENTA, 0)])
	g.offsets = PackedFloat32Array([0.0, 0.2, 0.7, 1.0])
	p.color_ramp = g
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	p.material = mat
	p.name = "Ambient"
	_root.add_child(p)
	_root.move_child(p, 0)
	var place := func():
		p.position = Vector2(_root.size.x / 2.0, _root.size.y + 10)
		p.emission_rect_extents = Vector2(_root.size.x / 2.0, 10)
	_root.resized.connect(place)
	place.call_deferred()


# ---------------------------------------------------------------- API

func set_units(units: Array) -> void:
	for c in _unit_list.get_children():
		c.queue_free()
	_cards.clear()
	for i in units.size():
		var u: RobotUnit = units[i]
		var card := UnitCard.new(u.robot_name, u.color, i + 1)
		card.unit = u
		var n := u.robot_name
		card.clicked.connect(func(add): unit_clicked.emit(n, add))
		card.double_clicked.connect(func(): unit_double_clicked.emit(n))
		_unit_list.add_child(card)
		_cards[n] = card
	minimap.units = units


func set_anchors(anchors: Array) -> void:
	minimap.anchors = anchors
	var none := _anchor_list.get_node_or_null("None")
	if none:
		none.visible = anchors.is_empty()
	var seen := {}
	for a in anchors:
		seen[a.anchor_id] = true
		var row: Label = _anchor_rows.get(a.anchor_id)
		if row == null:
			row = RmUtil.make_label("", 14, RmUtil.YELLOW)
			_anchor_list.add_child(row)
			_anchor_rows[a.anchor_id] = row
		var p: Vector3 = a.ros_position
		var stale := " [STALE]" if a.age > 5.0 else ""
		RmUtil.set_text(row, "◆ A%-2d  %+6.2f %+6.2f %+5.2f%s" % [a.anchor_id, p.x, p.y, p.z, stale])
		RmUtil.set_font_color(row, RmUtil.ORANGE if stale != "" else RmUtil.YELLOW)
	for id in _anchor_rows.keys():
		if not seen.has(id):
			_anchor_rows[id].queue_free()
			_anchor_rows.erase(id)


func log_msg(text: String, color := RmUtil.TEXT_DIM) -> void:
	if _log == null:
		return
	var ts := Time.get_time_string_from_system()
	_log.append_text("[color=#%s]%s[/color] [color=#%s]%s[/color]\n" % [RmUtil.MAGENTA.to_html(false), ts, color.to_html(false), text])


func toast(text: String, color := RmUtil.CYAN) -> void:
	_toast.text = text
	_toast.add_theme_color_override("font_color", color)
	_toast_t = 1.8
	_glitch_t = 0.25


func toggle_panel(i: int) -> void:
	if i >= 0 and i < _panels.size():
		_panels[i].set_collapsed(not _panels[i].collapsed)


## Tab: fold / unfold the side panels together (units, beacons, log)
func toggle_side_panels() -> void:
	var fold := false
	for k in 3:
		if not _panels[k].collapsed:
			fold = true
	for k in 3:
		_panels[k].set_collapsed(fold)


func toggle_help() -> void:
	_help.visible = not _help.visible


func set_hud_visible(v: bool) -> void:
	_root.visible = v


func is_over_ui() -> bool:
	var c := _root.get_viewport().gui_get_hovered_control()
	return c != null and c != _root and c != _overlay and c.mouse_filter != Control.MOUSE_FILTER_IGNORE


var _status_t := 0.0


func update_status(selected: Array, mode: String, stats: Dictionary, ros_ok: bool, demo: bool, manual_info: String) -> void:
	var dt := get_process_delta_time()
	var t := Time.get_ticks_msec() / 1000.0
	_mode_label.modulate.a = 0.75 + 0.25 * sin(t * 4.0)
	RmUtil.set_text(_mode_label, mode)
	RmUtil.set_text(_manual_label, manual_info)

	# text that changes all the time: 4 Hz is plenty
	_status_t -= dt
	if _status_t <= 0.0:
		_status_t = 0.25
		RmUtil.set_text(_clock_label, Time.get_time_string_from_system())
		var link := "◉ DEMO 演示" if demo else ("◉ ROS2 ONLINE" if ros_ok else "◌ ROS2 OFFLINE")
		RmUtil.set_text(_status_label, "%s   RX %d   TX %d   FPS %d" % [link, stats.get("rx", 0), stats.get("tx", 0), Engine.get_frames_per_second()])
		RmUtil.set_font_color(_status_label, RmUtil.LIME if (ros_ok or demo) else RmUtil.ORANGE)
		if selected.is_empty():
			RmUtil.set_text(_sel_label, "NO UNIT SELECTED  // 未选择单位")
			RmUtil.set_font_color(_sel_label, RmUtil.TEXT_DIM)
			RmUtil.set_text(_sel_detail, "左键选择单位，右键地面下达移动指令")
		else:
			var names := PackedStringArray()
			for u in selected:
				names.append(u.robot_name.to_upper())
			RmUtil.set_text(_sel_label, "%d UNIT%s ▸ %s" % [selected.size(), "S" if selected.size() > 1 else "", " · ".join(names)])
			RmUtil.set_font_color(_sel_label, selected[0].color.lightened(0.2) if selected.size() == 1 else RmUtil.CYAN)
			var u0: RobotUnit = selected[0]
			if selected.size() == 1 and u0.has_pose:
				RmUtil.set_text(_sel_detail, "x %+.2f  y %+.2f  yaw %+.1f°  v %.2f m/s  age %.2fs  %s" % [
					u0.ros_position.x, u0.ros_position.y, rad_to_deg(u0.yaw), u0.speed, u0.age, u0.status])
			else:
				RmUtil.set_text(_sel_detail, "formation spread around the target point 多车将围绕目标点编队")
		for k in ["move", "stop", "manual", "focus"]:
			if _buttons[k].disabled != selected.is_empty():
				_buttons[k].disabled = selected.is_empty()
		# offline robots: no card, listed in the panel header instead
		var offline := PackedStringArray()
		var hotkey := 1
		for card in _unit_list.get_children():
			if not card is UnitCard:
				continue
			var on: bool = card.unit != null and card.unit.is_online()
			if card.visible != on:
				card.visible = on
			if on:
				card.hotkey = hotkey
				hotkey += 1
			else:
				offline.append(card.robot)
		var sub := "OFFLINE: " + ", ".join(offline) if not offline.is_empty() else "RMB: compact"
		if _panels[0].subtitle != sub:
			_panels[0].subtitle = sub

	# glitchy title
	_glitch_t = maxf(_glitch_t - dt, 0.0)
	if _glitch_t > 0.0 or randf() < 0.004:
		var chars := "▓▒░#@$%&*<>/\\|01"
		var s := _title_text
		for k in 3:
			var i := randi() % s.length()
			s = s.substr(0, i) + chars[randi() % chars.length()] + s.substr(i + 1)
		_title.text = s
		_title.position.x = 28 + randf_range(-3, 3)
		if _glitch_t <= 0.0:
			_glitch_t = 0.08
	elif _title.text != _title_text:
		_title.text = _title_text
		_title.position.x = 28

	if _toast_t > 0.0:
		_toast_t -= dt
		_toast.modulate.a = clampf(_toast_t / 0.5, 0.0, 1.0)
		_toast.visible = true
	elif _toast.visible:
		_toast.visible = false
	if box_active or targeting or _overlay_dirty:
		_overlay.queue_redraw()
	_overlay_dirty = box_active or targeting


var _overlay_dirty := false


func _draw_overlay() -> void:
	var t := Time.get_ticks_msec() / 1000.0
	if box_active:
		var r := box_rect.abs()
		_overlay.draw_rect(r, Color(RmUtil.CYAN, 0.08))
		_overlay.draw_rect(r, Color(RmUtil.CYAN, 0.9), false, 1.5)
		for corner in [r.position, r.position + Vector2(r.size.x, 0), r.end, r.position + Vector2(0, r.size.y)]:
			_overlay.draw_circle(corner, 2.5, RmUtil.MAGENTA)
		_overlay.draw_string(RmUtil.font(), r.position + Vector2(4, -6), "SELECT %dx%d" % [int(r.size.x), int(r.size.y)],
				HORIZONTAL_ALIGNMENT_LEFT, -1, 13, RmUtil.CYAN)
	if targeting:
		var m := _overlay.get_local_mouse_position()
		var s := 16.0 + 4.0 * sin(t * 8.0)
		_overlay.draw_arc(m, s, t * 3.0, t * 3.0 + TAU * 0.7, 24, RmUtil.CYAN, 2.0)
		_overlay.draw_line(m - Vector2(s + 8, 0), m - Vector2(s - 4, 0), RmUtil.MAGENTA, 2.0)
		_overlay.draw_line(m + Vector2(s - 4, 0), m + Vector2(s + 8, 0), RmUtil.MAGENTA, 2.0)
		_overlay.draw_line(m - Vector2(0, s + 8), m - Vector2(0, s - 4), RmUtil.MAGENTA, 2.0)
		_overlay.draw_line(m + Vector2(0, s - 4), m + Vector2(0, s + 8), RmUtil.MAGENTA, 2.0)
		_overlay.draw_string(RmUtil.font(true), m + Vector2(22, 26), "MOVE TARGET", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, RmUtil.CYAN)
