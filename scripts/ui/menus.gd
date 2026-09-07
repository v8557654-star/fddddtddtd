class_name MenusUI
extends CanvasLayer
## All 2D menus: title / settings / pause / game over / victory.
## Styled as a degraded VHS/bodycam tape menu: black + mustard accents,
## flickering static, corner brackets, glitching title.

signal start_game
signal resume_game
signal restart_game
signal to_menu
signal settings_changed
signal net_start_game          # v10: host pressed "start" in the lobby

enum Screen { NONE, TITLE, SETTINGS, PAUSE, DEAD, NET }

const ACCENT := Color(0.93, 0.78, 0.36)
const ACCENT_DIM := Color(0.93, 0.78, 0.36, 0.55)
const TEXT := Color(0.9, 0.89, 0.83)
const TEXT_DIM := Color(0.62, 0.61, 0.55)
const BLOOD := Color(0.8, 0.12, 0.1)
const GOOD := Color(0.5, 0.85, 0.5)

var font_ui: Font
var font_ui_b: Font
var font_osd: Font
var font_osd_b: Font
var current: int = Screen.NONE

var root: Control
var panels := {}
var static_tex: TextureRect
var glow_tex: TextureRect
var _flick := 0.0
var _glitch_t := 0.0
var title_big: Label
var title_shadow: Label
var tape_label: Label

var end_title: Label
var end_sub: Label
var stats_label: Label

var sl := {}          # key -> HSlider
var sl_val := {}      # key -> Label
var chk := {}
var diff_buttons := []
var gfx_buttons: Array = []
var ctrl_buttons := []
var seed_edit: LineEdit
var lurk_vp: SubViewportContainer = null
# v10: multiplayer screen
var net_ip_edit: LineEdit
var net_nick_edit: LineEdit
var net_status: Label
var net_roster: Label
var net_ips: Label
var net_start_btn: Button
var net_leave_btn: Button
var net_host_btn: Button
var net_join_btn: Button
var net_row_join: HBoxContainer
var _net_msg := ""
var _net_bad := false
var lurk_model: MonsterModel = null
var lurk_light: OmniLight3D = null
var _lurk_t := 0.0


func _ready() -> void:
	layer = 60
	font_ui = load("res://assets/fonts/ui.ttf")
	font_ui_b = load("res://assets/fonts/ui_bold.ttf")
	font_osd = load("res://assets/fonts/osd_mono.ttf")
	font_osd_b = load("res://assets/fonts/osd_mono_bold.ttf")
	root = Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(root)
	_build_bg()
	_build_title()
	_build_settings()
	_build_pause()
	_build_end()
	_build_net()
	show_screen(Screen.TITLE)


# ------------------------------------------------------------------ chrome
func _build_bg() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.012, 0.012, 0.014, 1.0)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(bg)

	# warm mustard glow rising from the bottom -- "the hum of the lamps"
	var gt := GradientTexture2D.new()
	var g := Gradient.new()
	g.set_color(0, Color(0.55, 0.45, 0.16, 0.0))
	g.set_color(1, Color(0.55, 0.45, 0.16, 0.22))
	gt.gradient = g
	gt.fill_from = Vector2(0.5, 0.25)
	gt.fill_to = Vector2(0.5, 1.0)
	gt.width = 8
	gt.height = 256
	glow_tex = TextureRect.new()
	glow_tex.texture = gt
	glow_tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	glow_tex.stretch_mode = TextureRect.STRETCH_SCALE
	glow_tex.set_anchors_preset(Control.PRESET_FULL_RECT)
	glow_tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(glow_tex)

	static_tex = TextureRect.new()
	static_tex.texture = load("res://textures/static.png")
	static_tex.stretch_mode = TextureRect.STRETCH_TILE
	static_tex.modulate = Color(1, 1, 1, 0.05)
	static_tex.set_anchors_preset(Control.PRESET_FULL_RECT)
	static_tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(static_tex)

	# scanline stripes
	var lines := ColorRect.new()
	lines.set_anchors_preset(Control.PRESET_FULL_RECT)
	lines.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sh := ShaderMaterial.new()
	var code := Shader.new()
	code.code = """
shader_type canvas_item;
void fragment() {
	float l = step(0.5, fract(FRAGCOORD.y / 3.0));
	vec2 uv = SCREEN_UV - 0.5;
	float vig = smoothstep(0.95, 0.35, length(uv * vec2(1.0, 1.25)));
	COLOR = vec4(0.0, 0.0, 0.0, l * 0.16 + (1.0 - vig) * 0.75);
}
"""
	sh.shader = code
	lines.material = sh
	root.add_child(lines)

	# corner brackets
	var bc := Color(0.9, 0.9, 0.85, 0.35)
	for cnr in range(4):
		var h := ColorRect.new()
		var v := ColorRect.new()
		h.color = bc
		v.color = bc
		h.size = Vector2(52, 2)
		v.size = Vector2(2, 52)
		h.mouse_filter = Control.MOUSE_FILTER_IGNORE
		v.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var preset: int = [Control.PRESET_TOP_LEFT, Control.PRESET_TOP_RIGHT, Control.PRESET_BOTTOM_LEFT, Control.PRESET_BOTTOM_RIGHT][cnr]
		h.set_anchors_preset(preset)
		v.set_anchors_preset(preset)
		var sx := 1.0 if cnr % 2 == 0 else -1.0
		var sy := 1.0 if cnr < 2 else -1.0
		h.position = Vector2(24 if sx > 0 else -76, 24 if sy > 0 else -26)
		v.position = Vector2(24 if sx > 0 else -26, 24 if sy > 0 else -76)
		root.add_child(h)
		root.add_child(v)

	tape_label = _label("TAPE 07  ·  NO SIGNAL  ·  PLAY ▶", 13, TEXT_DIM, false, true)
	tape_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	tape_label.position = Vector2(34, 32)
	tape_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	tape_label.size_flags_horizontal = 0
	root.add_child(tape_label)


