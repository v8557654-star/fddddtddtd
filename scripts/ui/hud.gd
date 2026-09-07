class_name HudUI
extends CanvasLayer
## Camcorder OSD: REC, timecode, batteries, objective, subtitles, prompts.

var font_osd: Font
var font_osd_b: Font

var rec_dot: ColorRect
var rec_label: Label
var cam_label: Label
var timecode: Label
var batt_label: Label
var flash_bar: ColorRect
var flash_bg: ColorRect
var cam_bar: ColorRect
var cam_bg: ColorRect
var stam_bar: ColorRect
var san_bar: ColorRect
var objective: Label
var level_label: Label
var prompt: Label
var subtitle: Label
var crosshair: ColorRect
var warn_label: Label
var fps_label: Label
var inv_label: Label
var radar: RadarScope
var corner_tl: ColorRect
var corner_tr: ColorRect
var corner_bl: ColorRect
var corner_br: ColorRect
var crew_label: Label          # v10: co-op roster (top left, under the CAM line)
var spec_label: Label          # v10: "SPECTATING <name>" banner

var run_time := 0.0
var flash_v := 100.0
var cam_v := 100.0
var stam_v := 100.0
var san_v := 100.0
var subtitle_t := 0.0
var prompt_text := ""
var _blink := 0.0
var _fps_acc := 0.0
var _fps_n := 0


func _ready() -> void:
	layer = 40
	font_osd = load("res://assets/fonts/osd_mono.ttf")
	font_osd_b = load("res://assets/fonts/osd_mono_bold.ttf")
	_build()


func _mk_label(txt: String, size: int, bold := false) -> Label:
	var l := Label.new()
	l.text = txt
	l.add_theme_font_override("font", font_osd_b if bold else font_osd)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", Color(0.92, 0.95, 0.92, 0.88))
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
	l.add_theme_constant_override("shadow_offset_x", 1)
	l.add_theme_constant_override("shadow_offset_y", 1)
	return l


