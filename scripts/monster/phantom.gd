class_name Phantom
extends Node3D
## Hallucination director. Spawns a *fake* copy of the creature that:
##   PEEK    - leans out from behind a corner ahead of you; when you look at
##             it, it either blinks out or "charges" you...
##   CHARGE  - ...sprinting straight at the camera and dissolving 1-2 m away.
##   BEHIND  - materialises right behind your back with a growl; turn around
##             and it's gone (or it charges).
##   GLIMPSE - stands motionless far down a corridor in your peripheral view.
## Also fires audio-only scares (growl behind your ear, footsteps that stop).
## Runs on every level; frequency scales with LevelDefs "intensity".

signal scare(kind: String)         # for HUD / bodycam FX
signal jumpscare                   # full-screen flash

enum Mode { IDLE, PEEK, CHARGE, BEHIND, GLIMPSE }

const CELL_STEP := 0.8

var level: Node = null
var player: Player = null
var model: MonsterModel = null
var mode: int = Mode.IDLE
var intensity := 1.0
var enabled := true
var rng := RandomNumberGenerator.new()

var _cd := 30.0
var _t := 0.0
var _peek_side := 1.0
var _peek_base := Vector3.ZERO
var _peek_dir := Vector3.ZERO
var _seen_t := 0.0
var _charge_from := Vector3.ZERO
var _will_charge := false
var _fade := 0.0
var _alpha := 1.0
var _steps_t := 0.0


func _ready() -> void:
	rng.randomize()
	model = MonsterModel.new()
	model.name = "PhantomModel"
	add_child(model)
	visible = false
	_cd = rng.randf_range(20.0, 40.0)


func setup(lvl: Node, pl: Player, inten: float) -> void:
	level = lvl
	player = pl
	intensity = inten
	_cd = rng.randf_range(14.0, 30.0) / maxf(intensity, 0.1)


func _process(delta: float) -> void:
	if player == null or level == null or not player.alive:
		return
	match mode:
		Mode.IDLE:
			if not enabled:
				return
			_cd -= delta * intensity
			if _cd <= 0.0:
				_start_random()
		Mode.PEEK:
			_tick_peek(delta)
		Mode.CHARGE:
			_tick_charge(delta)
		Mode.BEHIND:
			_tick_behind(delta)
		Mode.GLIMPSE:
			_tick_glimpse(delta)
	if _fade > 0.0:
		_fade -= delta * 2.2
		_alpha = clampf(_fade, 0.0, 1.0)
		model.set_transparency(_alpha)
		if _fade <= 0.0:
			_end()


# ----------------------------------------------------------------- helpers
func _cam() -> Camera3D:
	return player.camera


func _fwd() -> Vector3:
	var f := -_cam().global_transform.basis.z
	f.y = 0.0
	return f.normalized() if f.length() > 0.05 else Vector3(0, 0, -1)


func _player_looking_at(p: Vector3, half_angle_deg := 28.0) -> bool:
	var to := (p + Vector3(0, 1.6, 0)) - _cam().global_position
	if to.length() > 40.0:
		return false
	var f := -_cam().global_transform.basis.z
	if f.dot(to.normalized()) < cos(deg_to_rad(half_angle_deg)):
		return false
	# LOS through the coarse grid
	var steps := int(to.length() / 0.6)
	var d := to.normalized()
	for i in range(1, steps):
		var q := _cam().global_position + d * (0.6 * i)
		if level.is_wall_at(Vector3(q.x, 1.2, q.z)):
			return false
	return true


func _free_near(p: Vector3) -> Vector3:
	var g = level.data.world_to_grid(p)
	g = level._nearest_free(level._clamp_grid(g))
	return level.data.grid_to_world(g)


func _show_at(p: Vector3, face_player := true) -> void:
	global_position = p
	if face_player:
		var to := player.global_position - p
		rotation.y = atan2(to.x, to.z)
	model.set_transparency(1.0)
	_alpha = 1.0
	_fade = 0.0
	visible = true


func _end() -> void:
	visible = false
	model.rotation.z = 0.0
	mode = Mode.IDLE
	_cd = rng.randf_range(18.0, 45.0) / maxf(intensity, 0.1)


func _dissolve(kind: String) -> void:
	scare.emit(kind)
	AudioBank.play_variant_3d("static_burst", global_position, 0.6, 1.0, "Monster")
	_fade = 1.0