func _panel() -> Control:
	var p := Control.new()
	p.set_anchors_preset(Control.PRESET_FULL_RECT)
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	p.visible = false
	root.add_child(p)
	return p


func _label(txt: String, size: int, col := TEXT, bold := false, mono := false) -> Label:
	var l := Label.new()
	l.text = txt
	l.add_theme_font_override("font", (font_osd_b if bold else font_osd) if mono else (font_ui_b if bold else font_ui))
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _button(txt: String, w := 340.0, h := 48.0, big := true) -> Button:
	var b := Button.new()
	b.text = txt
	b.custom_minimum_size = Vector2(w, h)
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT if big else HORIZONTAL_ALIGNMENT_CENTER
	b.add_theme_font_override("font", font_osd_b if big else font_osd)
	b.add_theme_font_size_override("font_size", 17 if big else 14)
	b.add_theme_color_override("font_color", TEXT)
	b.add_theme_color_override("font_hover_color", ACCENT)
	b.add_theme_color_override("font_pressed_color", ACCENT)
	b.add_theme_color_override("font_focus_color", TEXT)
	var st := StyleBoxFlat.new()
	st.bg_color = Color(0.05, 0.05, 0.055, 0.72)
	st.border_color = Color(0.5, 0.47, 0.36, 0.25)
	st.set_border_width_all(1)
	st.border_width_left = 3
	st.set_content_margin_all(10)
	st.content_margin_left = 18
	b.add_theme_stylebox_override("normal", st)
	var sth := st.duplicate()
	sth.bg_color = Color(0.16, 0.13, 0.06, 0.92)
	sth.border_color = ACCENT
	sth.border_width_left = 5
	b.add_theme_stylebox_override("hover", sth)
	b.add_theme_stylebox_override("pressed", sth)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.mouse_entered.connect(func(): AudioBank.play("click", 0.2, 1.4, "UI"))
	return b


func _hr(p: Control, w: float, col := ACCENT_DIM) -> void:
	var r := ColorRect.new()
	r.color = col
	r.custom_minimum_size = Vector2(w, 1)
	r.size_flags_horizontal = 0
	p.add_child(r)


func _spacer(p: Control, h: float) -> void:
	var s := Control.new()
	s.custom_minimum_size = Vector2(0, h)
	p.add_child(s)


func _section(p: Control, title: String) -> void:
	_spacer(p, 6)
	p.add_child(_label(title, 13, ACCENT, true, true))
	_hr(p, 380)
	_spacer(p, 2)


func _slider_row(p: Control, key: String, title: String, minv: float, maxv: float, val: float,
		step := 0.01, fmt := "%.2f", scale := 1.0) -> HSlider:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var l := _label(title, 14, TEXT, false, true)
	l.custom_minimum_size = Vector2(230, 0)
	row.add_child(l)
	var s := HSlider.new()
	s.min_value = minv
	s.max_value = maxv
	s.step = step
	s.value = val
	s.custom_minimum_size = Vector2(180, 20)
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_style_slider(s)
	row.add_child(s)
	var v := _label(fmt % (val * scale), 13, ACCENT, false, true)
	v.custom_minimum_size = Vector2(60, 0)
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(v)
	s.value_changed.connect(func(x): v.text = fmt % (x * scale))
	p.add_child(row)
	sl[key] = s
	sl_val[key] = v
	return s


func _style_slider(s: HSlider) -> void:
	var track := StyleBoxFlat.new()
	track.bg_color = Color(1, 1, 1, 0.10)
	track.set_content_margin_all(0)
	track.content_margin_top = 2
	track.content_margin_bottom = 2
	s.add_theme_stylebox_override("slider", track)
	var fill := StyleBoxFlat.new()
	fill.bg_color = ACCENT_DIM
	fill.content_margin_top = 2
	fill.content_margin_bottom = 2
	s.add_theme_stylebox_override("grabber_area", fill)
	s.add_theme_stylebox_override("grabber_area_highlight", fill)
	var gt := GradientTexture2D.new()
	var g := Gradient.new()
	g.set_color(0, ACCENT)
	g.set_color(1, ACCENT)
	gt.gradient = g
	gt.width = 8
	gt.height = 16
	s.add_theme_icon_override("grabber", gt)
	s.add_theme_icon_override("grabber_highlight", gt)
	s.add_theme_icon_override("grabber_disabled", gt)


func _check_row(p: Control, title: String, val: bool, key: String) -> void:
	var c := CheckBox.new()
	c.text = title
	c.button_pressed = val
	c.add_theme_font_override("font", font_osd)
	c.add_theme_font_size_override("font_size", 14)
	c.add_theme_color_override("font_color", TEXT)
	c.add_theme_color_override("font_hover_color", ACCENT)
	c.add_theme_color_override("font_pressed_color", TEXT)
	c.add_theme_color_override("font_hover_pressed_color", ACCENT)
	c.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	c.toggled.connect(func(_on): AudioBank.play("click", 0.35, 1.1, "UI"))
	p.add_child(c)
	chk[key] = c


