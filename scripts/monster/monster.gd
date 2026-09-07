class_name Monster
extends CharacterBody3D
## The creature (models/monster.glb via MonsterModel). Hunched, twitchy.
## AI: WANDER / STALK (behind-you) / AMBUSH (waits at the end of a corridor) /
## STARE (freezes and watches you) / APPROACH (slow, arms out) / CHASE / SEARCH.
##
## Escalation ("menace", 0..3): the first contacts are pure intimidation --
## it stares, walks at you, vanishes in static, or fakes a lunge into the lens
## without killing. Every scare raises menace; from menace 2 the chase is
## lethal. Menace also creeps up with time so long runs always turn deadly.

signal spotted_player
signal lost_player
signal attack_player
signal fake_attack           # lunged into the camera but let you live
signal scare_player          # stalker reached your back unseen
signal vanished_unseen       # stalker blinked away because you turned around
signal vanished_close        # walked up to you and dissolved
signal stare_started         # it stopped and is watching you
signal menace_changed(v: int)
signal state_changed(state: String)

enum State { WANDER, STALK, INVESTIGATE, CHASE, SEARCH, STUN, STARE, APPROACH, AMBUSH }

var menace := 0              # 0 = only scares, 1 = fake lunge, 2+ = lethal
var menace_timer := 0.0
var stare_t := 0.0
var stare_dur := 3.0
var approach_t := 0.0
var ambush_t := 0.0
var ambush_cd := 20.0
var _approach_start_d := 0.0
var stalk_t := 0.0
var _ambush_out := Vector3.INF     # free cell in front of the wall it hides in
var _ambush_lean := 0.0
var _step_out_t := 1.0             # 0..1 blend from wall position to _ambush_out
var _step_out_from := Vector3.ZERO
var _no_physics := false           # skip gravity / move_and_slide (embedded in a wall)

var state: int = State.WANDER
var level: Node = null
var player: Player = null
var dormant := true          # grace period: not in the world yet
# v10 co-op: on guests the creature is a puppet of the host's simulation
var puppet := false
var _pp_pos := Vector3.ZERO
var _pp_yaw := 0.0
var _pp_vel := Vector3.ZERO
var _pp_age := 0.0
var _pp_has := false

# rig
var model: MonsterModel = null

# ai
var path: PackedVector3Array = PackedVector3Array()
var path_i := 0
var repath_t := 0.0
var last_known := Vector3.ZERO
var lose_t := 0.0
var search_t := 0.0
var search_spot := Vector3.INF
var wander_target := Vector3.ZERO
var speed := 4.9
var walk_phase := 0.0
var stuck_t := 0.0
var sidestep := 0.0
var sidestep_dir := 1.0
var sees_player := false
var awareness := 0.0
var vocal_t := 3.0
var stun_t := 0.0
var attack_cd := 0.0
var stalk_cd := 35.0
var look_t := 0.0
var twitch_t := 0.0
var twitch := Vector3.ZERO
var breath_player: AudioStreamPlayer3D = null
var rng := RandomNumberGenerator.new()
var _step_phase_m := 0.0


func _ready() -> void:
	rng.randomize()
	add_to_group("monster")
	model = MonsterModel.new()
	model.name = "Model"
	add_child(model)
	var col := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.36
	cap.height = 2.8
	col.shape = cap
	col.position = Vector3(0, 1.4, 0)
	add_child(col)
	speed = GameSettings.monster_speed()
	breath_player = AudioBank.loop_3d("monster_breath", "Monster", 0.0)
	visible = false


# ================================================================= setup
func setup(lvl: Node, pl: Player) -> void:
	level = lvl
	player = pl
	last_known = global_position
	_pick_wander_target()


func activate(at: Vector3) -> void:
	dormant = false
	visible = true
	global_position = at
	_set_state(State.WANDER)
	stalk_cd = 25.0


