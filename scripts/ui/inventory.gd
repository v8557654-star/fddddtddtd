class_name InventoryUI
extends CanvasLayer
## Backpack. Opened with Tab, styled like the other VHS menus. Two slots
## (almond water / batteries) with counts; click a card or press 1 / 2 to use
## the item. The game pauses while it is open.

signal closed
signal used(kind: String)

const TEXT := Color(0.9, 0.89, 0.83)
const TEXT_DIM := Color(0.62, 0.61, 0.55)
const ACCENT := Color(0.93, 0.78, 0.35)
const BLOOD := Color(0.8, 0.12, 0.1)
const GOOD := Color(0.5, 0.85, 0.5)

const ITEMS := [
	{"id": "water", "key": "1", "name": "МИНДАЛЬНАЯ ВОДА", "desc": "Рассудок +38 · выносливость +40",
		"col": Color(0.7, 0.85, 1.0)},
	{"id": "battery", "key": "2", "name": "БАТАРЕЯ", "desc": "Фонарь +55% · камера +35%",
		"col": Color(0.35, 1.0, 0.45)},
	{"id": "key", "key": "3", "name": "РЖАВЫЙ КЛЮЧ", "desc": "Квестовый · применяется у двери",
		"col": Color(0.85, 0.65, 0.3)},
]

var counts := {"water": 0, "battery": 0, "key": 0}
var is_open := false

var font_osd: Font
var font_osd_b: Font
var root: Control
var cards := {}
var count_labels := {}
var status_lbl: Label
var vitals_lbl: Label
var hint_lbl: Label
var close_btn: Button
var _t := 0.0
var _flash := {}


func _ready() -> void:
	layer = 45
	process_mode = Node.PROCESS_MODE_ALWAYS
	font_osd = load("res://assets/fonts/osd_mono.ttf")
	font_osd_b = load("res://assets/fonts/osd_mono_bold.ttf")
	_build()
	root.visible = false


