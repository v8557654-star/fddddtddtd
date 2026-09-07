extends Node
## GameSettings -- persistent configuration + audio bus routing.
## Autoloaded as `GameSettings`.

const SAVE_PATH := "user://settings.cfg"

# --- audio ---
var master_volume := 0.85
var sfx_volume := 0.9
var ambience_volume := 0.75
var monster_volume := 0.9

# --- controls ---
var mouse_sensitivity := 0.0021
var invert_y := false
var head_bob_enabled := true
var head_bob_strength := 1.0

# --- video ---
var fov := 74.0
var bodycam_enabled := true
var grain_amount := 1.0
var scanline_amount := 1.0
var vignette_amount := 1.0
var volumetric_fog := false
var shadow_quality := 1          # 0 off, 1 low, 2 high
var max_active_lights := 10
var view_distance := 60.0
var graphics := 1                # 0 low, 1 normal, 2 high, 3 ultra
var _graphics_auto_done := false

# --- gameplay ---
var difficulty := 1              # 0 = tourist, 1 = standard, 2 = nightmare
var level_seed := -1             # -1 => random each run
var subtitles := true
var control_mode := "pc"        # "pc" | "mob"
var touch_sensitivity := 0.0045
var grace_minutes := 3.0
var stalker_events := true
var jumpscares := true
var show_fps := false
var net_nick := ""               # v10: co-op call sign
var net_last_ip := ""            # v10: last host address typed in

# --- graphics preset table -------------------------------------------------
# One knob drives everything expensive. Values are looked up by `graphics`.
const GFX_NAMES := ["НИЗКАЯ", "НОРМАЛЬНАЯ", "ВЫСОКАЯ", "УЛЬТРА"]

func gfx_scale() -> float:            # 3D render scale (viewport resolution)
	return [0.6, 0.85, 1.0, 1.0][clampi(graphics, 0, 3)]

func gfx_msaa() -> int:               # Viewport.MSAA_*
	return [0, 0, 2, 3][clampi(graphics, 0, 3)]   # off / off / 4x / 8x

func gfx_fxaa() -> bool:
	return graphics == 1

func gfx_ssao() -> bool:
	return graphics >= 2

func gfx_glow() -> bool:
	return graphics >= 1

func gfx_volumetric() -> bool:
	return graphics >= 3

func gfx_flash_shadows() -> bool:
	return graphics >= 1

func gfx_shadow_size() -> int:        # atlas size for the flashlight
	return [1024, 2048, 4096, 4096][clampi(graphics, 0, 3)]

func gfx_light_range_mul() -> float:  # ceiling lamp radius multiplier
	return [0.7, 0.9, 1.0, 1.1][clampi(graphics, 0, 3)]

func gfx_lamp_density() -> float:     # fraction of lamp positions that get a real light
	return [0.55, 0.8, 1.0, 1.0][clampi(graphics, 0, 3)]

func gfx_far() -> float:
	return [55.0, 80.0, 120.0, 160.0][clampi(graphics, 0, 3)]

func gfx_max_fps() -> int:
	return [60, 0, 0, 0][clampi(graphics, 0, 3)]

func gfx_bodycam_cheap() -> bool:     # simplified post shader
	return graphics == 0

func is_mobile_os() -> bool:
	return OS.get_name() in ["Android", "iOS"]


func auto_detect_graphics() -> void:
	# first launch only: phones start on LOW, everything else on NORMAL
	if _graphics_auto_done:
		return
	_graphics_auto_done = true
	if is_mobile_os():
		graphics = 0
		control_mode = "mob"
	elif OS.get_name() == "Web":
		graphics = 0


# --- gameplay derived difficulty table ---
func monster_speed() -> float:
	return [3.6, 4.95, 6.0][clampi(difficulty, 0, 2)]

func monster_hear_radius() -> float:
	return [7.0, 11.0, 15.0][clampi(difficulty, 0, 2)]

func monster_sight_range() -> float:
	return [9.0, 13.0, 17.0][clampi(difficulty, 0, 2)]

func sanity_drain() -> float:
	return [0.55, 0.85, 1.3][clampi(difficulty, 0, 2)]


