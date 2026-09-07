class_name Spider
extends CharacterBody3D
## Level 2 creature -- "Entity 62 / Aranea Membri" GLB from the user's repo.
## A scripted stalker: it shadows you through the long hall, keeps out of
## your torch beam, freezes when you look straight at it, then -- once you
## pass the chase line -- it shrieks and hunts you down the corridor. The
## only escape is the crate at the end: hide in it, wait for it to give up
## and crawl away, then walk out through the door.

signal state_changed(state: String)
signal caught_player
signal gave_up

enum State { DORMANT, LURK, STALK, FREEZE, CHASE, PROWL, RETREAT, GONE }

const MODEL_SCALE := 0.45
const EYE_H := 1.35

var state: int = State.DORMANT
var level: Node = null
var player: Player = null
var model: Node3D = null
var mesh_root: Node3D = null
var eye_light: OmniLight3D = null

var speed_stalk := 2.4
var speed_chase := 5.9
var path: PackedVector3Array = PackedVector3Array()
var path_i := 0
var repath_t := 0.0
var walk_phase := 0.0
var _step_ph := 0.0
var stuck_t := 0.0
var sidestep := 0.0
var sidestep_dir := 1.0

var lurk_t := 0.0
var freeze_t := 0.0
var prowl_t := 0.0
var prowl_target := Vector3.ZERO
var prowl_dur := 14.0
var vocal_t := 2.0
var stalk_gap := 11.0            # preferred distance behind the player while stalking
var retreat_to := Vector3.INF     # where it crawls off to when it gives up (set by the director)
var stalk_seen_t := 0.0          # how long the player has been looking at it
var bob_t := 0.0
var rng := RandomNumberGenerator.new()
var _no_physics := false
var _gone_t := 0.0
# v10 co-op puppet (guests replay the host's spider)
var puppet := false
var _pp_pos := Vector3.ZERO
var _pp_yaw := 0.0
var _pp_vel := Vector3.ZERO
var _pp_age := 0.0
var _pp_has := false
var _dbg_t := 0.0

# --- procedural leg rig -----------------------------------------------------
# The GLB has no skeleton: it is 4 legs x 2 rigid segments (femur / tibia)
# plus ~120 body pieces. We re-parent each segment under a hip / knee pivot
# and drive those with a trot gait (diagonal pairs move together).
# femur suffix, tibia suffix, hip, knee (ShapeContainerRoot local space),
# side (+1 right / -1 left), gait phase
const LEG_DEFS := [
	["_126", "_134", Vector3(0.37, -0.14, 0.63), Vector3(2.1, 0.55, 0.4), 1.0, 0.0],
	["_138", "_140", Vector3(-0.12, -0.03, 0.7), Vector3(-1.7, 0.85, 1.38), -1.0, PI],
	["_136", "_142", Vector3(0.15, -0.44, -0.36), Vector3(0.85, 0.1, -1.8), 1.0, PI],
	["_146", "_144", Vector3(-0.29, -0.52, -0.43), Vector3(-1.6, -0.1, -1.75), -1.0, 0.0],
]
var legs: Array = []            # [{hip, knee, side, phase}]
var abdomen: Node3D = null
var _leg_test := ""             # BR_LEGTEST=<phase> freezes the gait for screenshots
var _mat_cache := {}


func _ready() -> void:
	rng.randomize()
	add_to_group("spider")
	collision_layer = 8
	collision_mask = 1 | 8
	var col := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.36        # narrow enough for the 1.3 m service corridor
	cap.height = 2.0
	col.shape = cap
	col.position = Vector3(0, 1.0, 0)
	add_child(col)
	_build_model()
	visible = false