# ================================================================= ai loop
func _physics_process(delta: float) -> void:
	if puppet:
		return
	if player == null or level == null or dormant:
		return
	attack_cd = maxf(attack_cd - delta, 0.0)
	stalk_cd = maxf(stalk_cd - delta, 0.0)
	ambush_cd = maxf(ambush_cd - delta, 0.0)
	# the hunt gets more serious the longer it goes on
	menace_timer += delta
	if menace_timer > 150.0 and menace < 3:
		menace_timer = 0.0
		set_menace(menace + 1)

	match state:
		State.WANDER:
			_tick_wander(delta)
			_maybe_start_stalk(delta)
			_maybe_start_ambush(delta)
		State.AMBUSH:
			_tick_ambush(delta)
		State.STARE:
			_tick_stare(delta)
		State.APPROACH:
			_tick_approach(delta)
		State.STALK:
			_tick_stalk(delta)
		State.INVESTIGATE:
			_tick_investigate(delta)
		State.CHASE:
			_tick_chase(delta)
		State.SEARCH:
			_tick_search(delta)
		State.STUN:
			stun_t -= delta
			velocity = velocity.lerp(Vector3.ZERO, delta * 6.0)
			if stun_t <= 0.0:
				_set_state(State.SEARCH)
	if _no_physics:
		velocity = Vector3.ZERO
		_animate(delta)
		_sense(delta)
		_vocalise(delta)
		return
	if not is_on_floor():
		velocity.y -= 18.0 * delta
	else:
		velocity.y = minf(velocity.y, 0.0)
	move_and_slide()
	# step-up assist for raised floor sections
	if is_on_floor() and get_slide_collision_count() > 0 and Vector2(velocity.x, velocity.z).length() > 0.5:
		var low := false
		for i in range(get_slide_collision_count()):
			var c := get_slide_collision(i)
			var n := c.get_normal()
			if absf(n.y) < 0.5 and c.get_position().y < global_position.y + 0.55 and c.get_position().y > global_position.y + 0.05:
				low = true
		if low:
			velocity.y = 3.2
	_animate(delta)
	_sense(delta)
	_vocalise(delta)


func _set_state(s: int) -> void:
	if state == s or puppet:
		return
	if state == State.AMBUSH and s != State.STARE and s != State.APPROACH:
		model.rotation.z = 0.0
		_no_physics = false
		_ambush_out = Vector3.INF
	state = s
	path = PackedVector3Array()
	path_i = 0
	look_t = 0.0
	search_spot = Vector3.INF
	state_changed.emit(State.keys()[s])
	match s:
		State.CHASE:
			AudioBank.play("screech", 0.9, randf_range(0.94, 1.06), "Monster")
			spotted_player.emit()
		State.SEARCH:
			lost_player.emit()
		State.WANDER:
			_pick_wander_target()
		State.STARE:
			stare_t = 0.0
			_stare_seen = false
			stare_dur = rng.randf_range(2.2, 4.0)
			velocity = Vector3.ZERO
			awareness = 1.0
			AudioBank.play_variant_3d("growl", global_position, 0.7, randf_range(0.65, 0.8), "Monster")
			stare_started.emit()
		State.APPROACH:
			approach_t = 0.0
			_approach_start_d = global_position.distance_to(player.global_position)
			AudioBank.play_variant_3d("growl", global_position, 0.8, randf_range(0.8, 0.95), "Monster")


func set_menace(v: int) -> void:
	v = clampi(v, 0, 3)
	if v == menace:
		return
	menace = v
	menace_changed.emit(menace)
	if OS.get_environment("BR_DEBUG") == "1":
		print("DBG menace -> ", menace)


func is_lethal() -> bool:
	if menace >= 2:
		return true
	return GameSettings.difficulty >= 2 and menace >= 1


## First real contact: it does not run. It stops and looks at you.
func _on_contact() -> void:
	if state == State.CHASE or state == State.STALK or state == State.STARE or state == State.APPROACH:
		return
	if state == State.SEARCH:
		# it just lost you and found you again: no more games
		_set_state(State.CHASE if is_lethal() else State.APPROACH)
		return
	_set_state(State.STARE)


func _pick_wander_target() -> void:
	if level == null:
		return
	var d = level.data
	if d.rooms.is_empty():
		return
	# prefers the dark: it lives where the lights are dead
	var pool: Array[Vector2i] = []
	for p in d.rooms:
		if d.zone[d.idx(p.x, p.y)] == d.Zone.DARK:
			pool.append(p)
	if pool.is_empty() or rng.randf() < 0.35:
		pool = d.rooms
	var r: Vector2i = pool[rng.randi_range(0, pool.size() - 1)]
	wander_target = d.grid_to_world(r)


# ------------------------------------------------------------- senses
func _los_clear(from: Vector3, to: Vector3) -> bool:
	# coarse grid LOS; the first/last 0.7 m are skipped so a body pressed
	# against (or half inside) a wall cell still counts as visible
	var dist := from.distance_to(to)
	if dist < 1.6:
		return true
	var dirv := (to - from) / maxf(dist, 0.001)
	var d := 0.7
	while d < dist - 0.7:
		var p := from + dirv * d
		if level.is_wall_at(Vector3(p.x, 1.2, p.z)):
			return false
		d += 0.5
	return true


func _can_see() -> bool:
	if player == null or not player.alive:
		return false
	var to_p := player.global_position - global_position
	var dist := to_p.length()
	var range := GameSettings.monster_sight_range()
	if player.flashlight_on:
		range *= 1.5
	elif level.is_lit_at(player.global_position):
		range *= 1.15
	if player.crouching:
		range *= 0.68
	if dist > range:
		return false
	# NB: this AI's facing convention is +Z (rotation.y = atan2(dir.x, dir.z))
	var fwd := global_transform.basis.z
	var flat_to := Vector3(to_p.x, 0, to_p.z).normalized()
	var flat_fwd := Vector3(fwd.x, 0, fwd.z).normalized()
	if flat_fwd.dot(flat_to) < cos(deg_to_rad(82.0)):
		return false
	return _los_clear(global_position + Vector3(0, 2.4, 0), player.global_position + Vector3(0, 1.2, 0))