func _build() -> void:
	var root := Control.new()
	root.name = "OSD"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	# ---- top left: REC -------------------------------------------------------
	rec_dot = ColorRect.new()
	rec_dot.color = Color(0.95, 0.08, 0.08, 0.95)
	rec_dot.size = Vector2(13, 13)
	rec_dot.position = Vector2(26, 26)
	root.add_child(rec_dot)

	rec_label = _mk_label("REC", 20, true)
	rec_label.position = Vector2(46, 18)
	root.add_child(rec_label)

	cam_label = _mk_label("CAM 02  ·  LEVEL 0  ·  ISO 6400", 13)
	cam_label.position = Vector2(26, 46)
	cam_label.add_theme_color_override("font_color", Color(0.85, 0.88, 0.85, 0.6))
	root.add_child(cam_label)

	# ---- top right: timecode --------------------------------------------------
	timecode = _mk_label("00:00:00:00", 20, true)
	timecode.position = Vector2(-260, 18)
	timecode.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	root.add_child(timecode)

	batt_label = _mk_label("BAT 100%  ●●●●●", 13)
	batt_label.position = Vector2(-260, 46)
	batt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	batt_label.add_theme_color_override("font_color", Color(0.85, 0.88, 0.85, 0.6))
	root.add_child(batt_label)

	# ---- corner brackets --------------------------------------------------------
	var bc := Color(0.9, 0.93, 0.9, 0.35)
	corner_tl = ColorRect.new(); corner_tl.color = bc; corner_tl.size = Vector2(46, 2); corner_tl.position = Vector2(20, 20); root.add_child(corner_tl)
	corner_tr = ColorRect.new(); corner_tr.color = bc; corner_tr.size = Vector2(2, 46); corner_tr.position = Vector2(20, 20); root.add_child(corner_tr)
	var c2 := ColorRect.new(); c2.color = bc; c2.size = Vector2(46, 2); c2.set_anchors_preset(Control.PRESET_TOP_RIGHT); c2.position = Vector2(-66, 20); root.add_child(c2)
	var c3 := ColorRect.new(); c3.color = bc; c3.size = Vector2(2, 46); c3.set_anchors_preset(Control.PRESET_TOP_RIGHT); c3.position = Vector2(-22, 20); root.add_child(c3)

	# ---- bottom left: batteries + vitals ----------------------------------------
	var lbl_f := _mk_label("FLASH", 12)
	lbl_f.position = Vector2(26, -96)
	lbl_f.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	lbl_f.position = Vector2(26, -96)
	root.add_child(lbl_f)
	flash_bg = ColorRect.new(); flash_bg.color = Color(1, 1, 1, 0.16); flash_bg.size = Vector2(150, 7)
	flash_bg.set_anchors_preset(Control.PRESET_BOTTOM_LEFT); flash_bg.position = Vector2(78, -91); root.add_child(flash_bg)
	flash_bar = ColorRect.new(); flash_bar.color = Color(0.95, 0.85, 0.5, 0.85); flash_bar.size = Vector2(150, 7)
	flash_bar.set_anchors_preset(Control.PRESET_BOTTOM_LEFT); flash_bar.position = Vector2(78, -91); root.add_child(flash_bar)

	var lbl_c := _mk_label("CAM", 12)
	lbl_c.set_anchors_preset(Control.PRESET_BOTTOM_LEFT); lbl_c.position = Vector2(26, -80); root.add_child(lbl_c)
	cam_bg = ColorRect.new(); cam_bg.color = Color(1, 1, 1, 0.16); cam_bg.size = Vector2(150, 7)
	cam_bg.set_anchors_preset(Control.PRESET_BOTTOM_LEFT); cam_bg.position = Vector2(78, -75); root.add_child(cam_bg)
	cam_bar = ColorRect.new(); cam_bar.color = Color(0.55, 0.85, 0.95, 0.85); cam_bar.size = Vector2(150, 7)
	cam_bar.set_anchors_preset(Control.PRESET_BOTTOM_LEFT); cam_bar.position = Vector2(78, -75); root.add_child(cam_bar)

	var lbl_s := _mk_label("STAM", 12)
	lbl_s.set_anchors_preset(Control.PRESET_BOTTOM_LEFT); lbl_s.position = Vector2(26, -64); root.add_child(lbl_s)
	stam_bar = ColorRect.new(); stam_bar.color = Color(0.8, 0.9, 0.8, 0.55); stam_bar.size = Vector2(150, 4)
	stam_bar.set_anchors_preset(Control.PRESET_BOTTOM_LEFT); stam_bar.position = Vector2(78, -60); root.add_child(stam_bar)

	var lbl_n := _mk_label("SAN", 12)
	lbl_n.set_anchors_preset(Control.PRESET_BOTTOM_LEFT); lbl_n.position = Vector2(26, -52); root.add_child(lbl_n)
	san_bar = ColorRect.new(); san_bar.color = Color(0.9, 0.5, 0.5, 0.6); san_bar.size = Vector2(150, 4)
	san_bar.set_anchors_preset(Control.PRESET_BOTTOM_LEFT); san_bar.position = Vector2(78, -48); root.add_child(san_bar)

	# ---- bottom right: objective --------------------------------------------------
	level_label = _mk_label("LEVEL 0", 15, true)
	level_label.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT); level_label.position = Vector2(-320, -64)
	level_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	level_label.custom_minimum_size = Vector2(300, 0)
	root.add_child(level_label)
	objective = _mk_label("ЦЕЛЬ: НАЙДИ ДВЕРЬ", 13)
	objective.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT); objective.position = Vector2(-420, -42)
	objective.custom_minimum_size = Vector2(400, 0)
	objective.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	objective.add_theme_color_override("font_color", Color(0.85, 0.88, 0.85, 0.62))
	root.add_child(objective)

	# ---- centre -------------------------------------------------------------------
	crosshair = ColorRect.new()
	crosshair.color = Color(1, 1, 1, 0.5)
	crosshair.size = Vector2(3, 3)
	crosshair.set_anchors_preset(Control.PRESET_CENTER)
	crosshair.position = Vector2(-1, -1)
	root.add_child(crosshair)

	prompt = _mk_label("", 16, true)
	prompt.set_anchors_preset(Control.PRESET_CENTER)
	prompt.position = Vector2(-200, 40)
	prompt.custom_minimum_size = Vector2(400, 0)
	prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	prompt.add_theme_color_override("font_color", Color(0.98, 0.95, 0.75, 0.95))
	root.add_child(prompt)

	warn_label = _mk_label("", 26, true)
	warn_label.set_anchors_preset(Control.PRESET_CENTER)
	warn_label.position = Vector2(-300, -120)
	warn_label.custom_minimum_size = Vector2(600, 0)
	warn_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	warn_label.add_theme_color_override("font_color", Color(0.95, 0.2, 0.15, 0.9))
	root.add_child(warn_label)

	subtitle = _mk_label("", 17)
	subtitle.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	subtitle.position = Vector2(0, -140)
	subtitle.custom_minimum_size = Vector2(0, 0)
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_color_override("font_color", Color(0.9, 0.9, 0.85, 0.85))
	root.add_child(subtitle)

	fps_label = _mk_label("", 12)
	fps_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	fps_label.position = Vector2(26, 70)
	root.add_child(fps_label)

	inv_label = _mk_label("", 13, true)
	inv_label.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	inv_label.position = Vector2(26, -130)
	inv_label.add_theme_color_override("font_color", Color(0.98, 0.95, 0.75, 0.85))
	root.add_child(inv_label)

	# ---- v10: co-op roster / spectator banner ----------------------------------
	crew_label = _mk_label("", 12)
	crew_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	crew_label.position = Vector2(26, 92)
	crew_label.add_theme_color_override("font_color", Color(0.85, 0.88, 0.85, 0.7))
	root.add_child(crew_label)
	spec_label = _mk_label("", 18, true)
	spec_label.set_anchors_preset(Control.PRESET_CENTER)
	spec_label.anchor_left = 0.0
	spec_label.anchor_right = 1.0
	spec_label.offset_left = 0
	spec_label.offset_right = 0
	spec_label.offset_top = -300
	spec_label.offset_bottom = -260
	spec_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	spec_label.add_theme_color_override("font_color", Color(0.93, 0.78, 0.36, 0.9))
	root.add_child(spec_label)

	# ---- top right: exit beacon scope (below the corner brackets) --------------------
	radar = RadarScope.new()
	radar.font = font_osd
	radar.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	radar.position = Vector2(-150, 78)
	radar.size = Vector2(130, 132)
	radar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(radar)

	# subtitle centring hack: full width
	subtitle.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	subtitle.offset_left = 0
	subtitle.offset_right = 0
	subtitle.anchor_right = 1.0
	subtitle.offset_top = -150
	subtitle.offset_bottom = -110