func _build_model() -> void:
	# GLB faces roughly +Z after the scene import; our AI yaw convention is
	# rotation.y = atan2(dir.x, dir.z) -> +Z forward, so no extra wrapper turn
	model = Node3D.new()
	model.name = "Model"
	add_child(model)
	var ps: PackedScene = load("res://models/spider.glb")
	if ps != null:
		mesh_root = ps.instantiate() as Node3D
		mesh_root.scale = Vector3.ONE * MODEL_SCALE
		# GLB bbox y -3.35..1.01 -> lift so the leg tips stand on the floor
		mesh_root.position = Vector3(0, 3.35 * MODEL_SCALE, 0)
		model.add_child(mesh_root)
		_apply_material(mesh_root)
		_rig_legs()
		_leg_test = OS.get_environment("BR_LEGTEST")
		if OS.get_environment("BR_DUMP") == "1":
			_dump(mesh_root, 0)
			var sr: Node3D = mesh_root.find_child("ShapeContainerRoot*", true, false) as Node3D
			if sr != null:
				print("DUMP sroot fwd(+z) in spider space = ", global_transform.basis.inverse() * sr.global_transform.basis.z,
						" up = ", global_transform.basis.inverse() * sr.global_transform.basis.y)
	else:
		# fallback silhouette so the level still plays without the GLB
		var mi := MeshInstance3D.new()
		var cm := CapsuleMesh.new()
		cm.radius = 0.5
		cm.height = 2.0
		mi.mesh = cm
		mi.position.y = 1.0
		model.add_child(mi)
	eye_light = OmniLight3D.new()
	eye_light.light_color = Color(0.55, 1.0, 0.65)
	eye_light.light_energy = 0.0
	eye_light.omni_range = 3.0
	eye_light.shadow_enabled = false
	eye_light.position = Vector3(0, EYE_H, 0.8)
	model.add_child(eye_light)


func _dump(n: Node, d: int) -> void:
	if d > 6:
		return
	var extra := ""
	if n is MeshInstance3D:
		var mi: MeshInstance3D = n
		extra = " MESH surf=%d aabb=%s" % [mi.mesh.get_surface_count(), str(mi.get_aabb())]
	print("DUMP " + "  ".repeat(d) + n.name + " kids=%d" % n.get_child_count() + extra + " T=" + str((n as Node3D).position) if n is Node3D else "")
	for c in n.get_children():
		_dump(c, d + 1)


func _apply_material(n: Node) -> void:
	# keep the author's textures but darken / roughen so it sits in the gloom
	if n is MeshInstance3D:
		var mi: MeshInstance3D = n
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		for i in range(mi.get_surface_override_material_count()):
			var m := mi.mesh.surface_get_material(i)
			if m is StandardMaterial3D:
				# one darkened copy per source material (shared -> mergeable)
				if not _mat_cache.has(m):
					var sm: StandardMaterial3D = (m as StandardMaterial3D).duplicate()
					sm.albedo_color = sm.albedo_color * Color(0.62, 0.6, 0.58)
					sm.roughness = 0.85
					sm.metallic = 0.0
					sm.cull_mode = BaseMaterial3D.CULL_DISABLED
					_mat_cache[m] = sm
				mi.set_surface_override_material(i, _mat_cache[m])
	for c in n.get_children():
		_apply_material(c)