func _player_looking(at: Vector3 = Vector3.INF) -> bool:
	if player == null or player.camera == null:
		return false
	var cam := player.camera
	var pt := global_position if at == Vector3.INF else at
	var to_m := (pt + Vector3(0, 1.7, 0)) - cam.global_position
	var d := to_m.length()
	if d > 24.0:
		return false
	var fwd := -cam.global_transform.basis.z
	if fwd.dot(to_m.normalized()) < cos(deg_to_rad(50.0)):
		return false
	if d < 3.5:
		return true
	return _los_clear(cam.global_position, pt + Vector3(0, 1.7, 0))


var _sense_dbg := 0.0
func _sense(delta: float) -> void:
	var saw := _can_see()
	if OS.get_environment("BR_AIDBG") == "1":
		_sense_dbg -= delta
		if _sense_dbg <= 0.0:
			_sense_dbg = 1.0
			var to_p := player.global_position - global_position
			var fwd := global_transform.basis.z
			print("SENSE saw=%s aw=%.2f dist=%.1f dot=%.2f range=%.1f los=%s" % [saw, awareness, to_p.length(),
				Vector3(fwd.x,0,fwd.z).normalized().dot(Vector3(to_p.x,0,to_p.z).normalized()), GameSettings.monster_sight_range(),
				_los_clear(global_position + Vector3(0, 2.4, 0), player.global_position + Vector3(0, 1.2, 0))])
	if saw:
		awareness = minf(awareness + delta * (2.6 if state == State.CHASE else 1.6), 1.0)
		last_known = player.global_position
		# STALK never escalates here: it ends only by vanishing (looked at)
		# or by the scare when it reaches your back
		if awareness >= 1.0 and state != State.CHASE and state != State.STALK:
			_on_contact()
		lose_t = 0.0
	else:
		awareness = maxf(awareness - delta * 0.5, 0.0)
		if state == State.APPROACH:
			# you broke line of sight while it was walking at you
			lose_t += delta
			if lose_t > 2.5:
				if is_lethal() or menace >= 1:
					_set_state(State.CHASE)
				else:
					_set_state(State.INVESTIGATE)
		if state == State.CHASE:
			# close in but no LOS (corner): keep hunting, don't give up
			var dp := global_position.distance_to(player.global_position)
			if dp < 7.0 and player.alive:
				lose_t = maxf(lose_t - delta * 2.0, 0.0)
			else:
				lose_t += delta
			if lose_t > 3.0:
				_set_state(State.SEARCH)
				search_t = 14.0
	sees_player = saw and awareness > 0.35


func hear(at: Vector3, radius: float) -> void:
	if dormant or puppet:
		return
	var d := global_position.distance_to(at)
	if d > radius:
		return
	if state == State.CHASE or state == State.STALK or state == State.STARE or state == State.APPROACH:
		return   # it already knows exactly where you are
	last_known = at
	if d < radius * 0.5:
		if is_lethal():
			_set_state(State.CHASE)
		else:
			_set_state(State.INVESTIGATE)
			search_t = 0.0
			AudioBank.play_variant_3d("growl", global_position, 0.6, 0.9, "Monster")
	else:
		_set_state(State.INVESTIGATE)
		AudioBank.play_variant_3d("growl", global_position, 0.35, 1.0, "Monster")