func _choice_row(p: Control, title: String, names: Array, cb: Callable, store: Array) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var l := _label(title, 14, TEXT, false, true)
	l.custom_minimum_size = Vector2(230, 0)
	row.add_child(l)
	for i in range(names.size()):
		var b := _button(names[i], 0, 30, false)
		b.custom_minimum_size = Vector2(88, 30)
		b.pressed.connect(cb.bind(i))
		row.add_child(b)
		store.append(b)
	p.add_child(row)


func _mark_choice(buttons: Array, sel: int) -> void:
	for i in range(buttons.size()):
		var b: Button = buttons[i]
		var st: StyleBoxFlat = b.get_theme_stylebox("normal")
		if i == sel:
			st.bg_color = Color(0.36, 0.29, 0.10, 0.95)
			st.border_color = ACCENT
			b.add_theme_color_override("font_color", ACCENT)
		else:
			st.bg_color = Color(0.05, 0.05, 0.055, 0.72)
			st.border_color = Color(0.5, 0.47, 0.36, 0.25)
			b.add_theme_color_override("font_color", TEXT)


# ------------------------------------------------------------------ title
func _build_title() -> void:
	var p := _panel()
	panels[Screen.TITLE] = p

	var col := VBoxContainer.new()
	col.set_anchors_preset(Control.PRESET_CENTER_LEFT)
	col.position = Vector2(110, -270)
	col.custom_minimum_size = Vector2(520, 540)
	col.add_theme_constant_override("separation", 8)
	p.add_child(col)

	col.add_child(_label("// FOUND FOOTAGE  ·  BODYCAM  ·  LEVEL 0 → LEVEL 4", 13, TEXT_DIM, false, true))
	_spacer(col, 2)
	var tw := Control.new()
	tw.custom_minimum_size = Vector2(520, 96)
	col.add_child(tw)
	title_shadow = _label("BACKROOMS", 84, Color(0.8, 0.15, 0.1, 0.45), true)
	title_shadow.position = Vector2(3, -8)
	tw.add_child(title_shadow)
	title_big = _label("BACKROOMS", 84, ACCENT, true)
	title_big.position = Vector2(0, -10)
	tw.add_child(title_big)
	var sub := _label("Б О Д И К А М", 22, TEXT, false, true)
	col.add_child(sub)
	_hr(col, 420)
	_spacer(col, 2)
	var tag := _label("Ни одного человеческого следа.\nТолько плёнка в камере — и что-то, что ходит за спиной.", 15, TEXT_DIM)
	col.add_child(tag)
	_spacer(col, 14)

	var b1 := _button("▶   НАЧАТЬ ЗАПИСЬ")
	b1.pressed.connect(func():
			AudioBank.play("click", 0.6, 0.9, "UI")
			start_game.emit())
	col.add_child(b1)
	var bn := _button("     ВМЕСТЕ  ·  LAN / ИНТЕРНЕТ")
	bn.pressed.connect(func():
			AudioBank.play("click", 0.6, 0.9, "UI")
			show_screen(Screen.NET))
	col.add_child(bn)
	var b2 := _button("     НАСТРОЙКИ")
	b2.pressed.connect(func(): show_screen(Screen.SETTINGS))
	col.add_child(b2)
	var b3 := _button("     ВЫХОД")
	b3.pressed.connect(func(): get_tree().quit())
	col.add_child(b3)
	_spacer(col, 10)
	col.add_child(_label("WASD движение · SHIFT бег · CTRL присед · F фонарь · V ПНВ\nQ / R наклон · E взять / открыть · TAB рюкзак · 1 / 2 использовать · ESC пауза", 12, TEXT_DIM, false, true))

	_build_lurker(p)
	var ver := _label("v11  ·  5 LEVELS  ·  CO-OP  ·  GODOT 4", 12, TEXT_DIM, false, true)
	ver.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	ver.position = Vector2(-260, -40)
	ver.custom_minimum_size = Vector2(220, 0)
	ver.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	p.add_child(ver)


func _build_lurker(p: Control) -> void:
	## a dim 3D vignette: the creature standing in a yellow corridor, barely lit
	lurk_vp = SubViewportContainer.new()
	lurk_vp.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	lurk_vp.offset_left = -520
	lurk_vp.offset_right = -20
	lurk_vp.offset_top = 40
	lurk_vp.offset_bottom = -40
	lurk_vp.stretch = true
	lurk_vp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lurk_vp.modulate = Color(1, 1, 1, 0.9)
	# soft oval mask so the vignette bleeds into the black
	var mask := ShaderMaterial.new()
	var msh := Shader.new()
	msh.code = """
shader_type canvas_item;
void fragment() {
	vec4 c = texture(TEXTURE, UV);
	vec2 d = (UV - vec2(0.5, 0.52)) * vec2(1.0, 0.85);
	float a = 1.0 - smoothstep(0.22, 0.5, length(d));
	COLOR = vec4(c.rgb, c.a * a);
}
"""
	mask.shader = msh
	lurk_vp.material = mask
	p.add_child(lurk_vp)
	var vp := SubViewport.new()
	vp.transparent_bg = false
	vp.msaa_3d = Viewport.MSAA_DISABLED
	vp.own_world_3d = true
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.012, 0.012, 0.014, 1.0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.4, 0.34, 0.2)
	env.ambient_light_energy = 0.12
	env.fog_enabled = true
	env.fog_light_color = Color(0.2, 0.17, 0.1)
	env.fog_density = 0.08
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)
	lurk_vp.add_child(vp)
	var cam := Camera3D.new()
	cam.position = Vector3(0, 1.5, 5.4)
	cam.fov = 48
	cam.current = true
	vp.add_child(cam)
	lurk_model = MonsterModel.new()
	lurk_model.position = Vector3(0.3, 0, 0)
	lurk_model.rotation.y = -0.35
	vp.add_child(lurk_model)
	# flickering overhead lamp behind the creature
	lurk_light = OmniLight3D.new()
	lurk_light.light_color = Color(1.0, 0.9, 0.7)
	lurk_light.light_energy = 2.2
	lurk_light.omni_range = 8.0
	lurk_light.position = Vector3(-0.5, 3.4, -1.0)
	vp.add_child(lurk_light)
	# floor + back wall so the light has something to fall on
	var fl := MeshInstance3D.new()
	var fm := PlaneMesh.new()
	fm.size = Vector2(12, 12)
	var mf := StandardMaterial3D.new()
	mf.albedo_color = Color(0.45, 0.38, 0.14)
	mf.roughness = 0.95
	fm.material = mf
	fl.mesh = fm
	vp.add_child(fl)
	var wall := MeshInstance3D.new()
	var wm := BoxMesh.new()
	wm.size = Vector3(12, 5, 0.2)
	var mw := StandardMaterial3D.new()
	mw.albedo_color = Color(0.62, 0.55, 0.22)
	mw.roughness = 0.9
	wm.material = mw
	wall.mesh = wm
	wall.position = Vector3(0, 2.5, -3.0)
	vp.add_child(wall)