func _rig_legs() -> void:
	legs.clear()
	var sroot: Node = mesh_root.find_child("ShapeContainerRoot*", true, false)
	if sroot == null or not (sroot is Node3D):
		return
	var by_suffix := {}
	for c in sroot.get_children():
		var nm: String = c.name
		var us := nm.rfind("_")
		if us >= 0:
			by_suffix[nm.substr(us)] = c
	for d in LEG_DEFS:
		var femur: Node3D = by_suffix.get(d[0]) as Node3D
		var tibia: Node3D = by_suffix.get(d[1]) as Node3D
		if femur == null or tibia == null:
			continue
		var hip_p: Vector3 = d[2]
		var knee_p: Vector3 = d[3]
		var hip := Node3D.new()
		hip.name = "Hip" + str(d[0])
		hip.position = hip_p
		sroot.add_child(hip)
		var knee := Node3D.new()
		knee.name = "Knee" + str(d[1])
		knee.position = knee_p - hip_p
		hip.add_child(knee)
		var fx: Transform3D = femur.transform
		sroot.remove_child(femur)
		hip.add_child(femur)
		femur.transform = Transform3D(Basis(), -hip_p) * fx
		var tx: Transform3D = tibia.transform
		sroot.remove_child(tibia)
		knee.add_child(tibia)
		tibia.transform = Transform3D(Basis(), -knee_p) * tx
		legs.append({"hip": hip, "knee": knee, "side": float(d[4]), "phase": float(d[5])})
	# everything that is not a leg = body: fold ~120 pieces into one mesh
	var body := Node3D.new()
	body.name = "Body"
	sroot.add_child(body)
	var kids: Array = sroot.get_children()
	for c in kids:
		if c == body or not (c is Node3D) or String(c.name).begins_with("Hip"):
			continue
		if String(c.name).ends_with("_128"):
			abdomen = c
			continue
		var cx: Transform3D = (c as Node3D).transform
		sroot.remove_child(c)
		body.add_child(c)
		(c as Node3D).transform = cx
	MeshMerge.merge_subtree(body, 0.0, true, true)
	if abdomen != null:
		MeshMerge.merge_subtree(abdomen, 0.0, true, true)


func setup(lvl: Node, pl: Player) -> void:
	level = lvl
	player = pl


func activate(at: Vector3) -> void:
	global_position = at
	visible = true
	_set_state(State.LURK)


func start_chase() -> void:
	if state == State.CHASE or state == State.GONE or state == State.RETREAT:
		return
	# if it lagged far behind while lurking, bring it up to ~14 m behind the
	# player (out of the hall lights) so the hunt starts on your heels
	var d := global_position.distance_to(player.global_position)
	if d > 20.0 or d < 12.0:
		var back: Vector3 = player.transform.basis.z
		for k in range(6):
			var cand: Vector3 = level.nearest_walkable(player.global_position + back * 18.0
					+ player.transform.basis.x * rng.randf_range(-2.5, 2.5))
			if level.is_reachable(cand, player.global_position):
				global_position = cand
				break
	_set_state(State.CHASE)


func player_hidden() -> void:
	## Called by the level script the moment the player is inside the crate.
	if state == State.CHASE or state == State.STALK or state == State.LURK or state == State.FREEZE:
		_set_state(State.PROWL)


func retreat() -> void:
	if state != State.GONE:
		_set_state(State.RETREAT)


func is_hunting() -> bool:
	return state == State.CHASE


# ================================================================= loop
func _physics_process(delta: float) -> void:
	if puppet:
		return
	if player == null or level == null or state == State.DORMANT or state == State.GONE:
		return
	match state:
		State.LURK:
			_tick_lurk(delta)
		State.STALK:
			_tick_stalk(delta)
		State.FREEZE:
			_tick_freeze(delta)
		State.CHASE:
			_tick_chase(delta)
		State.PROWL:
			_tick_prowl(delta)
		State.RETREAT:
			_tick_retreat(delta)
	if not is_on_floor():
		velocity.y -= 18.0 * delta
	else:
		velocity.y = minf(velocity.y, 0.0)
	move_and_slide()
	_animate(delta)
	_vocalise(delta)
	if OS.get_environment("BR_DEBUG") == "1":
		_dbg_t -= delta
		if _dbg_t <= 0.0:
			_dbg_t = 2.0
			print("SPIDER st=%s pos=(%.1f,%.1f) d=%.1f path=%d/%d" % [State.keys()[state],
					global_position.x, global_position.z,
					global_position.distance_to(player.global_position), path_i, path.size()])


