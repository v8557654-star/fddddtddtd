class_name BackstageScript
extends Node
## Level 2 director ("Закулисье", GLB from github.com/v8557654-star/models).
## One long scripted encounter:
##   1. you walk the big hall; the spider (Entity 62) shadows you from the dark
##   2. the moment you enter the narrow service corridor it shrieks and charges
##   3. at the end of the corridor stands a crate -- climb in, it loses you,
##      prowls around, gives up and crawls away
##   4. the iron door behind the crate is jammed until it is gone; then leave.

const SpiderClass := preload("res://scripts/monster/spider.gd")
const CrateClass := preload("res://scripts/items/hide_crate.gd")

enum Phase { WALK, CHASE, HIDDEN, CLEAR, DONE }

var game: Node = null
var level: Node = null
var player: Player = null
var spider: Spider = null
var crate: HideCrate = null
var phase: int = Phase.WALK
var chase_x := 0.0
var door_locked := true
var _t := 0.0
var _armed := false
var _hint_t := 0.0
var _out_early := false
var _corridor_lights: Array[OmniLight3D] = []


func setup(g: Node, lvl: Node, pl: Player) -> void:
	game = g
	level = lvl
	player = pl
	var def: Dictionary = level.def
	chase_x = level.glb_to_world(float(def["chase_x_glb"]), 0.0).x

	# --- crate at the end of the corridor -----------------------------------
	var cg: Array = def["crate_glb"]
	crate = CrateClass.new()
	crate.name = "HideCrate"
	var cpos: Vector3 = level.nearest_walkable(level.glb_to_world(cg[0], cg[1]))
	level.add_child(crate)
	crate.global_position = cpos
	# open side faces back towards the corridor mouth (-X in glb space)
	crate.rotation.y = -PI / 2.0
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var gc: Vector2i = level.data.world_to_grid(cpos + Vector3(dx * 0.75, 0, dz * 0.75))
			if gc.x >= 0 and gc.y >= 0 and gc.x < level.data.gw and gc.y < level.data.gh and level.astar != null:
				level.astar.set_point_solid(gc, true)
	crate.entered.connect(_on_crate_entered)
	crate.exited.connect(_on_crate_exited)
	# a weak work-lamp over the crate so it is readable from the corridor
	var cl := OmniLight3D.new()
	cl.light_color = Color(1.0, 0.8, 0.55)
	cl.light_energy = 1.4
	cl.omni_range = 6.0
	cl.shadow_enabled = false
	cl.position = Vector3(0, 2.6, 0.6)
	crate.add_child(cl)

	# --- red emergency lamps along the corridor (its ceiling is too low for
	# the regular fixtures, so it would be pitch black otherwise) ------------
	var x0 := chase_x - 2.0
	var x1 := cpos.x - 3.0
	var cz: float = level.glb_to_world(float(def["chase_x_glb"]), float(def.get("corridor_z_glb", 0.3))).z
	var n := int(maxf(2.0, floor((x1 - x0) / 6.0)))
	for i in range(n + 1):
		var lx := lerpf(x0, x1, float(i) / float(n))
		var l := OmniLight3D.new()
		l.light_color = Color(1.0, 0.22, 0.12)
		l.light_energy = 1.1
		l.omni_range = 5.5
		l.omni_attenuation = 1.6
		l.shadow_enabled = false
		var w: Vector3 = level.nearest_walkable(Vector3(lx, 0, cz))
		l.position = Vector3(w.x, w.y + 2.35, w.z)
		level.add_child(l)
		_corridor_lights.append(l)
		var cap := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.06
		cm.bottom_radius = 0.09
		cm.height = 0.12
		var mm := StandardMaterial3D.new()
		mm.albedo_color = Color(0.5, 0.05, 0.02)
		mm.emission_enabled = true
		mm.emission = Color(1.0, 0.2, 0.1)
		mm.emission_energy_multiplier = 2.0
		cm.material = mm
		cap.mesh = cm
		cap.position = l.position + Vector3(0, 0.15, 0)
		level.add_child(cap)

	# --- the spider ----------------------------------------------------------
	spider = SpiderClass.new()
	spider.name = "Spider"
	spider.puppet = not Net.is_authority()     # v10: guests replay the host's spider
	level.add_child(spider)
	spider.setup(level, player)
	# when it gives up it crawls back down the hall, towards where you came in
	spider.retreat_to = level.nearest_walkable(level.glb_to_world(-6.0, 0.0))
	spider.caught_player.connect(_on_caught)
	spider.gave_up.connect(_on_gave_up)
	spider.state_changed.connect(_on_spider_state)
	if OS.get_environment("BR_DEBUG") == "1":
		print("DBG backstage: chase_x=%.1f crate=%s door=%s" % [chase_x, str(cpos), str(level.door_world_position())])
	# screenshot helpers: BR_SPIDER_AT=x,z[,state]  (world coords)
	if OS.get_environment("BR_SPIDER_AT") != "":
		var sp := OS.get_environment("BR_SPIDER_AT").split(",")
		_armed = true
		spider.activate(level.nearest_walkable(Vector3(float(sp[0]), 0, float(sp[1]))))
		if sp.size() > 2 and sp[2] == "freeze":
			spider._set_state(spider.State.FREEZE)
			spider.freeze_t = 999.0
		elif sp.size() > 2 and sp[2] == "chase":
			_start_chase()