# ------------------------------------------------------------- movement
var _aidbg_t := 0.0
func _follow_path(delta: float, target_speed: float) -> void:
	repath_t -= delta
	if OS.get_environment("BR_AIDBG") == "1":
		_aidbg_t -= delta
		if _aidbg_t <= 0.0:
			_aidbg_t = 0.5
			var cn := "none"
			var cp := Vector3.ZERO
			if get_slide_collision_count() > 0:
				var sc := get_slide_collision(0)
				cn = str(sc.get_normal())
				cp = sc.get_position()
			print("AIDBG st=%s pos=%s path_i=%d/%d wp0=%s vel=%s spd=%.1f coll=%d n=%s cpos=%s" % [
				State.keys()[state], global_position, path_i, path.size(),
				(path[path_i] if path_i < path.size() else Vector3.INF),
				velocity, target_speed, get_slide_collision_count(), cn, cp])
	if path_i >= path.size():
		velocity = Vector3(velocity.x, 0, velocity.z).lerp(Vector3.ZERO, delta * 5.0)
		return
	var wp := path[path_i]
	var to := Vector3(wp.x, 0, wp.z) - Vector3(global_position.x, 0, global_position.z)
	var dist := to.length()
	if dist < 0.9:
		path_i += 1
		if path_i >= path.size():
			return
		to = Vector3(path[path_i].x, 0, path[path_i].z) - Vector3(global_position.x, 0, global_position.z)
		dist = to.length()
	var dirv := to / maxf(dist, 0.001)
	if sidestep > 0.0:
		sidestep -= delta
		var side := Vector3(-dirv.z, 0, dirv.x) * sidestep_dir
		dirv = (dirv + side * 0.6).normalized()
	var wish := dirv * target_speed
	velocity.x = move_toward(velocity.x, wish.x, 26.0 * delta)
	velocity.z = move_toward(velocity.z, wish.z, 26.0 * delta)
	var desired_yaw := atan2(dirv.x, dirv.z)
	rotation.y = lerp_angle(rotation.y, desired_yaw, delta * 7.0)
	if velocity.length() < target_speed * 0.35 and target_speed > 0.5:
		stuck_t += delta
		if stuck_t > 0.4:
			stuck_t = 0.0
			sidestep = 0.65
			# dodge toward the side that is actually open, not into the doorframe
			var s1 := Vector3(-dirv.z, 0, dirv.x)
			var pa := global_position + s1 * 1.0
			var pb := global_position - s1 * 1.0
			var wa = level.is_wall_at(Vector3(pa.x, 1.0, pa.z))
			var wb = level.is_wall_at(Vector3(pb.x, 1.0, pb.z))
			if wa and not wb:
				sidestep_dir = -1.0
			elif wb and not wa:
				sidestep_dir = 1.0
			else:
				sidestep_dir = 1.0 if rng.randf() > 0.5 else -1.0
	else:
		stuck_t = 0.0
	walk_phase += velocity.length() * delta * 1.7
	var ph := walk_phase / PI
	if ph - _step_phase_m >= 1.0 and velocity.length() > 0.6:
		_step_phase_m = ph
		monster_footstep()


func _request_path(to: Vector3, interval := 0.55) -> void:
	if repath_t > 0.0:
		return
	repath_t = interval
	path = level.get_nav_path(global_position, to)
	path_i = 0
	# path[0] is the cell we already stand in -- targeting it made the monster
	# re-centre on its own tile forever; skip ahead to the real next cell
	if path.size() > 1:
		var wp0 := path[0]
		if Vector2(global_position.x - wp0.x, global_position.z - wp0.z).length() < 1.3:
			path_i = 1


func _tick_wander(delta: float) -> void:
	if path_i >= path.size() and repath_t <= 0.0:
		var here := Vector3(global_position.x, 0, global_position.z)
		var tgt := Vector3(wander_target.x, 0, wander_target.z)
		if here.distance_to(tgt) < 1.2:
			if rng.randf() < delta * 0.4:
				_pick_wander_target()
		else:
			_request_path(wander_target)
	_follow_path(delta, speed * 0.40)


func _point_behind_player(d: float) -> Vector3:
	var cam := player.camera
	var back := cam.global_transform.basis.z
	back.y = 0.0
	if back.length() < 0.1:
		back = Vector3(0, 0, 1)
	back = back.normalized()
	var p := player.global_position + back * d
	var g = level.data.world_to_grid(p)
	g = level._nearest_free(level._clamp_grid(g))
	return level.data.grid_to_world(g)


func _maybe_start_stalk(delta: float) -> void:
	if not GameSettings.stalker_events or stalk_cd > 0.0:
		return
	if player == null or not player.alive:
		return
	if _player_looking():
		return
	if rng.randf() > delta * 0.035:
		return
	var p := _point_behind_player(rng.randf_range(6.0, 9.0))
	if p.distance_to(player.global_position) < 4.0:
		return
	global_position = p
	rotation.y = atan2((player.global_position - global_position).x,
			(player.global_position - global_position).z)
	_set_state(State.STALK)
	stalk_t = 0.0
	if OS.get_environment("BR_DEBUG") == "1":
		print("DBG stalk began behind player")
	AudioBank.play("whisper", 0.35, 0.8, "Monster")


func _tick_stalk(delta: float) -> void:
	if _player_looking():
		look_t += delta
		velocity = velocity.lerp(Vector3.ZERO, delta * 12.0)
		# it freezes, head cocked, then blinks out
		var to_p := player.global_position - global_position
		rotation.y = lerp_angle(rotation.y, atan2(to_p.x, to_p.z), delta * 10.0)
		if look_t > 0.45:
			vanished_unseen.emit()
			_vanish()
		return
	look_t = 0.0
	stalk_t += delta
	var behind := _point_behind_player(1.5)
	_request_path(behind, 0.45)
	_follow_path(delta, speed * 0.55)
	if global_position.distance_to(player.global_position) < 1.35:
		scare_player.emit()
		_vanish()
	elif stalk_t > 22.0 or not player.alive:
		# could not reach you (stuck / cornered): slip away quietly
		_vanish(rng.randf_range(30.0, 50.0), false)