func _set_state(s: int) -> void:
	if state == s or puppet:
		return
	state = s
	path = PackedVector3Array()
	path_i = 0
	repath_t = 0.0
	state_changed.emit(State.keys()[s])
	match s:
		State.LURK:
			lurk_t = rng.randf_range(4.0, 8.0)
		State.STALK:
			stalk_seen_t = 0.0
		State.FREEZE:
			freeze_t = rng.randf_range(1.2, 2.4)
			velocity = Vector3.ZERO
		State.CHASE:
			AudioBank.play("spider_screech", 1.0, randf_range(0.95, 1.05), "Monster")
			velocity = Vector3.ZERO
			repath_t = 1.1       # rears up and shrieks first -- a head start for you
		State.PROWL:
			prowl_t = 0.0
			prowl_dur = rng.randf_range(12.0, 18.0)
			prowl_target = player.global_position
			AudioBank.play_variant_3d("spider_click", global_position, 0.9, 1.0, "Monster")
		State.RETREAT:
			AudioBank.play("spider_hiss", 0.8, 0.9, "Monster")
			gave_up.emit()
		State.GONE:
			visible = false
			velocity = Vector3.ZERO


# ------------------------------------------------------------- senses
func _player_looking_at_me() -> bool:
	if player.camera == null:
		return false
	var cam := player.camera
	var to_m := (global_position + Vector3(0, EYE_H, 0)) - cam.global_position
	var d := to_m.length()
	if d > 30.0:
		return false
	var fwd := -cam.global_transform.basis.z
	if fwd.dot(to_m.normalized()) < cos(deg_to_rad(22.0)):
		return false
	return _los_clear(cam.global_position, global_position + Vector3(0, EYE_H, 0))


func _in_torch(p: Vector3) -> bool:
	if not player.flashlight_on or player.camera == null:
		return false
	var cam := player.camera
	var to := p - cam.global_position
	if to.length() > 16.0:
		return false
	return (-cam.global_transform.basis.z).dot(to.normalized()) > cos(deg_to_rad(24.0))


func _los_clear(from: Vector3, to: Vector3) -> bool:
	var dist := from.distance_to(to)
	if dist < 1.5:
		return true
	var dirv := (to - from) / dist
	var d := 0.6
	while d < dist - 0.6:
		var p := from + dirv * d
		if level.is_wall_at(Vector3(p.x, 1.2, p.z)):
			return false
		d += 0.5
	return true


# ------------------------------------------------------------- states
func _tick_lurk(delta: float) -> void:
	# sits still in the dark until the player has walked in a bit, then
	# starts shadowing
	lurk_t -= delta
	velocity = velocity.lerp(Vector3.ZERO, delta * 6.0)
	_face(player.global_position, delta, 3.0)
	if lurk_t <= 0.0 or global_position.distance_to(player.global_position) < 9.0:
		_set_state(State.STALK)


func _stalk_point() -> Vector3:
	# a spot behind the player (relative to their facing), out of the torch
	var back := player.transform.basis.z    # +Z is behind the player
	var side := player.transform.basis.x
	var best := Vector3.INF
	var best_score := -1e9
	for k in range(6):
		var ang := rng.randf_range(-0.9, 0.9)
		var dir := (back * cos(ang) + side * sin(ang)).normalized()
		var p := player.global_position + dir * stalk_gap
		p = level.nearest_walkable(p) as Vector3
		if not level.is_reachable(global_position, p):
			continue
		var score := -absf(p.distance_to(player.global_position) - stalk_gap)
		if _in_torch(p):
			score -= 6.0
		if level.is_lit_at(p):
			score -= 2.0
		score -= p.distance_to(global_position) * 0.1
		if score > best_score:
			best_score = score
			best = p
	return best


