extends Node
## Level 4 -- "БЕГИ ИЛИ УМРИ" (v9). Director for the endless sprint.
##
## The tunnel is collapsing: the camera shakes, chunks of the ceiling come
## down, the red lamps stutter. EVERYTHING that lives down here is on your
## heels -- the creature and the spider, both fully lethal, both a hair
## slower than your sprint. Stamina is the whole game: sprint, breathe,
## sprint. Reach the white light -> the "run" ending.

const SpiderClass := preload("res://scripts/monster/spider.gd")

var game: Node = null
var level: Node = null
var player: Player = null
var spider: Node3D = null
var door_locked := false

var _t := 0.0
var _started := false
var _finished := false
var _quake_loop: AudioStreamPlayer = null
var _quake := 0.0                  # 0..1 current tremor intensity
var _surge_t := 0.0
var _debris_t := 1.5
var _rock_pool: Array[Node3D] = []
var _flicker_t := 0.6
var _hint_t := 0.0
var _rubber_t := 0.0
var _mon_pace := 4.4               # creature: under sprint (5.4), over a walk (2.9)
var _spd_pace := 4.3               # spider: right behind it
var _mat_rock: StandardMaterial3D


func setup(g: Node, lvl: Node, pl: Player) -> void:
	game = g
	level = lvl
	player = pl
	_mat_rock = StandardMaterial3D.new()
	_mat_rock.albedo_texture = load("res://textures/concrete.png")
	_mat_rock.albedo_color = Color(0.45, 0.43, 0.40)
	_mat_rock.roughness = 0.95
	# the run wants a fresh operator: full stamina, a faster drain so it
	# actually runs out in the middle of the tunnel
	player.stamina = 100.0
	player.stamina_drain_mul = 0.45
	# --- the pack -------------------------------------------------------
	var m = game.monster
	if m != null:
		game.monster_active = true
		m.activate(Vector3(0.7, 0.0, level.BACK - 4.0))
		m.set_menace(3)
		m.awareness = 1.0
		m.last_known = player.global_position
		m.speed = _mon_pace
		m._set_state(m.State.CHASE)
		m.set_physics_process(false)      # released in _start
	spider = SpiderClass.new()
	spider.name = "Spider"
	spider.puppet = not Net.is_authority()     # v10: guests replay the host's spider
	# position BEFORE add_child: a body that enters the tree at the origin
	# and is moved a frame later drags whatever stands on it (the player
	# spawns at the origin) along as a "moving platform"
	spider.position = Vector3(-0.8, 0.0, level.BACK - 2.0)
	level.add_child(spider)
	spider.setup(level, player)
	spider.speed_chase = _spd_pace
	spider.activate(Vector3(-0.8, 0.0, level.BACK - 2.0))
	spider.caught_player.connect(_on_caught)
	spider.set_physics_process(false)
	# quake bed starts immediately, low
	_quake_loop = AudioBank.loop_2d("quake", "Ambience", 0.0)
	game.get_tree().create_timer(1.6).timeout.connect(_start)
	if OS.get_environment("BR_DEBUG") == "1":
		print("DBG run level: gate=%s monster=%s spider=%s" % [str(level.door_world_position()), str(m.global_position if m != null else Vector3.INF), str(spider.global_position)])


func _start() -> void:
	if _started or game == null or not is_instance_valid(game) or game.state != game.State.PLAYING:
		return
	_started = true
	var m = game.monster
	if m != null and is_instance_valid(m):
		m.set_physics_process(true)
	if spider != null and is_instance_valid(spider):
		spider.set_physics_process(true)
		spider.start_chase()
	AudioBank.play("screech", 1.0, 0.9, "Monster")
	AudioBank.play("spider_screech", 0.9, 0.95, "Monster")
	AudioBank.play("distant_bang", 1.0, 0.8, "SFX")
	game.bodycam.burst(0.6)
	game.hud.show_subtitle("БЕГИ.", 2.0)


