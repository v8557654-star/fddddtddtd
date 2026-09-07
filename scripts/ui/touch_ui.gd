class_name TouchUI
extends Control
## Mobile control overlay: floating left joystick, right-side look drag,
## action buttons. Enabled when GameSettings.control_mode == "mob".

var joy_id := -1
var joy_center := Vector2.ZERO
var joy_vec := Vector2.ZERO
var joy_active := false
var look_id := -1

var btns := {}
var _player: Node = null
var _game: Node = null


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_buttons()


func _player_node() -> Node:
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("player")
	return _player


func _game_node() -> Node:
	if _game == null or not is_instance_valid(_game):
		_game = get_tree().get_first_node_in_group("game")
	return _game


func _build_buttons() -> void:
	var vp := get_viewport_rect().size
	_add_btn("interact", "ВЗАИМ.", Vector2(vp.x - 150, vp.y - 170), Vector2(110, 64))
	_add_btn("sprint", "БЕГ", Vector2(vp.x - 260, vp.y - 120), Vector2(86, 52), true)
	_add_btn("crouch", "ПРИСЕД", Vector2(vp.x - 260, vp.y - 190), Vector2(86, 52), true)
	_add_btn("flash", "ФОНАРЬ", Vector2(vp.x - 360, vp.y - 120), Vector2(86, 52))
	_add_btn("nvg", "ПНВ", Vector2(vp.x - 360, vp.y - 190), Vector2(86, 52))
	_add_btn("leanl", "НАКЛОН Л", Vector2(vp.x * 0.42, vp.y - 84), Vector2(96, 50), true)
	_add_btn("leanr", "НАКЛОН Р", Vector2(vp.x * 0.42 + 110, vp.y - 84), Vector2(96, 50), true)
	_add_btn("pause", "II", Vector2(vp.x - 74, 26), Vector2(52, 40))
	_add_btn("inv", "РЮКЗАК", Vector2(vp.x - 150, 26), Vector2(70, 40))


func _add_btn(key: String, label: String, pos: Vector2, sz: Vector2, hold := false) -> void:
	var b := Button.new()
	b.name = "tb_" + key
	b.text = label
	b.position = pos
	b.size = sz
	var st := StyleBoxFlat.new()
	st.bg_color = Color(0.05, 0.05, 0.06, 0.55)
	st.border_color = Color(0.8, 0.75, 0.5, 0.5)
	st.set_border_width_all(2)
	st.set_corner_radius_all(10)
	b.add_theme_stylebox_override("normal", st)
	var stp := st.duplicate()
	stp.bg_color = Color(0.35, 0.3, 0.12, 0.75)
	b.add_theme_stylebox_override("pressed", stp)
	b.add_theme_font_size_override("font_size", 13)
	b.mouse_filter = Control.MOUSE_FILTER_STOP
	match key:
		"interact":
			b.pressed.connect(func():
				var p := _player_node()
				if p != null:
					p.try_interact())
			b.button_down.connect(func():
				var p := _player_node()
				if p != null:
					p.touch_interact_held = true)
			b.button_up.connect(func():
				var p := _player_node()
				if p != null:
					p.touch_interact_held = false)
		"flash":
			b.pressed.connect(func():
				var p := _player_node()
				if p != null:
					p.set_flashlight(not p.flashlight_on))
		"nvg":
			b.pressed.connect(func():
				var p := _player_node()
				if p != null:
					p.set_nvg(not p.nvg_on))
		"sprint":
			b.toggled.connect(func(on: bool):
				var p := _player_node()
				if p != null:
					p.touch_sprint = on)
			b.toggle_mode = true
		"crouch":
			b.toggled.connect(func(on: bool):
				var p := _player_node()
				if p != null:
					p.touch_crouch = on)
			b.toggle_mode = true
		"leanl":
			b.button_down.connect(func():
				var p := _player_node()
				if p != null:
					p.touch_lean = -1.0)
			b.button_up.connect(func():
				var p := _player_node()
				if p != null:
					p.touch_lean = 0.0)
		"leanr":
			b.button_down.connect(func():
				var p := _player_node()
				if p != null:
					p.touch_lean = 1.0)
			b.button_up.connect(func():
				var p := _player_node()
				if p != null:
					p.touch_lean = 0.0)
		"pause":
			b.pressed.connect(func():
				var g := _game_node()
				if g != null:
					g.toggle_pause())
		"inv":
			b.pressed.connect(func():
				var g := _game_node()
				if g != null:
					g.toggle_inventory())
	add_child(b)
	btns[key] = b


func _over_button(p: Vector2) -> bool:
	for k in btns:
		var b: Control = btns[k]
		if Rect2(b.global_position, b.size).has_point(p):
			return true
	return false


func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventScreenTouch:
		if event.pressed:
			if _over_button(event.position):
				return
			if joy_id == -1 and event.position.x < get_viewport_rect().size.x * 0.45:
				joy_id = event.index
				joy_center = event.position
				joy_vec = Vector2.ZERO
				joy_active = true
				queue_redraw()
			elif look_id == -1:
				look_id = event.index
		else:
			if event.index == joy_id:
				joy_id = -1
				joy_vec = Vector2.ZERO
				joy_active = false
				var p := _player_node()
				if p != null:
					p.touch_move = Vector2.ZERO
				queue_redraw()
			if event.index == look_id:
				look_id = -1
	elif event is InputEventScreenDrag:
		if event.index == joy_id:
			joy_vec = (event.position - joy_center) / 70.0
			if joy_vec.length() > 1.0:
				joy_vec = joy_vec.normalized()
			var p := _player_node()
			if p != null:
				p.touch_move = joy_vec
			queue_redraw()
		elif event.index == look_id:
			var p2 := _player_node()
			if p2 != null:
				p2.apply_touch_look(event.relative)


func _draw() -> void:
	var vp := get_viewport_rect().size
	# resting hint for the joystick zone
	var base := joy_center if joy_active else Vector2(150, vp.y - 170)
	draw_circle(base, 74, Color(0.9, 0.85, 0.6, 0.10 if joy_active else 0.06))
	draw_arc(base, 74, 0, TAU, 40, Color(0.9, 0.85, 0.6, 0.45 if joy_active else 0.30), 3.0)
	draw_circle(base + joy_vec * 60.0, 26, Color(0.95, 0.9, 0.7, 0.55 if joy_active else 0.32))