func _tick_stalk(delta: float) -> void:
	var d := global_position.distance_to(player.global_position)
	if _player_looking_at_me() and d < 20.0:
		stalk_seen_t += delta
		if stalk_seen_t > 0.25:
			_set_state(State.FREEZE)
			return
	else:
		stalk_seen_t = maxf(stalk_seen_t - delta, 0.0)
	repath_t -= delta
	if repath_t <= 0.0 or path_i >= path.size():
		repath_t = 0.9
		var tgt := _stalk_point()
		if tgt != Vector3.INF:
			path = level.get_nav_path(global_position, tgt)
			path_i = 1 if path.size() > 1 else 0
	# creeps closer over time; never right up to you before the chase line
	var want_speed := speed_stalk * (1.3 if d > stalk_gap + 5.0 else 1.0)
	if d < stalk_gap * 0.55:
		want_speed = 0.0
	_follow_path(delta, want_speed)
	if _in_torch(global_position):
		# torch on it: scuttle sideways out of the cone
		var side := player.transform.basis.x * (1.0 if rng.randf() > 0.5 else -1.0)
		var esc: Vector3 = level.nearest_walkable(global_position + side * 3.0)
		path = level.get_nav_path(global_position, esc)
		path_i = 1 if path.size() > 1 else 0
		repath_t = 0.6


func _tick_freeze(delta: float) -> void:
	# it stops dead when watched. Eyes light up. Then it backs into the dark.
	freeze_t -= delta
	velocity = velocity.lerp(Vector3.ZERO, delta * 12.0)
	_face(player.global_position, delta, 5.0)
	if freeze_t <= 0.0:
		if _player_looking_at_me():
			# still being watched: slink away out of sight and re-stalk
			var away := (global_position - player.global_position).normalized()
			var esc: Vector3 = level.nearest_walkable(global_position + away * 6.0 + player.transform.basis.x * rng.randf_range(-3.0, 3.0))
			path = level.get_nav_path(global_position, esc)
			path_i = 1 if path.size() > 1 else 0
			repath_t = 2.0
		_set_state(State.STALK)
		repath_t = 1.5


func _tick_chase(delta: float) -> void:
	repath_t -= delta
	if repath_t <= 0.0:
		repath_t = 0.3
		var lead := player.global_position + player.velocity * 0.25
		path = level.get_nav_path(global_position, lead)
		path_i = 1 if path.size() > 1 else 0
	var burst := 1.0 + 0.18 * sin(Time.get_ticks_msec() / 210.0)
	var d := global_position.distance_to(player.global_position)
	# rubber band: closes fast from afar, snaps at your heels up close so a
	# sprinting player makes the crate -- a walking one does not
	var sp := speed_chase
	if d < 4.0:
		sp = minf(4.4, speed_chase)
	elif d < 8.0:
		sp = minf(5.3, speed_chase)
	_follow_path(delta, sp * burst)
	if d < 1.7 and player.alive:
		caught_player.emit()


func _tick_prowl(delta: float) -> void:
	# player is in the crate: it circles the spot, clicking, then loses interest
	prowl_t += delta
	repath_t -= delta
	if repath_t <= 0.0 or path_i >= path.size():
		repath_t = rng.randf_range(1.0, 2.2)
		var ang := rng.randf_range(0.0, TAU)
		var r := rng.randf_range(2.5, 6.0)
		var p: Vector3 = level.nearest_walkable(prowl_target + Vector3(cos(ang) * r, 0, sin(ang) * r))
		path = level.get_nav_path(global_position, p)
		path_i = 1 if path.size() > 1 else 0
	_follow_path(delta, speed_stalk * 0.8)
	if prowl_t > prowl_dur:
		_set_state(State.RETREAT)