# =================================================================== tick
func _process(delta: float) -> void:
	if game == null or player == null or not is_instance_valid(player):
		return
	if not game.world_running():
		if _quake_loop != null and is_instance_valid(_quake_loop):
			_quake_loop.volume_db = linear_to_db(0.0001)
		player.shake = 0.0
		return
	_t += delta
	if OS.get_environment("BR_RUN_AUTO") == "1" and player.alive:
		_auto(delta)
	# ---- earthquake: a slow swell with surges -------------------------------
	var base := clampf(_t / 6.0, 0.15, 0.55)
	_surge_t -= delta
	if _surge_t <= 0.0:
		_surge_t = randf_range(3.0, 7.0)
		_quake = 1.0
		AudioBank.play("distant_bang", randf_range(0.6, 0.9), randf_range(0.5, 0.7), "Ambience")
	_quake = maxf(_quake - delta * 0.45, 0.0)
	var amp := base + _quake * 0.8
	player.shake = amp
	if _quake_loop != null and is_instance_valid(_quake_loop):
		_quake_loop.volume_db = linear_to_db(clampf(0.25 + amp * 0.6, 0.0001, 1.0))
	# ---- the roof comes down in pieces ------------------------------------
	_debris_t -= delta
	if _debris_t <= 0.0:
		_debris_t = randf_range(0.7, 1.8) / (0.6 + amp)
		_drop_rock()
	# ---- lamps stutter with the tremor ------------------------------------
	_flicker_t -= delta
	if _flicker_t <= 0.0:
		_flicker_t = randf_range(0.5, 1.6) / (0.5 + amp)
		var f = level.nearest_flickerable(player.global_position + Vector3(0, 0, -randf_range(0.0, 12.0)))
		if f != null:
			level.flicker_fixture(f, randf_range(0.3, 0.9))
	# ---- keep the pack honest ---------------------------------------------
	_rubber_t -= delta
	if _rubber_t <= 0.0:
		_rubber_t = 0.25
		_rubber_band()
	# ---- stamina hints (the camera's own overlay, never about the pack) ----
	_hint_t -= delta
	if _hint_t <= 0.0 and player.stamina < 12.0:
		_hint_t = 9.0
		game.hud.show_subtitle("Дыхание сбито. Шаг — вдох — и снова бегом.", 2.5)
	# ---- the light ---------------------------------------------------------
	var gate: Vector3 = level.door_world_position()
	if not _finished and player.alive and player.global_position.z < gate.z + 1.2:
		_finish()


func _rubber_band() -> void:
	## Both hunters chase for real, but the tunnel is a straight line and a
	## path-follower loses time on every cell corner. Clamp the gap so the
	## race stays a race: never further than 26 m, never a free kill from
	## behind while you still have breath.
	if not Net.is_authority():
		return          # v10: the host runs the pack
	var m = game.monster
	# v10: the pack keys off the rearmost living operator -- nobody gets left
	# behind for a free kill, nobody in front gets an easy ride either
	var rear: Node3D = player
	var rz := -1e9
	for pl in game.living_players():
		if pl.global_position.z > rz:
			rz = pl.global_position.z
			rear = pl
	var pz: float = rear.global_position.z
	if m != null and is_instance_valid(m) and not m.dormant:
		if m.player == null or not is_instance_valid(m.player) or not m.player.alive:
			m.player = rear
		if m.state != m.State.CHASE:
			m.awareness = 1.0
			m.last_known = rear.global_position
			m._set_state(m.State.CHASE)
		var gap: float = m.global_position.z - pz
		if gap > 34.0:
			m.global_position.z = pz + 34.0
		# elastic pace: it can't quite hold a sprint, but the further it
		# drops back the harder it pushes -- it is never out of earshot
		m.speed = _mon_pace + clampf((gap - 11.0) * 0.28, 0.0, 2.2)
		m.lose_t = 0.0                     # a straight tunnel: it never "loses" you
	if spider != null and is_instance_valid(spider) and spider.visible:
		if spider.state != spider.State.CHASE:
			spider._set_state(spider.State.CHASE)
		var gap: float = spider.global_position.z - pz
		if gap > 38.0:
			spider.global_position.z = pz + 38.0
		spider.speed_chase = _spd_pace + clampf((gap - 14.0) * 0.28, 0.0, 2.2)


func _drop_rock() -> void:
	## A chunk of ceiling falls somewhere 4-16 m ahead of the camera (so
	## you SEE it), bounces once with a crack, and lies there for a while.
	var pz := player.global_position.z
	var z := pz - randf_range(4.0, 16.0)
	if z < level.door_world_position().z + 3.0:
		return
	var x := randf_range(-1.1, 1.1)
	var rock := RigidBody3D.new()
	rock.collision_layer = 0           # lands on the floor, blocks nobody
	rock.collision_mask = 1
	rock.mass = 4.0
	var s := randf_range(0.22, 0.5)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(s, s * 0.7, s * 1.2)
	bm.material = _mat_rock
	mi.mesh = bm
	mi.rotation = Vector3(randf_range(0, 1), randf_range(0, TAU), randf_range(0, 1))
	rock.add_child(mi)
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = bm.size
	cs.shape = bs
	cs.rotation = mi.rotation
	rock.add_child(cs)
	rock.position = Vector3(x, level.HEIGHT - 0.3, z)
	rock.angular_velocity = Vector3(randf_range(-4, 4), randf_range(-4, 4), randf_range(-4, 4))
	level.add_child(rock)
	_rock_pool.append(rock)
	# dust puff where it will land + the crack a beat later
	var when := sqrt(2.0 * (level.HEIGHT - 0.3) / 9.8)
	game.get_tree().create_timer(when).timeout.connect(func():
		if not is_instance_valid(rock):
			return
		AudioBank.play_variant_3d("rock_hit", rock.global_position, randf_range(0.7, 1.0), randf_range(0.85, 1.15), "SFX")
		if game.state == game.State.PLAYING and player.global_position.distance_to(rock.global_position) < 6.0:
			game.bodycam.burst(0.3))
	# keep the pool small: old rocks behind the player vanish
	while _rock_pool.size() > 18:
		var old: Node3D = _rock_pool.pop_front()
		if is_instance_valid(old):
			old.queue_free()