func _vanish(cd := -1.0, loud := true) -> void:
	if loud:
		AudioBank.play_variant_3d("static_burst", global_position, 0.7, 1.0, "Monster")
	visible = false
	_no_physics = false
	_step_out_t = 1.0
	_ambush_out = Vector3.INF
	model.rotation.z = 0.0
	stalk_cd = rng.randf_range(40.0, 70.0) if cd < 0.0 else cd
	ambush_cd = maxf(ambush_cd, 12.0)
	awareness = 0.0
	lose_t = 0.0
	var d = level.data
	# reappear somewhere genuinely far: best of several random rooms (on
	# a small map a plain random pick could land right next to the player)
	var far: Vector2i = d.rooms[rng.randi_range(0, d.rooms.size() - 1)]
	var best_d := -1.0
	for k in range(24):
		var c: Vector2i = d.rooms[rng.randi_range(0, d.rooms.size() - 1)]
		var dd: float = d.grid_to_world(c).distance_to(player.global_position)
		if dd > best_d:
			best_d = dd
			far = c
		if dd > 30.0:
			break
	global_position = d.grid_to_world(far)
	_set_state(State.WANDER)
	get_tree().create_timer(0.5).timeout.connect(func():
			if not dormant:
				visible = true)


func _tick_investigate(delta: float) -> void:
	_request_path(last_known)
	_follow_path(delta, speed * 0.72)
	var here := Vector3(global_position.x, 0, global_position.z)
	var tgt := Vector3(last_known.x, 0, last_known.z)
	if here.distance_to(tgt) < 1.6:
		search_t += delta
		rotation.y += delta * 1.6
		if search_t > 4.0:
			search_t = 0.0
			_set_state(State.WANDER)


func _tick_chase(delta: float) -> void:
	# lead a moving target
	var lead := player.global_position + player.velocity * 0.30
	_request_path(lead, 0.35)
	var burst := 1.0 + 0.22 * sin(Time.get_ticks_msec() / 260.0)
	_follow_path(delta, speed * burst)
	var d := global_position.distance_to(player.global_position)
	if d < 1.8 and attack_cd <= 0.0:
		attack_cd = 1.2
		if is_lethal():
			attack_player.emit()
		else:
			_do_fake_attack()


func _do_fake_attack() -> void:
	# a lunge into the lens, a scream, and it is gone -- this time
	fake_attack.emit()
	set_menace(menace + 1)
	_vanish(rng.randf_range(30.0, 45.0))


# ------------------------------------------------------------- intimidation
var _stare_seen := false
var _stare_seen_d := 0.0
func _tick_stare(delta: float) -> void:
	stare_t += delta
	_tick_step_out(delta)
	velocity = velocity.lerp(Vector3.ZERO, delta * 10.0)
	var to_p := player.global_position - global_position
	rotation.y = lerp_angle(rotation.y, atan2(to_p.x, to_p.z), delta * 6.0)
	var d := to_p.length()
	if not player.alive:
		_set_state(State.WANDER)
		return
	var looking := _player_looking()
	if looking and not _stare_seen:
		_stare_seen = true
		_stare_seen_d = d
		stare_t = 0.0          # the stare proper starts when eyes meet
	if not _stare_seen:
		# you have not noticed it yet -- it keeps still for a moment, then
		# comes closer until you do (never wastes the scare)
		if stare_t > 2.5 or d > 20.0:
			_set_state(State.APPROACH)
		return
	# it holds the stare longer while you look back at it
	var dur := stare_dur + (1.2 if looking else 0.0)
	# you saw it and ran: a first-timer gets let go, later it gives chase
	if d > _stare_seen_d + 7.0 or (stare_t > 1.0 and not looking and d > 14.0):
		if is_lethal() or menace >= 1:
			_set_state(State.CHASE)
		else:
			_vanish(rng.randf_range(20.0, 35.0))
			vanished_close.emit()
			set_menace(1)
		return
	if stare_t < dur:
		return
	# stare over: what next depends on how far the hunt has gone
	if menace == 0:
		if rng.randf() < 0.45 or d < 5.0:
			_vanish(rng.randf_range(20.0, 35.0))
			vanished_close.emit()
			set_menace(1)
		else:
			_set_state(State.APPROACH)
	elif not is_lethal():
		_set_state(State.APPROACH)
	else:
		_set_state(State.CHASE)