func _tick_retreat(delta: float) -> void:
	# crawls back the way it came and disappears
	repath_t -= delta
	if repath_t <= 0.0:
		repath_t = 1.0
		var far := retreat_to
		if far == Vector3.INF:
			var away := (global_position - player.global_position).normalized()
			far = level.nearest_walkable(global_position + away * 30.0)
		path = level.get_nav_path(global_position, far)
		path_i = 1 if path.size() > 1 else 0
	_follow_path(delta, speed_chase * 0.7)
	_gone_t += delta
	var d := global_position.distance_to(player.global_position)
	var arrived := retreat_to != Vector3.INF and Vector2(global_position.x - retreat_to.x, global_position.z - retreat_to.z).length() < 2.0
	if d > 34.0 or arrived or _gone_t > 20.0:
		_set_state(State.GONE)


# ------------------------------------------------------------- movement
func _face(at: Vector3, delta: float, rate: float) -> void:
	var to := at - global_position
	if Vector2(to.x, to.z).length() < 0.05:
		return
	rotation.y = lerp_angle(rotation.y, atan2(to.x, to.z), delta * rate)


func _follow_path(delta: float, target_speed: float) -> void:
	if path_i >= path.size() or target_speed <= 0.01:
		velocity.x = move_toward(velocity.x, 0.0, 20.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, 20.0 * delta)
		return
	var wp := path[path_i]
	var to := Vector3(wp.x - global_position.x, 0, wp.z - global_position.z)
	var dist := to.length()
	if dist < 0.9:
		path_i += 1
		if path_i >= path.size():
			return
		to = Vector3(path[path_i].x - global_position.x, 0, path[path_i].z - global_position.z)
		dist = to.length()
	var dirv := to / maxf(dist, 0.001)
	if sidestep > 0.0:
		sidestep -= delta
		dirv = (dirv + Vector3(-dirv.z, 0, dirv.x) * sidestep_dir * 0.6).normalized()
	var wish := dirv * target_speed
	velocity.x = move_toward(velocity.x, wish.x, 28.0 * delta)
	velocity.z = move_toward(velocity.z, wish.z, 28.0 * delta)
	rotation.y = lerp_angle(rotation.y, atan2(dirv.x, dirv.z), delta * 8.0)
	if velocity.length() < target_speed * 0.35:
		stuck_t += delta
		if stuck_t > 0.4:
			stuck_t = 0.0
			sidestep = 0.6
			sidestep_dir = 1.0 if rng.randf() > 0.5 else -1.0
	else:
		stuck_t = 0.0
	walk_phase += velocity.length() * delta * 2.4
	var ph := walk_phase / PI
	if ph - _step_ph >= 1.0 and velocity.length() > 0.5:
		_step_ph = ph
		AudioBank.play_variant_3d("spider_step", global_position,
				0.45 if state == State.STALK else 0.9, randf_range(0.9, 1.1), "Monster")


func _animate(delta: float) -> void:
	if mesh_root == null:
		return
	var sp := Vector2(velocity.x, velocity.z).length()
	var amp := clampf(sp / speed_chase, 0.0, 1.0)     # 0 stalk .. 1 full charge
	var move := clampf(sp / 1.0, 0.0, 1.0)            # 0 standing .. 1 walking
	if _leg_test != "":
		walk_phase = float(_leg_test)
		move = 1.0
		amp = 1.0
	bob_t += delta
	# legs: trot gait -- a leg swings forward while lifted, drags back planted
	for leg in legs:
		var ph: float = walk_phase + float(leg["phase"])
		var side: float = leg["side"]
		var swing := sin(ph) * (0.24 + 0.14 * amp) * move
		var lift := maxf(0.0, cos(ph)) * (0.17 + 0.15 * amp) * move
		var idle := (1.0 - move) * (0.012 * sin(bob_t * 2.1 + float(leg["phase"]) * 0.8) + 0.02 * absf(sin(bob_t * 0.9)))
		if state == State.FREEZE:
			idle += 0.015 * sin(bob_t * 23.0 + side * 1.3)     # tense tremor
		var hip: Node3D = leg["hip"]
		var knee: Node3D = leg["knee"]
		hip.rotation = Vector3(0.0, -swing * side, (lift + idle) * side)
		knee.rotation.z = -lift * 1.25 * side
	if abdomen != null:
		abdomen.rotation.x = 0.03 * sin(bob_t * 1.4) + 0.05 * sin(walk_phase * 2.0) * move
	# body: bob in time with the steps, slight roll, nose down when charging
	mesh_root.position.y = 3.35 * MODEL_SCALE + sin(walk_phase * 2.0) * 0.035 * move + 0.01 * sin(bob_t * 1.4) * (1.0 - move)
	mesh_root.rotation.z = sin(walk_phase) * 0.045 * move
	mesh_root.rotation.x = lerpf(mesh_root.rotation.x, -0.12 * amp if state == State.CHASE else 0.0, delta * 4.0)
	var glow := 0.0
	match state:
		State.FREEZE:
			glow = 1.6 + 0.6 * sin(Time.get_ticks_msec() / 80.0)
		State.CHASE:
			glow = 2.2
		State.STALK:
			glow = 0.35
		State.PROWL:
			glow = 1.0
	if eye_light != null:
		eye_light.light_energy = lerpf(eye_light.light_energy, glow, delta * 6.0)