func _finish() -> void:
	_finished = true
	player.shake = 0.0
	if Net.active and not _finish_local:
		# tell the crew; everybody runs _finish through the win event
		game.win_game("run")
		return
	if _quake_loop != null and is_instance_valid(_quake_loop):
		_quake_loop.volume_db = linear_to_db(0.0001)
	# the pack does not follow into the light
	var m = game.monster
	if m != null and is_instance_valid(m):
		m.set_physics_process(false)
	if spider != null and is_instance_valid(spider):
		spider.set_physics_process(false)
	AudioBank.play("collapse", 0.9, 0.8, "SFX")
	game.hud.show_subtitle("Свет. Гул за спиной обрывается.", 3.0)
	if not Net.active:
		game.win_game("run")
	print("DBG run level: reached the light at t=%.1f" % _t)


var _finish_local := false
func on_crew_win() -> void:
	## v10: called by main when the "win" event lands (every peer).
	_finish_local = true
	_finished = false
	_finish()


func _on_caught() -> void:
	if game.world_running():
		game.on_spider_attack(spider)


func _exit_tree() -> void:
	if _quake_loop != null and is_instance_valid(_quake_loop):
		_quake_loop.stop()
		_quake_loop.queue_free()
	if player != null and is_instance_valid(player):
		player.shake = 0.0
		player.stamina_drain_mul = 1.0
	var m = game.monster if game != null and is_instance_valid(game) else null
	if m != null and is_instance_valid(m):
		m.speed = GameSettings.monster_speed()


# ---- director API used by main.gd ----------------------------------------
func door_prompt() -> String:
	return "СВЕТ"


func on_door_interact() -> bool:
	if not _finished:
		_finish()
	return true


func radar_target() -> Vector3:
	return level.door_world_position()


func threat_position() -> Vector3:
	# the closer of the two hunters drives the fear / static
	var m = game.monster
	var best := Vector3.INF
	var bd := 1e9
	if m != null and is_instance_valid(m) and not m.dormant:
		bd = m.global_position.distance_to(player.global_position)
		best = m.global_position
	if spider != null and is_instance_valid(spider) and spider.visible:
		var d := spider.global_position.distance_to(player.global_position)
		if d < bd:
			best = spider.global_position
	return best


func threat_sees_player() -> bool:
	# static / warning overlay only when one of them is really close
	if not _started:
		return false
	var tp := threat_position()
	return tp != Vector3.INF and tp.distance_to(player.global_position) < 12.0


# ---- headless test driver ---------------------------------------------------
var _auto_walk := false
var _dbg_t := 0.0
func _auto(delta: float) -> void:
	## BR_RUN_AUTO=1: sprint down the tunnel, jog when winded (like a human
	## would), report the outcome. BR_RUN_AUTO_WALK=1: walk only (should die).
	player.yaw = 0.0
	player.debug_move = Vector2(0, -1)
	if OS.get_environment("BR_RUN_AUTO_WALK") == "1":
		player.debug_sprint = false
	else:
		if player.stamina < 4.0:
			_auto_walk = true
		elif player.stamina > 22.0:
			_auto_walk = false
		player.debug_sprint = not _auto_walk
	_dbg_t -= delta
	if _dbg_t <= 0.0:
		_dbg_t = 2.0
		var m = game.monster
		print("DBG run auto t=%.1f z=%.1f stam=%.0f sprint=%s mon_gap=%.1f spd_gap=%.1f" % [_t, player.global_position.z, player.stamina, str(player.sprinting),
			(m.global_position.z - player.global_position.z) if m != null else -1.0,
			(spider.global_position.z - player.global_position.z) if spider != null else -1.0])