func _tick_approach(delta: float) -> void:
	approach_t += delta
	_tick_step_out(delta)
	if _no_physics:
		return
	_request_path(player.global_position, 0.45)
	var pace := speed * (0.42 if approach_t < 3.0 else 0.6)
	_follow_path(delta, pace)
	var d := global_position.distance_to(player.global_position)
	if not player.alive:
		_set_state(State.WANDER)
		return
	if d < 3.2 or approach_t > 9.0:
		if menace == 0:
			# walks right up to you and dissolves into static
			# (if you never turned around it is the behind-you scare instead)
			if not _player_looking() and d < 3.2:
				scare_player.emit()
				_vanish(rng.randf_range(25.0, 40.0), false)
			else:
				_vanish(rng.randf_range(25.0, 40.0))
				vanished_close.emit()
			set_menace(1)
		else:
			# menace >= 1: it breaks into a sprint and lunges
			_set_state(State.CHASE)
		return
	# you are getting away: it gives chase (fake or real, per menace)
	if d > _approach_start_d + 6.0 or d > 16.0:
		if menace == 0:
			_vanish(rng.randf_range(25.0, 40.0))
			vanished_close.emit()
			set_menace(1)
		else:
			_set_state(State.CHASE)


## While you are not looking it places itself 12-22 m ahead of you, in the
## direction you are walking, and waits under the lamps for you to notice.
func _maybe_start_ambush(delta: float) -> void:
	if ambush_cd > 0.0 or player == null or not player.alive:
		return
	if delta < 100.0:
		if _player_looking():
			return
		if rng.randf() > delta * 0.05:
			return
	var cam := player.camera
	var f := -cam.global_transform.basis.z
	f.y = 0.0
	if f.length() < 0.1:
		return
	f = f.normalized()
	var right := Vector3(f.z, 0, -f.x)
	var d = level.data
	var best := Vector3.INF
	var best_score := -1.0
	for i in range(60):
		var dist := rng.randf_range(8.0, 22.0)
		var lat := rng.randf_range(-4.0, 4.0)
		var p := player.global_position + f * dist + right * lat
		if level.is_wall_at(Vector3(p.x, 1.0, p.z)):
			continue
		var g = level._nearest_free(level._clamp_grid(d.world_to_grid(p)))
		var w: Vector3 = d.grid_to_world(g)
		if not _los_clear(w + Vector3(0, 1.7, 0), cam.global_position):
			continue
		# prefer spots straight ahead, lit (you should SEE it) and -- best of
		# all -- next to a wall edge it can peek round
		var to_w := (w - player.global_position)
		var ld := Vector3(to_w.x, 0, to_w.z).normalized()
		var corner := false
		for dir in [Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 0, -1)]:
			var wp: Vector3 = w + dir * 0.75
			if level.is_wall_at(Vector3(wp.x, 1.0, wp.z)) and absf(dir.dot(ld)) < 0.65:
				corner = true
				break
		var score: float = f.dot(ld) + (0.4 if level.is_lit_at(w) else 0.0) + (0.9 if corner else 0.0)
		if score > best_score:
			best_score = score
			best = w
	if best == Vector3.INF:
		if OS.get_environment("BR_DEBUG") == "1":
			print("DBG ambush: no spot ahead (player at %s facing %s)" % [player.global_position, f])
		ambush_cd = 6.0
		return
	_ambush_out = best
	global_position = best
	var to_p := player.global_position - global_position
	rotation.y = atan2(to_p.x, to_p.z)
	velocity = Vector3.ZERO
	ambush_t = 0.0
	ambush_cd = rng.randf_range(45.0, 80.0)
	_ambush_lean = 0.0
	_no_physics = false
	# corner peek: if a wall runs beside this cell (roughly perpendicular to
	# your line of sight) it hides half inside it and leans out
	var look_dir := Vector3(to_p.x, 0, to_p.z).normalized()
	var best_dir := Vector3.INF
	var best_perp := 0.65
	for dir in [Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 0, -1)]:
		var wp: Vector3 = best + dir * 0.75
		if not level.is_wall_at(Vector3(wp.x, 1.0, wp.z)):
			continue
		var perp: float = absf(dir.dot(look_dir))
		if perp < best_perp:
			best_perp = perp
			best_dir = dir
	if best_dir != Vector3.INF:
		global_position = best + best_dir * 0.62
		_no_physics = true
		# lean the top of the body out of the wall (toward -best_dir)
		var lx: float = to_local(global_position - best_dir).x
		_ambush_lean = -signf(lx) * 0.32
	if OS.get_environment("BR_DEBUG") == "1":
		print("DBG ambush set up at ", global_position, " d=", to_p.length(), " corner=", best_dir != Vector3.INF)
	_set_state(State.AMBUSH)