func _random_event_choice() -> int:
	var r := rng.randf()
	if r < 0.44:
		return Mode.PEEK
	if r < 0.66:
		return Mode.BEHIND
	if r < 0.84:
		return Mode.GLIMPSE
	return -1   # audio only


func _start_random() -> void:
	var m := _random_event_choice()
	match m:
		Mode.PEEK:
			if not _start_peek():
				_start_audio_only()
		Mode.BEHIND:
			if not _start_behind():
				_start_audio_only()
		Mode.GLIMPSE:
			if not _start_glimpse():
				_start_audio_only()
		_:
			_start_audio_only()


func _start_audio_only() -> void:
	# growl right behind the ear / running steps that stop dead
	var back := player.global_position - _fwd() * rng.randf_range(1.5, 3.0) + Vector3(0, 1.5, 0)
	if rng.randf() < 0.55:
		AudioBank.play_3d("growl", back, 0.9, rng.randf_range(0.7, 0.85), "Monster")
		scare.emit("growl_behind")
	else:
		_steps_t = 4.0
		mode = Mode.GLIMPSE
		visible = false
		_t = 0.0
		return
	_end()


# ----------------------------------------------------------------- PEEK
func _start_peek() -> bool:
	# find a wall edge ahead of the player: a free cell that is visible and
	# has a solid neighbour to its left/right (relative to the view). The
	# phantom starts hidden inside that wall and leans out into the free cell.
	var f := _fwd()
	var right := Vector3(f.z, 0, -f.x)
	var cands: Array = []
	for attempt in range(60):
		var dist := rng.randf_range(5.0, 18.0)
		var lat := rng.randf_range(-6.0, 6.0)
		var p := player.global_position + f * dist + right * lat
		if level.is_wall_at(Vector3(p.x, 1.0, p.z)):
			continue
		for side: float in [1.0, -1.0]:
			var wall_p: Vector3 = p + right * side * CELL_STEP
			if not level.is_wall_at(Vector3(wall_p.x, 1.0, wall_p.z)):
				continue
			if not _player_looking_at(p, 45.0):
				continue
			cands.append([p, wall_p, side, dist])
	if cands.is_empty():
		return false
	# prefer mid-distance
	cands.sort_custom(func(a, b): return absf(a[3] - 10.0) < absf(b[3] - 10.0))
	var c: Array = cands[0]
	var p: Vector3 = c[0]
	var wall_p: Vector3 = c[1]
	_peek_side = c[2]
	var fy: float = level.data.grid_to_world(level.data.world_to_grid(p)).y
	_peek_base = Vector3(wall_p.x, fy, wall_p.z)
	_peek_dir = -right * _peek_side
	_show_at(_peek_base)
	mode = Mode.PEEK
	_t = 0.0
	_seen_t = 0.0
	_will_charge = rng.randf() < 0.45
	AudioBank.play_3d("whisper", p, 0.35, 0.8, "Monster")
	return true


func _tick_peek(delta: float) -> void:
	_t += delta
	# feet stay inside the wall; the body tilts out round the corner over
	# ~1.1 s so head + shoulder + one arm emerge, then it sways slightly
	var lean := smoothstep(0.0, 1.0, clampf(_t / 1.1, 0.0, 1.0))
	var out := _peek_base + _peek_dir * (0.30 * lean)
	global_position = out
	var to := player.global_position - global_position
	rotation.y = atan2(to.x, to.z)
	model.animate(delta, 0.0, 0.2, player.global_position + Vector3(0, 1.4, 0), 0.4)
	var lx := to_local(global_position + _peek_dir).x
	var sway := 1.0 + 0.06 * sin(_t * 1.7)
	model.rotation.z = -signf(lx) * 0.36 * lean * sway       # whole body leans out of the wall
	model.upper.rotation.z = -signf(lx) * 0.18 * lean         # head cocks a little further
	if _fade > 0.0:
		return
	if _player_looking_at(global_position, 16.0) and _t > 0.6:
		_seen_t += delta
		if _seen_t > 0.45:
			if _will_charge:
				_begin_charge()
			else:
				_dissolve("peek_vanish")
	elif _t > 9.0:
		_fade = 1.0


# ----------------------------------------------------------------- CHARGE
func _begin_charge() -> void:
	mode = Mode.CHARGE
	model.rotation.z = 0.0
	_charge_from = global_position
	_t = 0.0
	AudioBank.play("screech", 0.95, rng.randf_range(0.95, 1.1), "Monster")
	scare.emit("charge")