func _lbl(txt: String, size: int, col := TEXT, bold := false) -> Label:
	var l := Label.new()
	l.text = txt
	l.add_theme_font_override("font", font_osd_b if bold else font_osd)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.7))
	l.add_theme_constant_override("shadow_offset_x", 1)
	l.add_theme_constant_override("shadow_offset_y", 1)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _build() -> void:
	root = Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(root)

	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.62)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(dim)

	# scanline stripe overlay (cheap: a few thin rects)
	for i in range(0, 720, 6):
		var s := ColorRect.new()
		s.color = Color(0, 0, 0, 0.12)
		s.anchor_right = 1.0
		s.offset_top = i
		s.offset_bottom = i + 2
		s.mouse_filter = Control.MOUSE_FILTER_IGNORE
		root.add_child(s)

	var panel := Control.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(760, 420)
	panel.position = Vector2(-380, -210)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(panel)

	var bg := ColorRect.new()
	bg.color = Color(0.03, 0.03, 0.035, 0.94)
	bg.size = Vector2(760, 420)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(bg)
	for e in [[0, 0, 760, 2], [0, 418, 760, 2], [0, 0, 2, 420], [758, 0, 2, 420]]:
		var ln := ColorRect.new()
		ln.color = Color(0.5, 0.47, 0.36, 0.45)
		ln.position = Vector2(e[0], e[1])
		ln.size = Vector2(e[2], e[3])
		ln.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_child(ln)

	var tape := _lbl("TAPE 07  ·  ▌▌ PAUSE  ·  INVENTORY", 12, TEXT_DIM)
	tape.position = Vector2(22, 14)
	panel.add_child(tape)
	var title := _lbl("РЮКЗАК", 34, ACCENT, true)
	title.position = Vector2(22, 34)
	panel.add_child(title)
	# close button (top-right of the panel). On touch screens this is the only
	# way out -- the touch overlay sits under this layer -- so it is big.
	close_btn = Button.new()
	close_btn.text = "✕  ЗАКРЫТЬ"
	close_btn.focus_mode = Control.FOCUS_NONE
	close_btn.custom_minimum_size = Vector2(150, 48)
	close_btn.position = Vector2(760 - 22 - 150, 26)
	close_btn.add_theme_font_override("font", font_osd_b)
	close_btn.add_theme_font_size_override("font_size", 15)
	close_btn.add_theme_color_override("font_color", TEXT)
	close_btn.add_theme_color_override("font_hover_color", Color(0.05, 0.05, 0.05))
	close_btn.add_theme_color_override("font_pressed_color", Color(0.05, 0.05, 0.05))
	var cst := StyleBoxFlat.new()
	cst.bg_color = Color(0.08, 0.08, 0.085, 0.95)
	cst.border_color = Color(0.5, 0.47, 0.36, 0.5)
	cst.set_border_width_all(1)
	close_btn.add_theme_stylebox_override("normal", cst)
	var csth := cst.duplicate()
	csth.bg_color = ACCENT
	csth.border_color = ACCENT
	close_btn.add_theme_stylebox_override("hover", csth)
	close_btn.add_theme_stylebox_override("pressed", csth)
	close_btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	close_btn.mouse_entered.connect(func(): AudioBank.play("click", 0.2, 1.4, "UI"))
	close_btn.pressed.connect(close)
	panel.add_child(close_btn)

	# tapping the dimmed area outside the panel also closes (handy on phones)
	root.gui_input.connect(func(ev: InputEvent):
		if (ev is InputEventScreenTouch and ev.pressed) \
				or (ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT):
			close())

	var under := ColorRect.new()
	under.color = Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.6)
	under.position = Vector2(22, 84)
	under.size = Vector2(716, 1)
	under.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(under)

	for i in range(ITEMS.size()):
		var it: Dictionary = ITEMS[i]
		var card := Button.new()
		card.custom_minimum_size = Vector2(228, 190)
		card.position = Vector2(22 + i * 244, 104)
		card.text = ""
		card.focus_mode = Control.FOCUS_NONE
		var st := StyleBoxFlat.new()
		st.bg_color = Color(0.06, 0.06, 0.065, 0.9)
		st.border_color = Color(0.5, 0.47, 0.36, 0.3)
		st.set_border_width_all(1)
		st.border_width_left = 4
		card.add_theme_stylebox_override("normal", st)
		var sth := st.duplicate()
		sth.bg_color = Color(0.16, 0.13, 0.06, 0.95)
		sth.border_color = ACCENT
		card.add_theme_stylebox_override("hover", sth)
		card.add_theme_stylebox_override("pressed", sth)
		card.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		card.add_theme_stylebox_override("disabled", st)
		card.mouse_entered.connect(func(): AudioBank.play("click", 0.2, 1.4, "UI"))
		card.pressed.connect(func(): use_item(it["id"]))
		panel.add_child(card)
		cards[it["id"]] = card

		var key := _lbl("[%s]" % it["key"], 14, TEXT_DIM, true)
		key.position = Vector2(16, 12)
		card.add_child(key)
		var nm := _lbl(it["name"], 16, TEXT, true)
		nm.position = Vector2(16, 34)
		card.add_child(nm)
		var ds := _lbl(it["desc"], 10, TEXT_DIM)
		ds.position = Vector2(16, 62)
		card.add_child(ds)

		# icon: simple silhouettes
		var icon := Control.new()
		icon.position = Vector2(186, 118)
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		card.add_child(icon)
		var c: Color = it["col"]
		if it["id"] == "water":
			for r in [[-10, -30, 20, 60], [-5, -40, 10, 12]]:
				var rc := ColorRect.new()
				rc.color = c
				rc.position = Vector2(r[0], r[1])
				rc.size = Vector2(r[2], r[3])
				rc.mouse_filter = Control.MOUSE_FILTER_IGNORE
				icon.add_child(rc)
			var lab := ColorRect.new()
			lab.color = Color(0.12, 0.12, 0.14)
			lab.position = Vector2(-8, -12)
			lab.size = Vector2(16, 22)
			lab.mouse_filter = Control.MOUSE_FILTER_IGNORE
			icon.add_child(lab)
		elif it["id"] == "key":
			# bow (ring), shaft, two teeth
			for r in [[-14, -34, 18, 18], [-9, -29, 8, 8], [-8, -16, 6, 44], [-2, 16, 10, 5], [-2, 24, 7, 5]]:
				var rc := ColorRect.new()
				rc.color = Color(0.12, 0.12, 0.14) if (r[2] == 8 and r[3] == 8) else c
				rc.position = Vector2(r[0], r[1])
				rc.size = Vector2(r[2], r[3])
				rc.mouse_filter = Control.MOUSE_FILTER_IGNORE
				icon.add_child(rc)
		else:
			for r in [[-12, -26, 24, 52], [-5, -32, 10, 6]]:
				var rc := ColorRect.new()
				rc.color = Color(0.25, 0.25, 0.27) if r[3] > 10 else c
				rc.position = Vector2(r[0], r[1])
				rc.size = Vector2(r[2], r[3])
				rc.mouse_filter = Control.MOUSE_FILTER_IGNORE
				icon.add_child(rc)
			var band := ColorRect.new()
			band.color = c
			band.position = Vector2(-12, -4)
			band.size = Vector2(24, 10)
			band.mouse_filter = Control.MOUSE_FILTER_IGNORE
			icon.add_child(band)

		var cnt := _lbl("× 0", 30, ACCENT, true)
		cnt.position = Vector2(16, 130)
		card.add_child(cnt)
		count_labels[it["id"]] = cnt
		var use := _lbl("НАЖМИ, ЧТОБЫ ИСПОЛЬЗОВАТЬ" if it["id"] != "key" else "ИСПОЛЬЗУЕТСЯ У ДВЕРИ", 10, TEXT_DIM)
		use.position = Vector2(16, 170)
		card.add_child(use)

	vitals_lbl = _lbl("", 13, TEXT_DIM)
	vitals_lbl.position = Vector2(22, 312)
	panel.add_child(vitals_lbl)
	status_lbl = _lbl("", 14, GOOD, true)
	status_lbl.position = Vector2(22, 338)
	panel.add_child(status_lbl)

	var sep := ColorRect.new()
	sep.color = Color(0.5, 0.47, 0.36, 0.3)
	sep.position = Vector2(22, 372)
	sep.size = Vector2(716, 1)
	sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(sep)
	hint_lbl = _lbl("TAB / ESC — закрыть    ·    1 / 2 / 3 или клик — использовать    ·    E у предмета — положить в рюкзак", 12, TEXT_DIM)
	hint_lbl.position = Vector2(22, 386)
	panel.add_child(hint_lbl)