func _tick_ambush(delta: float) -> void:
	ambush_t += delta
	velocity = velocity.lerp(Vector3.ZERO, delta * 10.0)
	var to_p := player.global_position - global_position
	rotation.y = lerp_angle(rotation.y, atan2(to_p.x, to_p.z), delta * 4.0)
	awareness = 1.0
	# lean out of the wall over ~0.8 s, with a slow breathing sway
	var lean_in := clampf(ambush_t / 0.8, 0.0, 1.0)
	model.rotation.z = _ambush_lean * lean_in * (1.0 + 0.08 * sin(ambush_t * 2.1))
	if _player_looking(_ambush_out):
		# noticed: it steps out of the corner and the stare begins
		_begin_step_out()
		_set_state(State.STARE)
		return
	if to_p.length() < 4.0:
		# walked right into it without looking up
		_begin_step_out()
		_set_state(State.APPROACH)
		return
	if ambush_t > 14.0:
		# never noticed -- it slips away
		visible = false
		model.rotation.z = 0.0
		_no_physics = false
		_vanish(rng.randf_range(10.0, 20.0), false)


func _begin_step_out() -> void:
	if _ambush_out == Vector3.INF or not _no_physics:
		model.rotation.z = 0.0
		_no_physics = false
		return
	_step_out_from = global_position
	_step_out_t = 0.0


func _tick_step_out(delta: float) -> void:
	# blends from the in-wall pose to the free cell; physics stays off until done
	if _step_out_t >= 1.0:
		return
	_step_out_t = minf(_step_out_t + delta / 0.6, 1.0)
	var k := smoothstep(0.0, 1.0, _step_out_t)
	global_position = _step_out_from.lerp(Vector3(_ambush_out.x, _step_out_from.y, _ambush_out.z), k)
	model.rotation.z = _ambush_lean * (1.0 - k)
	if _step_out_t >= 1.0:
		model.rotation.z = 0.0
		_no_physics = false
		_ambush_out = Vector3.INF


func _tick_search(delta: float) -> void:
	search_t -= delta
	# pick one spot at a time -- re-rolling every frame made it jitter in place
	var here := Vector3(global_position.x, 0, global_position.z)
	if search_spot == Vector3.INF or here.distance_to(Vector3(search_spot.x, 0, search_spot.z)) < 1.3:
		search_spot = last_known + Vector3(rng.randf_range(-3.5, 3.5), 0, rng.randf_range(-3.5, 3.5))
	_request_path(search_spot, 0.5)
	_follow_path(delta, speed * 0.55)
	if search_t <= 0.0:
		_set_state(State.WANDER)


func stun(t: float) -> void:
	_set_state(State.STUN)
	stun_t = t


# ------------------------------------------------------------- vocalisations
func _vocalise(delta: float) -> void:
	vocal_t -= delta
	if vocal_t > 0.0:
		return
	match state:
		State.CHASE:
			vocal_t = rng.randf_range(1.4, 2.8)
			AudioBank.play_variant_3d("growl", global_position, 0.95, randf_range(0.9, 1.1), "Monster")
		State.STALK:
			vocal_t = rng.randf_range(1.6, 3.0)
			AudioBank.play_variant_3d("growl", global_position, 0.16, randf_range(0.7, 0.8), "Monster")
		State.STARE, State.AMBUSH:
			vocal_t = rng.randf_range(2.5, 4.5)
			AudioBank.play_variant_3d("growl", global_position, 0.5, randf_range(0.6, 0.75), "Monster")
		State.APPROACH:
			vocal_t = rng.randf_range(1.2, 2.2)
			AudioBank.play_variant_3d("growl", global_position, 0.85, randf_range(0.75, 0.9), "Monster")
		State.SEARCH, State.INVESTIGATE:
			vocal_t = rng.randf_range(4.0, 9.0)
			AudioBank.play_variant_3d("growl", global_position, 0.45, randf_range(0.8, 0.95), "Monster")
		_:
			vocal_t = rng.randf_range(9.0, 20.0)
			if rng.randf() < 0.6:
				AudioBank.play_variant_3d("growl", global_position, 0.22, randf_range(0.7, 0.85), "Monster")


# ------------------------------------------------------------- animation
func _animate(delta: float) -> void:
	var sp := velocity.length()
	var gait := clampf(sp / maxf(speed, 0.1), 0.0, 1.4)
	walk_phase = walk_phase  # advanced in _follow_path
	model.walk_phase = walk_phase
	var reach := 0.0
	if state == State.CHASE:
		reach = 1.15
	elif state == State.APPROACH:
		reach = 1.0
	elif sees_player or state == State.STALK:
		reach = 0.7
	elif state == State.STARE or state == State.AMBUSH:
		reach = 0.25
	var look := Vector3.INF
	if player != null and (awareness > 0.1 or state == State.STALK or state == State.AMBUSH):
		look = player.global_position + Vector3(0, 1.4, 0)
	var glow := lerpf(0.05, 0.7, clampf(awareness, 0.0, 1.0))
	if state == State.CHASE:
		glow = 1.0
	elif state == State.STALK:
		glow = 0.35
	elif state == State.STARE or state == State.AMBUSH:
		glow = 0.8 + 0.2 * sin(Time.get_ticks_msec() / 90.0)   # pulsing red eyes
	elif state == State.APPROACH:
		glow = 0.9
	model.animate(delta, gait, reach, look, glow)

	if breath_player != null and player != null:
		var d := global_position.distance_to(player.global_position)
		var vol := clampf(1.0 - d / 16.0, 0.0, 1.0) * 0.9
		if state == State.STALK:
			vol = maxf(vol, 0.25)
		elif state == State.STARE or state == State.APPROACH or state == State.AMBUSH:
			vol = maxf(vol, 0.45)
		breath_player.volume_db = linear_to_db(maxf(vol, 0.0001))


