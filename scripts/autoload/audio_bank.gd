extends Node
## AudioBank -- loads every generated sound (OGG Vorbis; WAV also accepted), wires loops, and provides
## fire-and-forget 2D/3D playback helpers. Autoloaded as `AudioBank`.

const DIR := "res://audio/"
const LOOPED := {
	"hum.ogg": true,
	"quake.ogg": true,
	"ambience.ogg": true,
	"room_dark.ogg": true,
	"monster_breath.ogg": true,
	"nvg_whine.ogg": true,
	"lamp_buzz.ogg": true,
}

const MANIFEST := [
	"ambience.ogg",
	"quake.ogg",
	"fall_wind.ogg",
	"rock_hit_1.ogg",
	"rock_hit_2.ogg",
	"rock_hit_3.ogg",
	"breath_in.ogg",
	"breath_out.ogg",
	"brownout.ogg",
	"click.ogg",
	"collapse.ogg",
	"crate.ogg",
	"dig_1.ogg",
	"dig_2.ogg",
	"dig_3.ogg",
	"creak_1.ogg",
	"creak_2.ogg",
	"creak_3.ogg",
	"deny.ogg",
	"distant_bang.ogg",
	"door.ogg",
	"drip_1.ogg",
	"drip_2.ogg",
	"drip_3.ogg",
	"far_steps.ogg",
	"far_voices.ogg",
	"flicker.ogg",
	"fuse.ogg",
	"growl.ogg",
	"heartbeat.ogg",
	"hum.ogg",
	"hvac_surge.ogg",
	"lamp_buzz.ogg",
	"monster_breath.ogg",
	"noise_pulse.ogg",
	"nvg_whine.ogg",
	"pickup.ogg",
	"pipe_knock_1.ogg",
	"pipe_knock_2.ogg",
	"pipe_knock_3.ogg",
	"room_dark.ogg",
	"screech.ogg",
	"jumpscare_scream.ogg",
	"key_jingle.ogg",
	"spider_click_1.ogg",
	"spider_click_2.ogg",
	"spider_click_3.ogg",
	"spider_hiss.ogg",
	"spider_screech.ogg",
	"spider_step_1.ogg",
	"spider_step_2.ogg",
	"spider_step_3.ogg",
	"stairs_1.ogg",
	"stairs_2.ogg",
	"stairs_3.ogg",
	"static_burst.ogg",
	"step_crouch_1.ogg",
	"step_crouch_2.ogg",
	"step_monster_1.ogg",
	"step_monster_2.ogg",
	"step_monster_3.ogg",
	"step_run_1.ogg",
	"step_run_2.ogg",
	"step_run_3.ogg",
	"step_run_4.ogg",
	"step_walk_1.ogg",
	"step_walk_2.ogg",
	"step_walk_3.ogg",
	"step_walk_4.ogg",
	"stinger.ogg",
	"unlock.ogg",
	"whisper.ogg",
	"zap.ogg",
]

var streams := {}
var _rng := RandomNumberGenerator.new()
var _active_players: Array[AudioStreamPlayer] = []

signal bus_setup_done


func _ready() -> void:
	_rng.randomize()
	_load_all()


func _load_all() -> void:
	# In exported builds (APK / EXE) the original .wav files are NOT in the
	# pack -- the directory only lists "name.wav.import" / "name.wav.remap"
	# stubs, and load("res://audio/name.wav") resolves them through the remap.
	# So: collect names from whatever variant is present, then load by the
	# plain path. This was why mobile builds were completely silent.
	var names := {}
	var dir := DirAccess.open(DIR)
	if dir != null:
		dir.list_dir_begin()
		var fname: String = dir.get_next()
		while fname != "":
			if not dir.current_is_dir():
				var f: String = fname
				if f.ends_with(".import") or f.ends_with(".remap"):
					f = f.get_basename()
				if f.ends_with(".wav") or f.ends_with(".ogg"):
					names[f] = true
			fname = dir.get_next()
		dir.list_dir_end()
	else:
		push_error("AudioBank: cannot open " + DIR)
	# safety net: if directory listing gave nothing (some pack layouts), fall
	# back to the known manifest
	if names.is_empty():
		for f in MANIFEST:
			names[f] = true
	for k in names.keys():
		var f: String = str(k)
		var path: String = DIR + f
		if not ResourceLoader.exists(path):
			continue
		var s: Resource = load(path)
		var looped: bool = LOOPED.get(f, false) or LOOPED.get(f.get_basename() + ".wav", false)
		if s is AudioStreamWAV:
			var w := s as AudioStreamWAV
			if looped:
				w.loop_mode = AudioStreamWAV.LOOP_FORWARD
				w.loop_begin = 0
				w.loop_end = int(w.get_length() * w.mix_rate)
			streams[f.get_basename()] = w
		elif s is AudioStreamOggVorbis:
			var o := s as AudioStreamOggVorbis
			o.loop = looped
			streams[f.get_basename()] = o
		elif s != null:
			streams[f.get_basename()] = s
	if streams.is_empty():
		push_error("AudioBank: no sounds loaded from " + DIR)
	elif OS.get_environment("BR_DEBUG") == "1":
		print("DBG audio: %d streams loaded" % streams.size())


