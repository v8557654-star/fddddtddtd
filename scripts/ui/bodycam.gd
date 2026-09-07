class_name BodycamFX
extends CanvasLayer
## Full-screen bodycam post-process. Quantises the "video" clock to 24 Hz,
## drives grain / static bursts / NVG / damage / fear degradation.

var rect: ColorRect
var mat: ShaderMaterial
var clock := 0.0
var _quant := 0.0
var static_amt := 0.0
var damage := 0.0
var fear := 0.0
var fear_target := 0.0
var nvg := 0.0
var nvg_target := 0.0
var exposure := 1.0
var exposure_target := 1.0
var nvg_player: AudioStreamPlayer = null
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	layer = 50
	_rng.randomize()
	rect = ColorRect.new()
	rect.name = "BodycamFX"
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(rect)
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.set_deferred("size", get_viewport().get_visible_rect().size)
	mat = ShaderMaterial.new()
	mat.shader = load("res://shaders/bodycam.gdshader")
	rect.material = mat
	mat.set_shader_parameter("grain_tex", load("res://textures/grain.png"))
	mat.set_shader_parameter("dirt_tex", load("res://textures/lens_dirt.png"))
	mat.set_shader_parameter("static_tex", load("res://textures/static.png"))
	_apply_settings()


func _apply_settings() -> void:
	mat.set_shader_parameter("grain", 0.085 * GameSettings.grain_amount)
	mat.set_shader_parameter("scanlines", 0.14 * GameSettings.scanline_amount)
	mat.set_shader_parameter("vignette", GameSettings.vignette_amount)
	mat.set_shader_parameter("cheap", 1.0 if GameSettings.gfx_bodycam_cheap() else 0.0)
	rect.visible = GameSettings.bodycam_enabled


func burst(amount: float) -> void:
	static_amt = maxf(static_amt, amount)


func set_damage(v: float) -> void:
	damage = maxf(damage, v)


func set_fear(v: float) -> void:
	fear_target = clampf(v, 0.0, 1.0)


func set_nvg(on: bool) -> void:
	nvg_target = 1.0 if on else 0.0
	if on and nvg_player == null:
		nvg_player = AudioBank.loop_2d("nvg_whine", "SFX", 0.35)
	elif not on and nvg_player != null:
		nvg_player.stop()
		nvg_player.queue_free()
		nvg_player = null


func set_exposure(v: float) -> void:
	exposure_target = v


func _process(delta: float) -> void:
	if not GameSettings.bodycam_enabled:
		rect.visible = false
		return
	rect.visible = true

	clock += delta
	# 24 Hz video clock quantisation
	_quant = floor(clock * 24.0) / 24.0

	static_amt = maxf(static_amt - delta * 1.6, 0.0)
	damage = maxf(damage - delta * 1.4, 0.0)
	fear = lerpf(fear, fear_target, delta * 3.0)
	nvg = lerpf(nvg, nvg_target, delta * 7.0)
	exposure = lerpf(exposure, exposure_target, delta * 2.5)

	var jitter := 0.0
	if _rng.randf() < 0.06:
		jitter = _rng.randf_range(0.001, 0.006)

	var vp := get_viewport().get_visible_rect().size
	mat.set_shader_parameter("time_sec", fmod(_quant, 3600.0))
	mat.set_shader_parameter("frame_jitter", jitter)
	mat.set_shader_parameter("static_amt", static_amt)
	mat.set_shader_parameter("damage", damage)
	mat.set_shader_parameter("fear", fear)
	mat.set_shader_parameter("nvg", nvg)
	mat.set_shader_parameter("exposure", exposure)
	mat.set_shader_parameter("aspect", Vector2(vp.x / maxf(vp.y, 1.0), 1.0))
	mat.set_shader_parameter("lens_dirt", 0.55)
	_apply_settings()