# ------------------------------------------------------------------ settings
func _build_settings() -> void:
	var p := _panel()
	panels[Screen.SETTINGS] = p

	var outer := VBoxContainer.new()
	outer.set_anchors_preset(Control.PRESET_FULL_RECT)
	outer.offset_left = 90
	outer.offset_right = -90
	outer.offset_top = 64
	outer.offset_bottom = -40
	outer.add_theme_constant_override("separation", 10)
	p.add_child(outer)

	var head := HBoxContainer.new()
	head.add_child(_label("НАСТРОЙКИ", 34, ACCENT, true))
	var hs := Control.new()
	hs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(hs)
	head.add_child(_label("изменения применяются сразу · сохраняются по кнопке", 12, TEXT_DIM, false, true))
	outer.add_child(head)
	_hr(outer, 1100)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	outer.add_child(scroll)

	var cols := HBoxContainer.new()
	cols.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_theme_constant_override("separation", 60)
	scroll.add_child(cols)
	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 6)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_child(left)
	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 6)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_child(right)

	# ---- left: controls + camera
	_section(left, "УПРАВЛЕНИЕ")
	_slider_row(left, "sens", "Чувствительность мыши", 0.0005, 0.006, GameSettings.mouse_sensitivity, 0.0001, "%.1f", 1000.0)
	_slider_row(left, "tsens", "Чувствительность тача", 0.001, 0.012, GameSettings.touch_sensitivity, 0.0001, "%.1f", 1000.0)
	_check_row(left, "Инверсия оси Y", GameSettings.invert_y, "inverty")
	_choice_row(left, "Схема", ["ПК", "МОБИЛЬНОЕ"], _on_control_mode, ctrl_buttons)

	_section(left, "ГРАФИКА")
	_choice_row(left, "Качество", ["НИЗКОЕ", "НОРМ.", "ВЫСОКОЕ", "УЛЬТРА"], _on_graphics, gfx_buttons)
	gfx_hint = _label("", 11, TEXT_DIM, false, true)
	gfx_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	gfx_hint.custom_minimum_size = Vector2(480, 0)
	left.add_child(gfx_hint)
	_update_gfx_hint()

	_section(left, "КАМЕРА / ИЗОБРАЖЕНИЕ")
	_slider_row(left, "fov", "Поле зрения (FOV)", 60, 100, GameSettings.fov, 1, "%.0f°")
	_slider_row(left, "grain", "Зерно плёнки", 0, 2, GameSettings.grain_amount, 0.05, "%.2f")
	_slider_row(left, "scan", "Строчная развёртка", 0, 2, GameSettings.scanline_amount, 0.05, "%.2f")
	_slider_row(left, "vig", "Виньетка", 0, 1.5, GameSettings.vignette_amount, 0.05, "%.2f")
	_check_row(left, "Бодикам-эффекты", GameSettings.bodycam_enabled, "bodycam")
	_check_row(left, "Покачивание головы", GameSettings.head_bob_enabled, "headbob")
	_check_row(left, "Объёмный туман принудительно (тяжело для GPU)", GameSettings.volumetric_fog, "fog")
	_check_row(left, "Показывать FPS", GameSettings.show_fps, "fps")

	# ---- right: audio + game
	_section(right, "ЗВУК")
	_slider_row(right, "master", "Общая громкость", 0, 1, GameSettings.master_volume, 0.01, "%.0f%%", 100.0)
	_slider_row(right, "sfx", "Эффекты", 0, 1, GameSettings.sfx_volume, 0.01, "%.0f%%", 100.0)
	_slider_row(right, "amb", "Атмосфера", 0, 1, GameSettings.ambience_volume, 0.01, "%.0f%%", 100.0)
	_slider_row(right, "mon", "Монстр", 0, 1, GameSettings.monster_volume, 0.01, "%.0f%%", 100.0)

	_section(right, "ИГРА")
	_choice_row(right, "Сложность", ["ТУРИСТ", "СТАНДАРТ", "КОШМАР"], _on_difficulty, diff_buttons)
	_slider_row(right, "grace", "Пауза до монстра (мин)", 0.0, 5.0, GameSettings.grace_minutes, 0.5, "%.1f")
	_check_row(right, "Галлюцинации / появления за спиной", GameSettings.stalker_events, "stalker")
	_check_row(right, "Скримеры", GameSettings.jumpscares, "jumpscares")
	_check_row(right, "Субтитры", GameSettings.subtitles, "subs")
	var srow := HBoxContainer.new()
	srow.add_theme_constant_override("separation", 12)
	var sl_l := _label("Сид (-1 = случайный)", 14, TEXT, false, true)
	sl_l.custom_minimum_size = Vector2(230, 0)
	srow.add_child(sl_l)
	seed_edit = LineEdit.new()
	seed_edit.text = str(GameSettings.level_seed)
	seed_edit.custom_minimum_size = Vector2(150, 30)
	seed_edit.add_theme_font_override("font", font_osd)
	seed_edit.add_theme_font_size_override("font_size", 14)
	seed_edit.add_theme_color_override("font_color", ACCENT)
	var est := StyleBoxFlat.new()
	est.bg_color = Color(0.05, 0.05, 0.055, 0.8)
	est.border_color = Color(0.5, 0.47, 0.36, 0.35)
	est.set_border_width_all(1)
	est.set_content_margin_all(6)
	seed_edit.add_theme_stylebox_override("normal", est)
	seed_edit.add_theme_stylebox_override("focus", est)
	srow.add_child(seed_edit)
	right.add_child(srow)

	_hr(outer, 1100)
	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 12)
	var back := _button("←  СОХРАНИТЬ И ВЕРНУТЬСЯ", 320, 44)
	back.pressed.connect(_apply_and_back)
	foot.add_child(back)
	var reset := _button("СБРОСИТЬ", 160, 44, false)
	reset.pressed.connect(_reset_defaults)
	foot.add_child(reset)
	outer.add_child(foot)

	# live apply while dragging
	for k in sl.keys():
		sl[k].value_changed.connect(func(_v): _apply_live())
	for k in chk.keys():
		chk[k].toggled.connect(func(_v): _apply_live())
	_mark_choice(diff_buttons, GameSettings.difficulty)
	_mark_choice(ctrl_buttons, 0 if GameSettings.control_mode == "pc" else 1)
	_mark_choice(gfx_buttons, GameSettings.graphics)
	_update_gfx_hint()