func _tick_charge(delta: float) -> void:
	_t += delta
	var target := player.global_position
	var to := target - global_position
	to.y = 0.0
	var d := to.length()
	var spd := 9.5
	if d > 0.1:
		global_position += to.normalized() * minf(spd * delta, d)
		rotation.y = atan2(to.x, to.z)
	model.walk_phase += spd * delta * 1.7
	model.animate(delta, 1.3, 1.25, player.global_position + Vector3(0, 1.4, 0), 1.0)
	if fmod(_t, 0.28) < delta:
		AudioBank.play_variant_3d("step_monster", global_position, 1.0, 1.05, "Monster")
	if d < 1.6 and _fade <= 0.0:
		# right in your face -- then nothing
		jumpscare.emit()
		AudioBank.play("stinger", 0.9, 1.15, "SFX")
		_dissolve("charge_vanish")
	elif _t > 6.0 and _fade <= 0.0:
		_fade = 1.0


# ----------------------------------------------------------------- BEHIND
func _start_behind() -> bool:
	var f := _fwd()
	for attempt in range(10):
		var dist := rng.randf_range(1.8, 3.2)
		var p := player.global_position - f * dist
		if level.is_wall_at(Vector3(p.x, 1.0, p.z)):
			continue
		_show_at(_free_near(p))
		global_position = Vector3(p.x, global_position.y, p.z)
		mode = Mode.BEHIND
		_t = 0.0
		_seen_t = 0.0
		_will_charge = rng.randf() < 0.3
		AudioBank.play_3d("monster_breath", p + Vector3(0, 1.6, 0), 0.9, 1.0, "Monster")
		get_tree().create_timer(0.7).timeout.connect(func():
				if mode == Mode.BEHIND:
					AudioBank.play_3d("growl", global_position + Vector3(0, 1.6, 0), 1.0, 0.75, "Monster"))
		scare.emit("behind")
		return true
	return false


func _tick_behind(delta: float) -> void:
	_t += delta
	var to := player.global_position - global_position
	rotation.y = atan2(to.x, to.z)
	model.animate(delta, 0.0, 0.8, player.global_position + Vector3(0, 1.4, 0), 0.6)
	if _fade > 0.0:
		return
	# creep closer very slowly
	var d := Vector2(to.x, to.z).length()
	if d > 1.3:
		global_position += Vector3(to.x, 0, to.z).normalized() * 0.25 * delta
	if _player_looking_at(global_position, 35.0):
		_seen_t += delta
		if _seen_t > 0.12:
			if _will_charge and d > 2.0:
				_begin_charge()
			else:
				jumpscare.emit()
				_dissolve("behind_vanish")
	elif _t > 8.0:
		_fade = 1.0


# ----------------------------------------------------------------- GLIMPSE
func _start_glimpse() -> bool:
	var f := _fwd()
	var right := Vector3(f.z, 0, -f.x)
	for attempt in range(20):
		var ang := rng.randf_range(-0.9, 0.9)
		var dir := (f * cos(ang) + right * sin(ang)).normalized()
		var dist := rng.randf_range(14.0, 26.0)
		var p := player.global_position + dir * dist
		if level.is_wall_at(Vector3(p.x, 1.0, p.z)):
			continue
		if not _player_looking_at(p, 60.0):
			continue
		_show_at(_free_near(p))
		mode = Mode.GLIMPSE
		_t = 0.0
		_seen_t = 0.0
		_steps_t = 0.0
		return true
	return false


func _tick_glimpse(delta: float) -> void:
	_t += delta
	if _steps_t > 0.0:
		# audio-only: running steps coming closer behind, then silence
		_steps_t -= delta
		if fmod(_t, 0.32) < delta:
			var back := player.global_position - _fwd() * lerpf(9.0, 2.0, 1.0 - _steps_t / 4.0)
			AudioBank.play_variant_3d("step_monster", back, 0.8, 1.05, "Monster")
		if _steps_t <= 0.0:
			scare.emit("steps_behind")
			_end()
		return
	var to := player.global_position - global_position
	rotation.y = atan2(to.x, to.z)
	model.animate(delta, 0.0, 0.0, player.global_position + Vector3(0, 1.4, 0), 0.25)
	if _fade > 0.0:
		return
	if _player_looking_at(global_position, 10.0):
		_seen_t += delta
		if _seen_t > 1.2:
			_dissolve("glimpse_vanish")
	elif _t > 12.0:
		_fade = 1.0