func set_radar(rel: Vector2, dist: float, locked: bool, on: bool) -> void:
	## rel = door offset in the player's frame (x right, y forward), metres.
	radar.visible = on
	radar.rel = rel
	radar.dist = dist
	radar.locked = locked


func set_prompt(t: String) -> void:
	prompt_text = t
	if t == "":
		prompt.text = ""
	else:
		# phones have no E key: point at the on-screen button instead
		var key := "[ВЗАИМ.]" if GameSettings.control_mode == "mob" else "[E]"
		prompt.text = key + "  " + t


func show_subtitle(t: String, dur := 4.0) -> void:
	if not GameSettings.subtitles:
		return
	subtitle.text = t
	subtitle_t = dur


func set_warning(t: String) -> void:
	warn_label.text = t


func set_inventory(water: int, battery: int, key: int = 0) -> void:
	if water == 0 and battery == 0 and key == 0:
		inv_label.text = "[TAB] РЮКЗАК ПУСТ"
		inv_label.modulate.a = 0.5
	else:
		inv_label.text = "[TAB] ВОДА ×%d   БАТАРЕИ ×%d" % [water, battery]
		if key > 0:
			inv_label.text += "   КЛЮЧ"
		inv_label.modulate.a = 1.0


func set_level(name: String, obj: String) -> void:
	level_label.text = name
	objective.text = obj
	cam_label.text = "CAM 02  ·  %s  ·  ISO 6400" % name
	run_time = run_time   # timecode keeps counting across levels