# ------------------------------------------------------------------ API
func add(kind: String, n := 1) -> void:
	counts[kind] = int(counts.get(kind, 0)) + n
	_refresh()


func total() -> int:
	var t := 0
	for k in counts:
		t += int(counts[k])
	return t


func open() -> void:
	if is_open:
		return
	is_open = true
	root.visible = true
	status_lbl.text = ""
	if GameSettings.control_mode == "mob":
		hint_lbl.text = "✕ / тап вне окна — закрыть    ·    тап по карточке — использовать    ·    ВЗАИМ. — подобрать"
	else:
		hint_lbl.text = "TAB / ESC / ✕ — закрыть    ·    1 / 2 / 3 или клик — использовать    ·    E у предмета — положить в рюкзак"
	_refresh()
	AudioBank.play("click", 0.5, 0.9, "UI")
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func close() -> void:
	if not is_open:
		return
	is_open = false
	root.visible = false
	AudioBank.play("click", 0.4, 0.8, "UI")
	closed.emit()


func set_vitals(sanity: float, stamina: float, flash: float, cam: float) -> void:
	vitals_lbl.text = "РАССУДОК %3d%%   ВЫНОСЛИВОСТЬ %3d%%   ФОНАРЬ %3d%%   КАМЕРА %3d%%" % [
		int(sanity), int(stamina), int(flash), int(cam)]


func use_item(kind: String) -> void:
	if int(counts.get(kind, 0)) <= 0:
		AudioBank.play("deny", 0.6, 1.0, "UI")
		status_lbl.add_theme_color_override("font_color", BLOOD)
		status_lbl.text = "ПУСТО"
		return
	if kind == "key":
		AudioBank.play("key_jingle", 0.5, 1.1, "UI")
		status_lbl.add_theme_color_override("font_color", ACCENT)
		status_lbl.text = "КЛЮЧ ПРИМЕНЯЕТСЯ У ЗАПЕРТОЙ ДВЕРИ (E)"
		_flash[kind] = 0.35
		return
	counts[kind] = int(counts[kind]) - 1
	_flash[kind] = 0.35
	used.emit(kind)
	status_lbl.add_theme_color_override("font_color", GOOD)
	status_lbl.text = "ИСПОЛЬЗОВАНО: " + ("МИНДАЛЬНАЯ ВОДА" if kind == "water" else "БАТАРЕЯ")
	_refresh()


func _refresh() -> void:
	for k in cards:
		var n := int(counts.get(k, 0))
		count_labels[k].text = "× %d" % n
		count_labels[k].add_theme_color_override("font_color", ACCENT if n > 0 else TEXT_DIM)
		cards[k].modulate = Color(1, 1, 1, 1.0 if n > 0 else 0.55)


func _process(delta: float) -> void:
	if not is_open:
		return
	_t += delta
	for k in _flash.keys():
		_flash[k] -= delta
		var c: Control = cards[k]
		c.modulate = Color(1.4, 1.3, 1.0, 1.0) if _flash[k] > 0.0 else Color(1, 1, 1, 1.0 if int(counts[k]) > 0 else 0.55)
		if _flash[k] <= 0.0:
			_flash.erase(k)
	hint_lbl.modulate.a = 0.75 + 0.25 * sin(_t * 2.0)


func _unhandled_input(event: InputEvent) -> void:
	if not is_open:
		return
	if event.is_action_pressed("inventory") or event.is_action_pressed("pause"):
		close()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("slot_1"):
		use_item("water")
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("slot_2"):
		use_item("battery")
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("slot_3"):
		use_item("key")
		get_viewport().set_input_as_handled()