var gfx_hint: Label = null
const GFX_HINTS := [
	"60% разрешения · без теней, SSAO и свечения · меньше ламп · 60 FPS. Для телефонов и слабых ноутбуков.",
	"85% разрешения · FXAA · тени фонаря · свечение. Баланс для большинства ПК.",
	"100% · MSAA 4x · SSAO · мягкие тени · все лампы. Дискретная видеокарта.",
	"100% · MSAA 8x · SSAO · объёмный туман · дальность 160 м. Только мощные GPU.",
]

func _update_gfx_hint() -> void:
	if gfx_hint != null:
		gfx_hint.text = GFX_HINTS[clampi(GameSettings.graphics, 0, 3)]


func _on_graphics(i: int) -> void:
	GameSettings.graphics = i
	_mark_choice(gfx_buttons, i)
	_update_gfx_hint()
	AudioBank.play("click", 0.4, 1.0, "UI")
	settings_changed.emit()


func _on_difficulty(i: int) -> void:
	GameSettings.difficulty = i
	_mark_choice(diff_buttons, i)
	AudioBank.play("click", 0.4, 1.0, "UI")


func _on_control_mode(i: int) -> void:
	GameSettings.control_mode = "pc" if i == 0 else "mob"
	_mark_choice(ctrl_buttons, i)
	settings_changed.emit()


func _apply_live() -> void:
	GameSettings.mouse_sensitivity = sl["sens"].value
	GameSettings.touch_sensitivity = sl["tsens"].value
	GameSettings.fov = sl["fov"].value
	GameSettings.master_volume = sl["master"].value
	GameSettings.sfx_volume = sl["sfx"].value
	GameSettings.ambience_volume = sl["amb"].value
	GameSettings.monster_volume = sl["mon"].value
	GameSettings.grain_amount = sl["grain"].value
	GameSettings.scanline_amount = sl["scan"].value
	GameSettings.vignette_amount = sl["vig"].value
	GameSettings.grace_minutes = snappedf(sl["grace"].value, 0.5)
	GameSettings.bodycam_enabled = chk["bodycam"].button_pressed
	GameSettings.head_bob_enabled = chk["headbob"].button_pressed
	GameSettings.volumetric_fog = chk["fog"].button_pressed
	GameSettings.subtitles = chk["subs"].button_pressed
	GameSettings.invert_y = chk["inverty"].button_pressed
	GameSettings.show_fps = chk["fps"].button_pressed
	GameSettings.stalker_events = chk["stalker"].button_pressed
	GameSettings.jumpscares = chk["jumpscares"].button_pressed
	GameSettings.apply_audio()
	settings_changed.emit()


func _apply_and_back() -> void:
	_apply_live()
	var t := seed_edit.text.strip_edges()
	GameSettings.level_seed = int(t) if t.is_valid_int() else -1
	seed_edit.text = str(GameSettings.level_seed)
	GameSettings.save_settings()
	AudioBank.play("click", 0.6, 0.9, "UI")
	show_screen(Screen.PAUSE if _game_paused() else Screen.TITLE)


func _reset_defaults() -> void:
	GameSettings.reset_defaults()
	_sync_widgets()
	_apply_live()
	GameSettings.save_settings()