func _ready() -> void:
	if OS.has_feature("mobile") or OS.has_feature("android") or OS.has_feature("ios"):
		control_mode = "mob"
	for k in PROPS:
		_defaults[k] = get(k)
	load_settings()
	auto_detect_graphics()
	_build_audio_buses()
	apply_audio()


func _build_audio_buses() -> void:
	# Bus 0 is always Master.
	var names := ["SFX", "Ambience", "Monster", "UI", "Jumpscare"]
	for bn in names:
		if AudioServer.get_bus_index(bn) == -1:
			AudioServer.add_bus()
			AudioServer.set_bus_name(AudioServer.bus_count - 1, bn)
	for bn in names:
		var idx := AudioServer.get_bus_index(bn)
		if idx != -1:
			AudioServer.set_bus_send(idx, &"Master")
	# Jumpscare: hot bus for the kill scream. +6 dB into a hard limiter so it
	# is as loud as the output can go without clipping into garbage.
	var ji := AudioServer.get_bus_index("Jumpscare")
	if ji != -1 and AudioServer.get_bus_effect_count(ji) == 0:
		AudioServer.set_bus_volume_db(ji, 6.0)
		var lim := AudioEffectLimiter.new()
		lim.ceiling_db = -0.1
		lim.threshold_db = -0.5
		lim.soft_clip_db = 2.0
		AudioServer.add_bus_effect(ji, lim)


func apply_audio() -> void:
	AudioServer.set_bus_volume_db(0, linear_to_db(master_volume))
	_set_bus("SFX", sfx_volume)
	_set_bus("Ambience", ambience_volume)
	_set_bus("Monster", monster_volume)
	_set_bus("UI", sfx_volume)


func _set_bus(bus_name: String, lin: float) -> void:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx != -1:
		AudioServer.set_bus_volume_db(idx, linear_to_db(maxf(lin, 0.0001)))


const PROPS := ["master_volume", "sfx_volume", "ambience_volume", "monster_volume",
		"mouse_sensitivity", "invert_y", "head_bob_enabled", "head_bob_strength",
		"fov", "bodycam_enabled", "grain_amount", "scanline_amount", "vignette_amount",
		"volumetric_fog", "shadow_quality", "max_active_lights", "view_distance", "graphics", "_graphics_auto_done",
		"difficulty", "level_seed", "subtitles", "show_fps",
		"grace_minutes", "stalker_events", "jumpscares",
		"control_mode", "touch_sensitivity", "net_nick", "net_last_ip"]

var _defaults := {}


func reset_defaults() -> void:
	for k in _defaults.keys():
		set(k, _defaults[k])


func save_settings() -> void:
	var f := ConfigFile.new()
	for prop in ["master_volume", "sfx_volume", "ambience_volume", "monster_volume",
			"mouse_sensitivity", "invert_y", "head_bob_enabled", "head_bob_strength",
			"fov", "bodycam_enabled", "grain_amount", "scanline_amount", "vignette_amount",
			"volumetric_fog", "shadow_quality", "max_active_lights", "view_distance", "graphics", "_graphics_auto_done",
			"difficulty", "level_seed", "subtitles", "show_fps",
			"grace_minutes", "stalker_events", "jumpscares",
			"control_mode", "touch_sensitivity", "net_nick", "net_last_ip"]:
		f.set_value("settings", prop, get(prop))
	f.save(SAVE_PATH)


func load_settings() -> void:
	var f := ConfigFile.new()
	if f.load(SAVE_PATH) != OK:
		return
	for prop in ["master_volume", "sfx_volume", "ambience_volume", "monster_volume",
			"mouse_sensitivity", "invert_y", "head_bob_enabled", "head_bob_strength",
			"fov", "bodycam_enabled", "grain_amount", "scanline_amount", "vignette_amount",
			"volumetric_fog", "shadow_quality", "max_active_lights", "view_distance", "graphics", "_graphics_auto_done",
			"difficulty", "level_seed", "subtitles", "show_fps",
			"grace_minutes", "stalker_events", "jumpscares",
			"control_mode", "touch_sensitivity", "net_nick", "net_last_ip"]:
		if f.has_section_key("settings", prop):
			set(prop, f.get_value("settings", prop))