func set_objective(obj: String) -> void:
	objective.text = obj


func set_crew(lines: Array) -> void:
	## v10: one line per operator ("● ИМЯ" alive / "■ ИМЯ" tape stopped)
	crew_label.text = "\n".join(PackedStringArray(lines))


func set_spectating(t: String) -> void:
	spec_label.text = t


func set_batteries(f: float, c: float) -> void:
	flash_v = f
	cam_v = c


func set_vitals(stam: float, san: float) -> void:
	stam_v = stam
	san_v = san


func _process(delta: float) -> void:
	run_time += delta
	_blink += delta
	var on := fmod(_blink, 1.1) < 0.65
	rec_dot.visible = on
	rec_label.add_theme_color_override("font_color", Color(0.95, 0.3, 0.3, 0.95) if on else Color(0.6, 0.6, 0.6, 0.6))

	var secs := int(run_time)
	var fr := int(fmod(run_time, 1.0) * 24)
	timecode.text = "%02d:%02d:%02d:%02d" % [secs / 3600, (secs / 60) % 60, secs % 60, fr]
	var cells := int(round(cam_v / 20.0))
	var dots := ""
	for i in range(5):
		dots += "●" if i < cells else "○"
	batt_label.text = "BAT %03d%%  %s" % [int(cam_v), dots]

	flash_bar.size.x = 150.0 * flash_v / 100.0
	flash_bar.color = Color(0.95, 0.85, 0.5, 0.85) if flash_v > 25 else Color(0.95, 0.3, 0.25, 0.9)
	cam_bar.size.x = 150.0 * cam_v / 100.0
	stam_bar.size.x = 150.0 * stam_v / 100.0
	san_bar.size.x = 150.0 * san_v / 100.0
	san_bar.color = Color(0.9, 0.5, 0.5, 0.6) if san_v > 35 else Color(0.95, 0.15, 0.12, 0.85)

	if subtitle_t > 0.0:
		subtitle_t -= delta
		if subtitle_t <= 0.0:
			subtitle.text = ""

	if GameSettings.show_fps:
		_fps_acc += delta
		_fps_n += 1
		if _fps_acc > 0.5:
			fps_label.text = "%d FPS" % int(_fps_n / _fps_acc)
			_fps_acc = 0.0
			_fps_n = 0
	else:
		fps_label.text = ""