func _sync_widgets() -> void:
	sl["sens"].set_value_no_signal(GameSettings.mouse_sensitivity)
	sl["tsens"].set_value_no_signal(GameSettings.touch_sensitivity)
	sl["fov"].set_value_no_signal(GameSettings.fov)
	sl["master"].set_value_no_signal(GameSettings.master_volume)
	sl["sfx"].set_value_no_signal(GameSettings.sfx_volume)
	sl["amb"].set_value_no_signal(GameSettings.ambience_volume)
	sl["mon"].set_value_no_signal(GameSettings.monster_volume)
	sl["grain"].set_value_no_signal(GameSettings.grain_amount)
	sl["scan"].set_value_no_signal(GameSettings.scanline_amount)
	sl["vig"].set_value_no_signal(GameSettings.vignette_amount)
	sl["grace"].set_value_no_signal(GameSettings.grace_minutes)
	for k in sl.keys():
		sl[k].value_changed.emit(sl[k].value)   # refresh value labels
	chk["bodycam"].set_pressed_no_signal(GameSettings.bodycam_enabled)
	chk["headbob"].set_pressed_no_signal(GameSettings.head_bob_enabled)
	chk["fog"].set_pressed_no_signal(GameSettings.volumetric_fog)
	chk["subs"].set_pressed_no_signal(GameSettings.subtitles)
	chk["inverty"].set_pressed_no_signal(GameSettings.invert_y)
	chk["fps"].set_pressed_no_signal(GameSettings.show_fps)
	chk["stalker"].set_pressed_no_signal(GameSettings.stalker_events)
	chk["jumpscares"].set_pressed_no_signal(GameSettings.jumpscares)
	seed_edit.text = str(GameSettings.level_seed)
	_mark_choice(diff_buttons, GameSettings.difficulty)
	_mark_choice(ctrl_buttons, 0 if GameSettings.control_mode == "pc" else 1)
	_mark_choice(gfx_buttons, GameSettings.graphics)
	_update_gfx_hint()


func _game_paused() -> bool:
	var g := get_tree().get_first_node_in_group("game")
	return g != null and (g.state == g.State.PAUSED or g.state == g.State.PLAYING or g.state == g.State.SPECTATE)


# ------------------------------------------------------------------ pause / end
func _centre_box(p: Control, w: float, h: float) -> VBoxContainer:
	var frame := PanelContainer.new()
	frame.set_anchors_preset(Control.PRESET_CENTER)
	frame.custom_minimum_size = Vector2(w, h)
	frame.position = Vector2(-w * 0.5, -h * 0.5)
	var st := StyleBoxFlat.new()
	st.bg_color = Color(0.03, 0.03, 0.035, 0.86)
	st.border_color = ACCENT_DIM
	st.set_border_width_all(1)
	st.border_width_top = 3
	st.set_content_margin_all(34)
	frame.add_theme_stylebox_override("panel", st)
	p.add_child(frame)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	frame.add_child(col)
	return col


func _build_pause() -> void:
	var p := _panel()
	panels[Screen.PAUSE] = p
	var col := _centre_box(p, 440, 380)
	col.add_child(_label("ПАУЗА", 40, ACCENT, true))
	col.add_child(_label("ЗАПИСЬ ПРИОСТАНОВЛЕНА  ·  ▌▌", 13, TEXT_DIM, false, true))
	_hr(col, 370)
	_spacer(col, 6)
	var b1 := _button("▶   ПРОДОЛЖИТЬ", 370)
	b1.pressed.connect(func(): resume_game.emit())
	col.add_child(b1)
	var b2 := _button("     НАСТРОЙКИ", 370)
	b2.pressed.connect(func(): show_screen(Screen.SETTINGS))
	col.add_child(b2)
	var b3 := _button("     В ГЛАВНОЕ МЕНЮ", 370)
	b3.pressed.connect(func(): to_menu.emit())
	col.add_child(b3)


func _build_end() -> void:
	var p := _panel()
	panels[Screen.DEAD] = p
	var col := _centre_box(p, 520, 400)
	end_title = _label("ЗАПИСЬ ПРЕРВАНА", 44, BLOOD, true)
	col.add_child(end_title)
	end_sub = _label("", 13, TEXT_DIM, false, true)
	col.add_child(end_sub)
	_hr(col, 450)
	stats_label = _label("", 15, TEXT, false, true)
	col.add_child(stats_label)
	_spacer(col, 8)
	var b1 := _button("▶   ПОВТОРИТЬ ЗАПИСЬ", 450)
	b1.pressed.connect(func(): restart_game.emit())
	col.add_child(b1)
	var b2 := _button("     В ГЛАВНОЕ МЕНЮ", 450)
	b2.pressed.connect(func(): to_menu.emit())
	col.add_child(b2)


# ------------------------------------------------------------------ v10: co-op
func _edit(txt: String, w: float) -> LineEdit:
	var e := LineEdit.new()
	e.text = txt
	e.custom_minimum_size = Vector2(w, 34)
	e.add_theme_font_override("font", font_osd)
	e.add_theme_font_size_override("font_size", 15)
	e.add_theme_color_override("font_color", ACCENT)
	var est := StyleBoxFlat.new()
	est.bg_color = Color(0.05, 0.05, 0.055, 0.8)
	est.border_color = Color(0.5, 0.47, 0.36, 0.35)
	est.set_border_width_all(1)
	est.set_content_margin_all(6)
	e.add_theme_stylebox_override("normal", est)
	e.add_theme_stylebox_override("focus", est)
	return e