func _spawn_point_behind() -> Vector3:
	# a dark, reachable cell 10-16 m from the player, preferably behind
	var d = level.data
	var best := Vector3.INF
	var best_s := -1e9
	var fwd := -player.transform.basis.z
	for cell in d.rooms:
		var w: Vector3 = d.grid_to_world(cell)
		var dist := w.distance_to(player.global_position)
		if dist < 10.0 or dist > 16.0:
			continue
		if not level.is_reachable(w, player.global_position):
			continue
		var s := randf() * 1.5
		s -= fwd.dot((w - player.global_position).normalized()) * 3.0   # behind = good
		if not level.is_lit_at(w):
			s += 2.0
		if s > best_s:
			best_s = s
			best = w
	if best == Vector3.INF:
		best = player.global_position - fwd * 12.0
		best = level.nearest_walkable(best)
	return best


func _process(delta: float) -> void:
	if game == null or player == null or not is_instance_valid(player):
		return
	if not game.world_running():
		return
	_t += delta
	if OS.get_environment("BR_BS_AUTO") == "1":
		_auto(delta)
	if not Net.is_authority():
		# v10 guest: the host drives the phases (see net_apply)
		if phase == Phase.CHASE:
			_hint_t -= delta
			if _hint_t <= 0.0:
				_hint_t = 4.0
				if player.alive and player.global_position.distance_to(crate.global_position) < 14.0:
					game.hud.show_subtitle("Ящик! Залезай внутрь!", 3.0)
		return
	match phase:
		Phase.WALK:
			if not _armed and _t > 5.0:
				_armed = true
				spider.activate(_spawn_point_behind())
				if OS.get_environment("BR_DEBUG") == "1":
					print("DBG backstage: spider activated at ", spider.global_position)
			if _armed:
				for pl in game.living_players():
					if pl.global_position.x > chase_x:
						_start_chase()
						break
		Phase.CHASE:
			_hint_t -= delta
			if _hint_t <= 0.0:
				_hint_t = 4.0
				if player.alive and player.global_position.distance_to(crate.global_position) < 14.0:
					game.hud.show_subtitle("Ящик! Залезай внутрь!", 3.0)
			# v10: its target (maybe a partner) climbed into the crate
			if spider.player != null and is_instance_valid(spider.player) and spider.player.hidden and spider.state == spider.State.CHASE:
				_on_crate_entered()
		Phase.HIDDEN:
			# v10: it found somebody else to chase / the hidden one climbed out
			if spider.state == spider.State.CHASE:
				phase = Phase.CHASE
				_sync()
			elif spider.state == spider.State.PROWL and Net.active:
				var any_hidden := false
				for pl in game.living_players():
					if pl.hidden:
						any_hidden = true
				if not any_hidden:
					phase = Phase.CHASE
					_out_early = true
					spider.start_chase()
					_sync()
		Phase.CLEAR:
			pass


func _sync() -> void:
	## v10: host -> guests: phase + door state (guests replay the HUD side)
	if Net.active and Net.is_host:
		game.dir_event(["phase", phase, door_locked])


func net_apply(a: Array, _from: int = 0) -> void:
	## v10 guest: replay a director event from the host.
	if a.is_empty() or Net.is_authority():
		return
	if str(a[0]) != "phase":
		return
	var ph := int(a[1])
	door_locked = bool(a[2])
	if ph == phase:
		return
	var old := phase
	phase = ph
	match ph:
		Phase.CHASE:
			game.bodycam.burst(0.7)
			game.hud.show_subtitle("БЕГИ." if old == Phase.WALK else "Оно ещё здесь!", 2.5)
			game.hud.set_objective("ЦЕЛЬ: БЕГИ ПО КОРИДОРУ. СПРЯЧЬСЯ")
			_hint_t = 2.5
			for l in _corridor_lights:
				var tw := create_tween()
				for k in range(6):
					tw.tween_property(l, "light_energy", randf_range(0.1, 0.5), randf_range(0.05, 0.12))
					tw.tween_property(l, "light_energy", 1.1, randf_range(0.05, 0.15))
		Phase.HIDDEN:
			game.hud.show_subtitle("Сиди тихо. Не двигайся." if player.hidden else "Напарник в ящике. Не шуми.", 4.0)
			game.hud.set_objective("ЦЕЛЬ: ЖДИ, ПОКА ОНО НЕ УЙДЁТ")
		Phase.CLEAR:
			AudioBank.play("pipe_knock_1", 0.9, 0.7, "SFX")
			game.hud.show_subtitle("Лязг у двери. Штурвал свободен. Уходи.", 5.0)
			game.hud.set_objective("ЦЕЛЬ: ДВЕРЬ В КОНЦЕ — УХОДИ")
		_:
			pass