# ---------------------------------------------------------------------------
#  Exit beacon scope: a little camcorder-style direction finder. A sweep
#  runs round the dial; the exit shows as a blip (bearing = direction, radius
#  = distance, log-scaled) that only refreshes when the sweep passes over it,
#  and jitters more the farther away it is -- so it points, but does not lead
#  you by the hand.
# ---------------------------------------------------------------------------
class RadarScope extends Control:
	var font: Font
	var rel := Vector2(0, 1)
	var dist := 10.0
	var locked := false
	var _t := 0.0
	var _sweep := 0.0
	var _blip := Vector2.ZERO        # last "sampled" blip position (px)
	var _blip_age := 9.0
	var _seen_angle := 0.0
	var _rng := RandomNumberGenerator.new()
	const R := 44.0
	const MAX_D := 90.0

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		_rng.randomize()

	func _process(delta: float) -> void:
		_t += delta
		_blip_age += delta
		var prev := _sweep
		_sweep = fmod(_sweep + delta * 1.35, TAU)
		# bearing: 0 = straight ahead, clockwise; screen: up = forward
		var ang := atan2(rel.x, maxf(rel.y, -999.0))
		if rel.length() < 0.05:
			ang = 0.0
		var a := fposmod(ang, TAU)
		var crossed := (prev <= a and a < _sweep) or (_sweep < prev and (a >= prev or a < _sweep))
		if crossed or _blip_age > 6.0:
			var d := clampf(dist, 0.0, MAX_D)
			var rr := R * (0.12 + 0.88 * log(1.0 + d) / log(1.0 + MAX_D))
			var jit := deg_to_rad(lerpf(2.0, 16.0, clampf(d / MAX_D, 0.0, 1.0)))
			var ja := ang + _rng.randf_range(-jit, jit)
			_blip = Vector2(sin(ja), -cos(ja)) * rr
			_seen_angle = ja
			_blip_age = 0.0
		queue_redraw()

	func _draw() -> void:
		var c := Vector2(size.x * 0.5, R + 6.0)
		var ink := Color(0.62, 0.95, 0.66, 0.55)
		var dim := Color(0.62, 0.95, 0.66, 0.16)
		# dial
		draw_arc(c, R, 0.0, TAU, 48, ink, 1.2, true)
		draw_arc(c, R * 0.55, 0.0, TAU, 32, dim, 1.0, true)
		for i in range(12):
			var an := i * TAU / 12.0
			var v := Vector2(sin(an), -cos(an))
			var l := 6.0 if i % 3 == 0 else 3.0
			draw_line(c + v * (R - l), c + v * R, ink if i % 3 == 0 else dim, 1.0, true)
		draw_line(c + Vector2(0, -R * 0.55), c + Vector2(0, R * 0.55), dim, 1.0, true)
		draw_line(c + Vector2(-R * 0.55, 0), c + Vector2(R * 0.55, 0), dim, 1.0, true)
		# heading mark (you, looking up)
		draw_polygon(PackedVector2Array([c + Vector2(0, -6), c + Vector2(-4, 4), c + Vector2(4, 4)]), PackedColorArray([Color(0.9, 0.95, 0.9, 0.8)]))
		# sweep with a fading tail
		for k in range(10):
			var sa := _sweep - k * 0.09
			var sv := Vector2(sin(sa), -cos(sa))
			var col := Color(0.55, 1.0, 0.6, 0.30 * (1.0 - k / 10.0))
			draw_line(c, c + sv * R, col, 1.6 if k == 0 else 1.0, true)
		# blip: bright when just refreshed, decays until the next pass
		var fade := clampf(1.0 - _blip_age / 4.6, 0.12, 1.0)
		var bc := Color(1.0, 0.55, 0.25, fade) if locked else Color(0.55, 1.0, 0.6, fade)
		draw_circle(c + _blip, 3.2, bc)
		draw_arc(c + _blip, 6.0 + (1.0 - fade) * 5.0, 0.0, TAU, 20, Color(bc.r, bc.g, bc.b, fade * 0.45), 1.0, true)
		# readout
		if font != null:
			var txt := "ВЫХОД %d м" % int(round(dist))
			draw_string(font, Vector2(0, R * 2 + 24), txt, HORIZONTAL_ALIGNMENT_CENTER, size.x, 11, Color(0.85, 0.9, 0.85, 0.7))
			var sub := "ЗАБЛОКИРОВАН" if locked else "ПЕЛЕНГ"
			var sc := Color(1.0, 0.5, 0.3, 0.7) if locked else Color(0.85, 0.9, 0.85, 0.35)
			draw_string(font, Vector2(0, R * 2 + 38), sub, HORIZONTAL_ALIGNMENT_CENTER, size.x, 9, sc)