func _build_net() -> void:
	var p := _panel()
	panels[Screen.NET] = p
	var col := _centre_box(p, 640, 560)
	col.add_child(_label("ВМЕСТЕ", 40, ACCENT, true))
	col.add_child(_label("ДО 4 ОПЕРАТОРОВ  ·  ОДНА ПЛЁНКА  ·  ОДНО СУЩЕСТВО", 13, TEXT_DIM, false, true))
	_hr(col, 570)
	# nick
	var nrow := HBoxContainer.new()
	nrow.add_theme_constant_override("separation", 12)
	var nl := _label("ПОЗЫВНОЙ", 14, TEXT, false, true)
	nl.custom_minimum_size = Vector2(150, 0)
	nrow.add_child(nl)
	net_nick_edit = _edit(Net.nick, 260)
	net_nick_edit.max_length = 14
	net_nick_edit.text_changed.connect(func(t):
			Net.nick = t.strip_edges() if t.strip_edges() != "" else Net.nick
			GameSettings.net_nick = Net.nick)
	nrow.add_child(net_nick_edit)
	col.add_child(nrow)
	_spacer(col, 4)
	# host
	net_host_btn = _button("▶   СОЗДАТЬ КОМНАТУ  (порт 7777)", 570)
	net_host_btn.pressed.connect(func():
			AudioBank.play("click", 0.6, 0.9, "UI")
			var err: String = Net.host()
			_net_set_status(err, err != ""))
	col.add_child(net_host_btn)
	# join
	net_row_join = HBoxContainer.new()
	net_row_join.add_theme_constant_override("separation", 10)
	net_ip_edit = _edit(str(GameSettings.net_last_ip), 300)
	net_ip_edit.placeholder_text = "IP хоста, напр. 192.168.43.1"
	net_row_join.add_child(net_ip_edit)
	net_join_btn = _button("     ПОДКЛЮЧИТЬСЯ", 260, 48, true)
	net_join_btn.pressed.connect(func():
			AudioBank.play("click", 0.6, 0.9, "UI")
			GameSettings.net_last_ip = net_ip_edit.text.strip_edges()
			GameSettings.save_settings()
			var err: String = Net.join(net_ip_edit.text)
			_net_set_status(err, err != ""))
	net_row_join.add_child(net_join_btn)
	col.add_child(net_row_join)
	_spacer(col, 2)
	net_ips = _label("", 12, TEXT_DIM, false, true)
	col.add_child(net_ips)
	_hr(col, 570)
	net_status = _label("НЕ В СЕТИ", 13, TEXT_DIM, false, true)
	col.add_child(net_status)
	net_roster = _label("", 15, TEXT, false, true)
	net_roster.custom_minimum_size = Vector2(0, 96)
	col.add_child(net_roster)
	_spacer(col, 2)
	net_start_btn = _button("▶   НАЧАТЬ ЗАПИСЬ ВМЕСТЕ", 570)
	net_start_btn.pressed.connect(func():
			AudioBank.play("click", 0.6, 0.9, "UI")
			net_start_game.emit())
	col.add_child(net_start_btn)
	var brow := HBoxContainer.new()
	brow.add_theme_constant_override("separation", 10)
	net_leave_btn = _button("     ПОКИНУТЬ КОМНАТУ", 280)
	net_leave_btn.pressed.connect(func():
			Net.leave()
			_net_set_status("", false))
	brow.add_child(net_leave_btn)
	var bb := _button("     НАЗАД", 280)
	bb.pressed.connect(func(): show_screen(Screen.TITLE))
	brow.add_child(bb)
	col.add_child(brow)
	Net.lobby_changed.connect(_net_refresh)
	Net.joined_ok.connect(func(): _net_set_status("", false))
	Net.join_failed.connect(func(r): _net_set_status(r, true))
	Net.session_closed.connect(func(r):
			_net_set_status(r, true)
			if current == Screen.NONE or current == Screen.PAUSE:
				to_menu.emit())
	_net_refresh()


func _net_set_status(t: String, bad: bool) -> void:
	_net_msg = t
	_net_bad = bad
	_net_refresh()


func _net_refresh() -> void:
	if net_roster == null:
		return
	var txt := _net_msg
	var bad := _net_bad
	if not bad or txt == "":
		if not Net.active:
			txt = "НЕ В СЕТИ"
			bad = false
		elif Net.is_host:
			txt = "КОМНАТА ОТКРЫТА  ·  %d / %d  ·  ЖДЁМ ОПЕРАТОРОВ" % [Net.peers.size(), Net.MAX_PLAYERS] if Net.peers.size() < 2 else "КОМНАТА ОТКРЫТА  ·  %d / %d  ·  МОЖНО НАЧИНАТЬ" % [Net.peers.size(), Net.MAX_PLAYERS]
		elif Net.peers.is_empty():
			txt = "ПОДКЛЮЧЕНИЕ..."
		else:
			txt = "В КОМНАТЕ  ·  ЖДЁМ, ПОКА ХОСТ НАЧНЁТ"
	net_status.text = txt
	net_status.add_theme_color_override("font_color", BLOOD if bad else (GOOD if Net.active else TEXT_DIM))
	if current == Screen.NET:
		tape_label.text = "TAPE 07  ·  LINK  ·  %s" % ("ONLINE" if Net.active else "OFFLINE")
	var lines: Array[String] = []
	if Net.active:
		var i := 1
		for id in Net.peer_ids():
			var tag := "  (ХОСТ)" if id == 1 else ""
			var me := "  ← ты" if id == Net.my_id() else ""
			lines.append("CAM %02d   %s%s%s" % [i, Net.peer_name(id), tag, me])
			i += 1
		if lines.size() < Net.MAX_PLAYERS:
			lines.append("CAM %02d   ..." % (lines.size() + 1))
	net_roster.text = "\n".join(PackedStringArray(lines))
	net_start_btn.visible = Net.active and Net.is_host
	net_start_btn.disabled = Net.peers.size() < 1
	net_leave_btn.visible = Net.active
	net_host_btn.visible = not Net.active
	net_row_join.visible = not Net.active
	var ips: Array[String] = Net.local_ips()
	if Net.active and Net.is_host:
		net_ips.text = ("ТВОЙ IP В СЕТИ: " + "  ·  ".join(PackedStringArray(ips))) if not ips.is_empty() else "IP НЕ ОПРЕДЕЛЁН"
		net_ips.text += "\nПО ИНТЕРНЕТУ: ПРОБРОСЬ UDP-ПОРТ 7777 НА ЭТОТ АДРЕС И ДАЙ ДРУЗЬЯМ ВНЕШНИЙ IP"
	elif not Net.active:
		net_ips.text = "ТОЧКА ДОСТУПА / WI-FI: ВСЕ В ОДНОЙ СЕТИ, ХОСТ СООБЩАЕТ СВОЙ IP" if ips.is_empty() else "ЭТОТ ПК: " + "  ·  ".join(PackedStringArray(ips))
	else:
		net_ips.text = ""