func has(sound_name: String) -> bool:
	return streams.has(sound_name)


func get_stream(sound_name: String) -> AudioStream:
	var s: AudioStream = streams.get(sound_name)
	return s


func pick(prefix: String) -> AudioStream:
	## Random variant: prefix "step_walk" -> step_walk_1..N
	var found: Array[String] = []
	for k in streams.keys():
		if k.begins_with(prefix):
			found.append(k)
	if found.is_empty():
		return null
	return streams[found[_rng.randi_range(0, found.size() - 1)]]


# ------------------------------------------------------------------ playback
func _mk2d(stream: AudioStream, volume: float, pitch: float, bus: String) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.stream = stream
	p.volume_db = linear_to_db(maxf(volume, 0.0001))
	p.pitch_scale = pitch
	p.bus = bus
	p.max_polyphony = 4
	add_child(p)
	return p


func play(sound_name: String, volume := 1.0, pitch := 1.0, bus := "SFX") -> AudioStreamPlayer:
	var s: AudioStream = streams.get(sound_name)
	if s == null:
		return null
	var p := _mk2d(s, volume, pitch, bus)
	p.finished.connect(_on_finished.bind(p))
	p.play()
	return p


func play_variant(prefix: String, volume := 1.0, pitch := 1.0, bus := "SFX") -> AudioStreamPlayer:
	var s := pick(prefix)
	if s == null:
		return null
	var p := _mk2d(s, volume, pitch, bus)
	p.finished.connect(_on_finished.bind(p))
	p.play()
	return p


func play_3d(sound_name: String, at: Vector3, volume := 1.0, pitch := 1.0,
		bus := "SFX", attenuation := 0.9) -> AudioStreamPlayer3D:
	var s: AudioStream = streams.get(sound_name)
	if s == null:
		return null
	var p := AudioStreamPlayer3D.new()
	add_child(p)
	p.stream = s
	p.global_position = at
	p.volume_db = linear_to_db(maxf(volume, 0.0001))
	p.pitch_scale = pitch
	p.bus = bus
	p.unit_size = 4.0
	p.max_db = 3.0
	p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	p.autoplay = false
	p.max_distance = 45.0
	p.finished.connect(_on_finished_3d.bind(p))
	p.play()
	return p


func play_variant_3d(prefix: String, at: Vector3, volume := 1.0, pitch := 1.0,
		bus := "SFX") -> AudioStreamPlayer3D:
	var s := pick(prefix)
	if s == null:
		return null
	var p := AudioStreamPlayer3D.new()
	add_child(p)
	p.stream = s
	p.global_position = at
	p.volume_db = linear_to_db(maxf(volume, 0.0001))
	p.pitch_scale = pitch
	p.bus = bus
	p.unit_size = 4.0
	p.max_distance = 45.0
	p.finished.connect(_on_finished_3d.bind(p))
	p.play()
	return p


func loop_2d(sound_name: String, bus := "Ambience", volume := 1.0) -> AudioStreamPlayer:
	var st: AudioStream = streams.get(sound_name)
	var p := _mk2d(st, volume, 1.0, bus)
	p.play()
	return p


func loop_3d(sound_name: String, bus := "Monster", volume := 1.0) -> AudioStreamPlayer3D:
	var s: AudioStream = streams.get(sound_name)
	if s == null:
		return null
	var p := AudioStreamPlayer3D.new()
	p.stream = s
	p.bus = bus
	p.volume_db = linear_to_db(maxf(volume, 0.0001))
	p.unit_size = 5.0
	p.max_distance = 30.0
	add_child(p)
	p.play()
	return p


func _on_finished(p: AudioStreamPlayer) -> void:
	p.queue_free()


func _on_finished_3d(p: AudioStreamPlayer3D) -> void:
	p.queue_free()