func monster_footstep() -> void:
	AudioBank.play_variant_3d("step_monster", global_position,
			0.5 if state == State.STALK else 0.9, randf_range(0.92, 1.05), "Monster")


func lunge_at_camera(cam: Camera3D) -> void:
	# jumpscare pose: face filling the lens, jaws wide
	var fwd := -cam.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	# head is at ~3.1*scale above the feet: put it level with the camera
	global_position = cam.global_position + fwd * 0.45 + Vector3(0, -3.08 * model.MODEL_SCALE, 0)
	# facing convention is +Z (see _can_see_player): its +Z must point back
	# at the camera, i.e. along -fwd  ->  yaw = atan2(-fwd.x, -fwd.z)
	rotation.y = atan2(-fwd.x, -fwd.z)
	if model.upper != null:
		model.upper.rotation.y = 0.0
	model.animate(0.016, 0.0, 1.25, cam.global_position, 1.0)
	if model.eye_light != null:
		model.eye_light.light_energy = 6.0
	velocity = Vector3.ZERO
	biting = true
	set_physics_process(false)


var biting := false
func _process(delta: float) -> void:
	if biting and model != null:
		model.bite(delta)
	elif puppet:
		_tick_puppet(delta)


# ================================================================ v10: puppet
func puppet_apply(pos: Vector3, yaw: float, st: int, vel: Vector3, aware: float, flags: int, men: int) -> void:
	## Host state packet (20 Hz). Only the host runs the AI; here we replay
	## the pose and play the sounds the state changes imply.
	if not _pp_has:
		_pp_has = true
		global_position = pos
		rotation.y = yaw
	_pp_pos = pos
	_pp_yaw = yaw
	_pp_vel = vel
	_pp_age = 0.0
	awareness = aware
	menace = men
	dormant = (flags & 2) != 0
	visible = (flags & 1) != 0 and not dormant
	sees_player = (flags & 4) != 0
	if st != state:
		var old := state
		state = st
		state_changed.emit(State.keys()[st])
		match st:
			State.CHASE:
				AudioBank.play("screech", 0.9, randf_range(0.94, 1.06), "Monster")
			State.STARE:
				AudioBank.play_variant_3d("growl", global_position, 0.7, randf_range(0.65, 0.8), "Monster")
			State.APPROACH:
				AudioBank.play_variant_3d("growl", global_position, 0.8, randf_range(0.8, 0.95), "Monster")
			State.WANDER:
				if old == State.STARE or old == State.APPROACH or old == State.STALK:
					AudioBank.play_variant_3d("static_burst", global_position, 0.7, 1.0, "Monster")
	if (flags & 8) != 0 and not biting and player != null and player.camera != null and not player.alive:
		pass


func bite_remote(victim: Node3D) -> void:
	## Host: it caught another operator. Hold the pose on them for the
	## length of their death cam, then carry on.
	if victim == null or not is_instance_valid(victim) or victim.get("camera") == null:
		return
	lunge_at_camera(victim.camera)
	get_tree().create_timer(2.6).timeout.connect(func():
			if is_instance_valid(self) and biting:
				stop_biting()
				_set_state(State.SEARCH)
				search_t = 6.0)


func _tick_puppet(delta: float) -> void:
	if not _pp_has or dormant:
		return
	_pp_age += delta
	var want := _pp_pos + _pp_vel * minf(_pp_age, 0.25)
	var k := clampf(delta * 12.0, 0.0, 1.0)
	if global_position.distance_to(want) > 5.0:
		global_position = want
	else:
		global_position = global_position.lerp(want, k)
	rotation.y = lerp_angle(rotation.y, _pp_yaw, k)
	velocity = _pp_vel if _pp_age < 0.4 else Vector3.ZERO
	# gait + footsteps as in _follow_path
	walk_phase += velocity.length() * delta * 1.7
	var ph := walk_phase / PI
	if ph - _step_phase_m >= 1.0 and velocity.length() > 0.6:
		_step_phase_m = ph
		monster_footstep()
	_animate(delta)
	_vocalise(delta)


func stop_biting() -> void:
	biting = false
	if model != null:
		model.bite_reset()
	set_physics_process(true)