func show_screen(s: int) -> void:
	current = s
	for k in panels.keys():
		panels[k].visible = (k == s)
	root.visible = s != Screen.NONE
	glow_tex.visible = s == Screen.TITLE or s == Screen.DEAD
	tape_label.visible = s != Screen.NONE
	match s:
		Screen.TITLE:
			tape_label.text = "TAPE 07  ·  NO SIGNAL  ·  ▶ PLAY"
		Screen.SETTINGS:
			tape_label.text = "TAPE 07  ·  MENU  ·  SETUP"
		Screen.PAUSE:
			tape_label.text = "TAPE 07  ·  ▌▌ PAUSE"
		Screen.DEAD:
			tape_label.text = "TAPE 07  ·  ■ STOP"
		Screen.NET:
			tape_label.text = "TAPE 07  ·  LINK  ·  %s" % ("ONLINE" if Net.active else "OFFLINE")
			_net_refresh()
	if s == Screen.SETTINGS:
		_sync_widgets()
	if s == Screen.NONE:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func set_end_screen(win: bool, time_str: String, level_reached: int, kind := "") -> void:
	if kind == "fall":
		# v9: the chasm tunnel on Level 3
		end_title.text = "ПРОПАСТЬ"
		end_title.add_theme_color_override("font_color", BLOOD)
		end_sub.text = "ПОД НОГАМИ НИЧЕГО НЕ БЫЛО  ·  КАМЕРА ПАДАЛА 41 СЕКУНДУ  ·  ЗВУКА УДАРА НЕТ"
	elif kind == "run":
		# v9: the white light at the end of Level 4
		end_title.text = "ВЫ ДОБЕЖАЛИ"
		end_title.add_theme_color_override("font_color", GOOD)
		end_sub.text = "СВЕТ В КОНЦЕ ТОННЕЛЯ  ·  ЗА СПИНОЙ — ТИШИНА  ·  ПЛЁНКА СОХРАНЕНА"
	elif win:
		end_title.text = "ВЫ ВЫБРАЛИСЬ"
		end_title.add_theme_color_override("font_color", GOOD)
		end_sub.text = "ЛЮК ОТКРЫТ  ·  НАВЕРХУ — НЕБО  ·  ПЛЁНКА СОХРАНЕНА" if level_reached >= 3 else "АВАРИЙНЫЙ ВЫХОД ОТКРЫТ  ·  ПЛЁНКА СОХРАНЕНА"
	else:
		end_title.text = "ЗАПИСЬ ПРЕРВАНА"
		end_title.add_theme_color_override("font_color", BLOOD)
		end_sub.text = "СИГНАЛ ПОТЕРЯН  ·  ОПЕРАТОР НЕ ОТВЕЧАЕТ"
	stats_label.text = "ВРЕМЯ ЗАПИСИ:      %s\nДОСТИГНУТ УРОВЕНЬ: %s\nСЛОЖНОСТЬ:         %s" % [
			time_str, LevelDefs.get_def(level_reached)["name"],
			["ТУРИСТ", "СТАНДАРТ", "КОШМАР"][GameSettings.difficulty]]
	show_screen(Screen.DEAD)


func _process(delta: float) -> void:
	_flick += delta
	static_tex.modulate.a = 0.04 + 0.028 * absf(sin(_flick * 7.3)) + 0.02 * sin(_flick * 23.0)
	if current == Screen.TITLE and lurk_model != null:
		_lurk_t += delta
		lurk_model.animate(delta, 0.0, 0.15, Vector3(0, 1.5, 4.6), 0.25)
		lurk_model.rotation.y = -0.35 + sin(_lurk_t * 0.23) * 0.12
		if lurk_light != null:
			var f := 2.2
			if fmod(_lurk_t, 3.7) < 0.12 or fmod(_lurk_t, 5.3) < 0.05:
				f = randf_range(0.2, 1.0)
			lurk_light.light_energy = f
	if current == Screen.TITLE and title_big != null:
		_glitch_t -= delta
		if _glitch_t <= 0.0:
			_glitch_t = randf_range(0.8, 3.5)
			title_big.position = Vector2(randf_range(-4, 4), -10 + randf_range(-2, 2))
			title_shadow.position = Vector2(3 + randf_range(-6, 6), -8)
			title_shadow.modulate.a = randf_range(0.5, 1.0)
			get_tree().create_timer(0.08).timeout.connect(func():
					if title_big != null:
						title_big.position = Vector2(0, -10)
						title_shadow.position = Vector2(3, -8)
						title_shadow.modulate.a = 1.0)