func _vocalise(delta: float) -> void:
	vocal_t -= delta
	if vocal_t > 0.0:
		return
	match state:
		State.STALK:
			vocal_t = rng.randf_range(4.0, 8.0)
			AudioBank.play_variant_3d("spider_click", global_position, 0.35, randf_range(0.9, 1.1), "Monster")
		State.FREEZE:
			vocal_t = rng.randf_range(1.5, 2.5)
			AudioBank.play("spider_hiss", 0.5, randf_range(0.95, 1.1), "Monster")
		State.CHASE:
			vocal_t = rng.randf_range(1.6, 3.0)
			AudioBank.play_variant_3d("spider_click", global_position, 1.0, randf_range(1.05, 1.2), "Monster")
		State.PROWL:
			vocal_t = rng.randf_range(1.2, 2.6)
			AudioBank.play_variant_3d("spider_click", global_position, 0.8, randf_range(0.85, 1.0), "Monster")
		_:
			vocal_t = 2.0


func lunge_at_camera(cam: Camera3D) -> void:
	var fwd := -cam.global_transform.basis.z
	global_position = cam.global_position + fwd * 1.3 + Vector3(0, -1.5, 0)
	rotation.y = atan2(-fwd.x, -fwd.z)
	if eye_light != null:
		eye_light.light_energy = 5.0
	velocity = Vector3.ZERO


# ================================================================ v10: puppet
func puppet_apply(pos: Vector3, yaw: float, st: int, vel: Vector3, flags: int) -> void:
	if not _pp_has:
		_pp_has = true
		global_position = pos
		rotation.y = yaw
	_pp_pos = pos
	_pp_yaw = yaw
	_pp_vel = vel
	_pp_age = 0.0
	visible = (flags & 1) != 0
	if st != state:
		state = st
		state_changed.emit(State.keys()[st])
		match st:
			State.CHASE:
				AudioBank.play("spider_screech", 1.0, randf_range(0.95, 1.05), "Monster")
			State.PROWL:
				AudioBank.play_variant_3d("spider_click", global_position, 0.9, 1.0, "Monster")
			State.RETREAT:
				AudioBank.play("spider_hiss", 0.8, 0.9, "Monster")
				gave_up.emit()


func _process(delta: float) -> void:
	if not puppet or not _pp_has or state == State.DORMANT or state == State.GONE:
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
	walk_phase += velocity.length() * delta * 2.4
	var ph := walk_phase / PI
	if ph - _step_ph >= 1.0 and velocity.length() > 0.5:
		_step_ph = ph
		AudioBank.play_variant_3d("spider_step", global_position,
				0.45 if state == State.STALK else 0.9, randf_range(0.9, 1.1), "Monster")
	_animate(delta)
	_vocalise(delta)