var _auto_done := false
func _auto(_delta: float) -> void:
	## Headless test driver: sprint down the hall + corridor, dive into the
	## crate, wait for the creature to leave, walk to the door and use it.
	if _auto_done:
		return
	var here := player.global_position
	match phase:
		Phase.WALK, Phase.CHASE:
			var tgt: Vector3 = crate.global_position + crate.transform.basis.z * 1.5
			var dist := _auto_steer(tgt)
			player.debug_sprint = phase == Phase.CHASE
			if dist < 1.7 and not crate.occupied:
				player.debug_move = Vector2.ZERO
				crate.enter(player)
				print("DBG auto: entered crate at t=%.1f" % _t)
		Phase.HIDDEN:
			player.debug_move = Vector2.ZERO
		Phase.CLEAR:
			if crate.occupied:
				crate.leave()
				print("DBG auto: left crate at t=%.1f" % _t)
				return
			var dp: Vector3 = level.door_world_position()
			var dist := _auto_steer(dp)
			player.debug_sprint = false
			if dist < 1.6:
				player.debug_move = Vector2.ZERO
				var ea: Area3D = level.get_meta("exit_area")
				ea.interact(player)
				_auto_done = true
				print("DBG auto: used door at t=%.1f state=%d" % [_t, game.state])


func _auto_steer(tgt: Vector3) -> float:
	## Walk along the nav grid towards `tgt`; returns remaining straight distance.
	var here := player.global_position
	var to := tgt - here
	var dist := Vector2(to.x, to.z).length()
	var wp := tgt
	if dist > 2.0:
		var path: PackedVector3Array = level.get_nav_path(here, tgt)
		for i in range(path.size()):
			if Vector2(path[i].x - here.x, path[i].z - here.z).length() > 1.2:
				wp = path[i]
				break
	var d := wp - here
	player.yaw = atan2(-d.x, -d.z)
	player.debug_move = Vector2(0, -1)
	return dist


func _start_chase() -> void:
	phase = Phase.CHASE
	spider.start_chase()
	_sync()
	game.bodycam.burst(0.7)
	game.hud.show_subtitle("БЕГИ.", 2.5)
	game.hud.set_objective("ЦЕЛЬ: БЕГИ ПО КОРИДОРУ. СПРЯЧЬСЯ")
	_hint_t = 2.5
	# corridor lamps stutter as it passes
	for l in _corridor_lights:
		var tw := create_tween()
		for k in range(6):
			tw.tween_property(l, "light_energy", randf_range(0.1, 0.5), randf_range(0.05, 0.12))
			tw.tween_property(l, "light_energy", 1.1, randf_range(0.05, 0.15))


func _on_crate_entered() -> void:
	if not Net.is_authority():
		return          # v10 guest: the host notices via the hidden flag
	if phase == Phase.CHASE or phase == Phase.WALK:
		phase = Phase.HIDDEN
		# v10: if somebody else is still out in the open it just switches target
		if Net.active:
			var other: Player = game.nearest_living_player(spider.global_position, true)
			if other != null and other.global_position.distance_to(spider.global_position) < 22.0:
				spider.player = other
				phase = Phase.CHASE
				_sync()
				return
		spider.player_hidden()
		game.hud.show_subtitle("Сиди тихо. Не двигайся." if player.hidden else "Напарник в ящике. Не шуми.", 4.0)
		game.hud.set_objective("ЦЕЛЬ: ЖДИ, ПОКА ОНО НЕ УЙДЁТ")
		_sync()
	elif phase == Phase.CLEAR or phase == Phase.DONE:
		pass


func _on_crate_exited() -> void:
	if not Net.is_authority():
		return
	if phase == Phase.HIDDEN and spider.state != spider.State.GONE and spider.state != spider.State.RETREAT:
		# climbed out too early: it is right there
		phase = Phase.CHASE
		_out_early = true
		spider.start_chase()
		game.hud.show_subtitle("Оно ещё здесь!", 2.0)
		_sync()


func _on_gave_up() -> void:
	if phase == Phase.HIDDEN:
		game.hud.show_subtitle("Щёлканье удаляется. Оно уходит.", 4.0)


func _on_spider_state(s: String) -> void:
	if OS.get_environment("BR_DEBUG") == "1":
		print("DBG spider state -> ", s)
	if s == "GONE" and phase != Phase.DONE and Net.is_authority():
		phase = Phase.CLEAR
		door_locked = false
		AudioBank.play("pipe_knock_1", 0.9, 0.7, "SFX")
		game.hud.show_subtitle("Лязг у двери. Штурвал свободен. Уходи.", 5.0)
		game.hud.set_objective("ЦЕЛЬ: ДВЕРЬ В КОНЦЕ — УХОДИ")
		_sync()


func _on_caught() -> void:
	if game.world_running():
		game.on_spider_attack(spider)


func threat_position() -> Vector3:
	if spider != null and spider.visible and spider.state != spider.State.GONE:
		return spider.global_position
	return Vector3.INF


func threat_sees_player() -> bool:
	return spider != null and spider.state == spider.State.CHASE
