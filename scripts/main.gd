extends Node3D
## Game orchestrator: builds the world, runs the loop, drives horror systems.

const CustomMapClass := preload("res://scripts/world/custom_map.gd")
const PlayerClass := preload("res://scripts/player/player.gd")
const MonsterClass := preload("res://scripts/monster/monster.gd")
const PhantomClass := preload("res://scripts/monster/phantom.gd")
const PickupClass := preload("res://scripts/items/pickup.gd")
const BackstageClass := preload("res://scripts/world/backstage_script.gd")
const Level7Class := preload("res://scripts/world/level7_script.gd")
const RunLevelClass := preload("res://scripts/world/run_level.gd")
const RunDirectorClass := preload("res://scripts/world/run_script.gd")

enum State { MENU, PLAYING, PAUSED, DYING, DEAD, WIN, SPECTATE }

var state: int = State.MENU
var level: Node = null
var player: Player = null
var monster: Monster = null
var phantom: Phantom = null
var hud: HudUI = null
var bodycam: BodycamFX = null
var menus: MenusUI = null
var touch_ui: TouchUI = null
var inventory: InventoryUI = null
var env_world: WorldEnvironment = null
var director: Node = null          # per-level scripted encounter (Level 2)
var killer: Node3D = null          # whoever got us (for the death camera)

var level_id := 0
var run_seed := 0
var exit_open := false
var fear := 0.0
var run_time := 0.0
var total_time := 0.0
var _transition_t := -1.0
var _transition_done := false
var _fade_rect: ColorRect = null
var death_t := 0.0
var win_t := 0.0
var monster_active := false
var js_face: TextureRect = null
var warn_t := 0.0
var warn_txt := ""

var amb_hum: AudioStreamPlayer = null
var amb_room: AudioStreamPlayer = null
var amb_dark: AudioStreamPlayer = null
var _event_t := 25.0
var _whisper_t := 40.0
var rng := RandomNumberGenerator.new()
var _bot := false
var _perf_log := OS.get_environment("BR_PERF") == "1"
var _perf_acc := 0.0
var _perf_n := 0
var _dbg_touch_pick := OS.get_environment("BR_TOUCH_PICK") == "1"
var _dbg_touch_done := false
var _dbg_touch_acc := 0.0
var _bot_t := 0.0
var _bot_spawned := false
var _bot_chased := false
var _shot_dir := ""
var _shot_times: Array[float] = []
var _shot_i := 0
var _wall_t := 0.0
var _dbg_t := 0.0
# ---- v10: co-op ---------------------------------------------------------------
var remotes := {}                  # peer id -> Player(remote = true)
var spectating := 0                # peer id whose camera we watch (0 = none)
var _net_send_t := 0.0
var _retarget_t := 0.0
var _pickup_n := 0
var _net_dbg_t := 0.0


func _ready() -> void:
	add_to_group("game")
	rng.randomize()
	_build_ui()
	_build_environment()
	menus.show_screen(menus.Screen.SETTINGS if OS.get_environment("BR_SHOW_SETTINGS") == "1" else (menus.Screen.NET if OS.get_environment("BR_SHOW_NET") == "1" else menus.Screen.TITLE))
	menus.settings_changed.connect(_on_settings_changed)
	menus.start_game.connect(_on_start)
	menus.resume_game.connect(_on_resume)
	menus.restart_game.connect(_on_restart)
	menus.to_menu.connect(_on_to_menu)
	menus.net_start_game.connect(_on_net_start)
	Net.session_started.connect(_on_session_started)
	Net.peer_left.connect(_on_peer_left)
	# headless smoke-test hook (used by tools/smoke_test.sh)
	_bot = OS.get_environment("BR_BOT") == "1"
	_shot_dir = OS.get_environment("BR_SHOT_DIR")
	if _shot_dir != "":
		for part in OS.get_environment("BR_SHOT_TIMES").split(","):
			if part.strip_edges() != "":
				_shot_times.append(float(part))
	if OS.get_environment("BR_CONTROLS") != "":
		GameSettings.control_mode = OS.get_environment("BR_CONTROLS")
	if OS.get_environment("BR_GFX") != "":
		GameSettings.graphics = int(OS.get_environment("BR_GFX"))
		apply_graphics()
	if OS.get_environment("BR_GRACE") != "":
		GameSettings.grace_minutes = float(OS.get_environment("BR_GRACE"))
	if OS.get_environment("BR_SEED") != "":
		GameSettings.level_seed = int(OS.get_environment("BR_SEED"))
	if OS.get_environment("BR_AUTOSTART") == "1":
		call_deferred("_spawn_run")
	# v10 headless co-op hooks: BR_NET_HOST=1 (+BR_NET_PEERS=n waits for n
	# guests, default 1) / BR_NET_JOIN=ip
	if OS.get_environment("BR_NET_HOST") == "1":
		var err: String = Net.host()
		print("DBG net host: '", err, "'")
		var want := int(OS.get_environment("BR_NET_PEERS")) if OS.get_environment("BR_NET_PEERS") != "" else 1
		Net.lobby_changed.connect(func():
				if Net.is_host and not Net.in_game and Net.peers.size() >= want + 1:
					print("DBG net host: %d guests in, starting" % want)
					_on_net_start())
	elif OS.get_environment("BR_NET_JOIN") != "":
		get_tree().create_timer(0.8).timeout.connect(func():
				var err: String = Net.join(OS.get_environment("BR_NET_JOIN"))
				print("DBG net join: '", err, "'"))
	if OS.get_environment("BR_RESTART_AT") != "":
		get_tree().create_timer(float(OS.get_environment("BR_RESTART_AT"))).timeout.connect(
				func():
					print("DBG test restart, state=", state)
					menus.restart_game.emit())
	if OS.get_environment("BR_QUIT_AFTER") != "":
		get_tree().create_timer(float(OS.get_environment("BR_QUIT_AFTER"))).timeout.connect(
				func(): get_tree().quit(0))


func _build_ui() -> void:
	bodycam = load("res://scenes/ui/bodycam.tscn").instantiate()
	add_child(bodycam)
	hud = load("res://scenes/ui/hud.tscn").instantiate()
	hud.visible = false
	add_child(hud)
	menus = load("res://scenes/ui/menus.tscn").instantiate()
	inventory = InventoryUI.new()
	inventory.name = "Inventory"
	add_child(inventory)
	inventory.closed.connect(_on_inventory_closed)
	inventory.used.connect(_on_inventory_used)
	add_child(menus)


func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.012, 0.011, 0.009)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.32, 0.28, 0.2)
	env.ambient_light_energy = 0.07
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.glow_intensity = 0.35
	env.glow_bloom = 0.15
	env.ssao_intensity = 2.2
	env.ssao_radius = 0.6
	env.fog_enabled = true
	env.fog_light_color = Color(0.35, 0.3, 0.2)
	env.fog_density = 0.011
	env.fog_height = 1.0
	env.fog_height_density = 0.4
	env.volumetric_fog_density = 0.008
	env.volumetric_fog_albedo = Color(0.55, 0.48, 0.35)
	env.volumetric_fog_emission = Color(0.12, 0.1, 0.06)
	env.volumetric_fog_anisotropy = 0.35
	env_world = WorldEnvironment.new()
	env_world.environment = env
	add_child(env_world)
	apply_graphics()


func apply_graphics() -> void:
	## Everything expensive is switched here from GameSettings.graphics.
	var g := GameSettings
	var vp := get_viewport()
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	vp.scaling_3d_scale = g.gfx_scale()
	vp.msaa_3d = g.gfx_msaa() as Viewport.MSAA
	vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA if g.gfx_fxaa() else Viewport.SCREEN_SPACE_AA_DISABLED
	vp.positional_shadow_atlas_size = g.gfx_shadow_size()
	Engine.max_fps = g.gfx_max_fps()
	RenderingServer.directional_shadow_atlas_set_size(1024, true)
	if env_world != null:
		var env := env_world.environment
		env.glow_enabled = g.gfx_glow()
		env.ssao_enabled = g.gfx_ssao()
		# the old checkbox still forces volumetrics on; the preset can add them
		env.volumetric_fog_enabled = g.volumetric_fog or g.gfx_volumetric()
		env.fog_density = 0.011 if g.graphics >= 1 else 0.016   # thicker cheap fog hides the shorter far plane
	if player != null:
		player.apply_graphics()
	if level != null and level.has_method("apply_graphics"):
		level.apply_graphics()
	_setup_dust(g.graphics >= 2)
	if OS.get_environment("BR_DEBUG") == "1":
		print("DBG graphics preset=%d scale=%.2f msaa=%d ssao=%s glow=%s vol=%s far=%.0f" % [
			g.graphics, g.gfx_scale(), g.gfx_msaa(), g.gfx_ssao(), g.gfx_glow(), g.gfx_volumetric(), g.gfx_far()])


# ================================================================== flow
func _on_start() -> void:
	if Net.active:
		# a title-screen "start" while in a room means: play together
		_on_net_start()
		return
	_spawn_run()


func _on_net_start() -> void:
	if not Net.active or not Net.is_host:
		return
	var seedv: int = GameSettings.level_seed if GameSettings.level_seed >= 0 else rng.randi()
	var lvl := 0
	if OS.get_environment("BR_LEVEL") != "":
		lvl = int(OS.get_environment("BR_LEVEL"))
	Net.start_game(seedv, lvl)


func _on_session_started(seedv: int, lvl: int) -> void:
	## Every peer (host included) builds the same world from the same seed.
	print("DBG net session start seed=%d level=%d me=%d peers=%s" % [seedv, lvl, Net.my_id(), str(Net.peer_ids())])
	_clear_run()
	level_id = lvl
	total_time = 0.0
	run_seed = seedv
	_spawn_level(lvl)


func _on_peer_left(id: int) -> void:
	if remotes.has(id):
		var r: Node = remotes[id]
		remotes.erase(id)
		if monster != null and is_instance_valid(monster) and monster.player == r:
			monster.player = player
		var sp: Node = get_tree().get_first_node_in_group("spider")
		if sp != null and is_instance_valid(sp) and sp.player == r:
			sp.player = player
		if is_instance_valid(r):
			r.queue_free()
		if state == State.SPECTATE and spectating == id:
			spectating = 0
			_spectate_next()
	if state == State.PLAYING or state == State.SPECTATE:
		hud.show_subtitle("%s: СИГНАЛ ПОТЕРЯН. КАМЕРА ОТКЛЮЧИЛАСЬ." % Net.peer_name(id), 4.0)
	_update_crew_hud()


func _on_resume() -> void:
	_freeze_world(false)
	if state != State.SPECTATE:
		state = State.PLAYING
	menus.show_screen(menus.Screen.NONE)
	if player != null and player.alive:
		player.look_enabled = true
	if GameSettings.control_mode == "pc":
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _on_restart() -> void:
	if Net.active:
		if Net.is_host:
			_on_net_start()
		else:
			menus.end_sub.text = "ПЕРЕМОТКУ ЗАПУСКАЕТ ХОСТ  ·  ЖДИ"
		return
	_clear_run()
	_spawn_run()


func _on_to_menu() -> void:
	_clear_run()
	if Net.active:
		Net.leave()
	state = State.MENU
	hud.visible = false
	menus.show_screen(menus.Screen.TITLE)


func _clear_run() -> void:
	if inventory != null:
		if inventory.is_open:
			inventory.close()
		inventory.counts = {"water": 0, "battery": 0, "key": 0}
	Engine.time_scale = 1.0
	if js_face != null and is_instance_valid(js_face):
		js_face.queue_free()
	js_face = null
	monster_active = false
	warn_t = 0.0
	killer = null
	_bite_n = 0
	_fall_t = -1.0
	_transition_t = -1.0
	if _fade_rect != null and is_instance_valid(_fade_rect):
		_fade_rect.visible = false
		_fade_rect.color.a = 0.0
	for n in [level, player, monster, phantom, director]:
		if n != null and is_instance_valid(n):
			n.queue_free()
	level = null
	player = null
	monster = null
	phantom = null
	director = null
	_free_remotes()
	for c in get_children():
		if c is Pickup:
			remove_child(c)       # free the name at once: the next level reuses it
			c.queue_free()
	for p in [amb_hum, amb_room, amb_dark]:
		if p != null and is_instance_valid(p):
			p.stop()
			p.queue_free()
	for b in _buzzers:
		if b != null and is_instance_valid(b):
			b.queue_free()
	_buzzers.clear()
	_brownout_on = false
	amb_hum = null
	amb_room = null
	amb_dark = null


func _spawn_run() -> void:
	level_id = 0
	total_time = 0.0
	run_seed = GameSettings.level_seed if GameSettings.level_seed >= 0 else rng.randi()
	if OS.get_environment("BR_LEVEL") != "":
		level_id = int(OS.get_environment("BR_LEVEL"))
	_spawn_level(level_id)


func _spawn_level(lvl: int) -> void:
	exit_open = false
	fear = 0.0
	run_time = 0.0
	level_id = lvl
	var def := LevelDefs.get_def(lvl)

	if def.get("procedural", "") == "run":
		level = RunLevelClass.new()
	else:
		level = CustomMapClass.new()
	level.name = "Level"
	add_child(level)
	level.build(run_seed, lvl)
	var d = level.data

	player = PlayerClass.new()
	player.name = "Player"
	player.peer_id = Net.my_id()
	player.nick = Net.nick
	player.position = _spawn_slot(d.player_spawn, level.spawn_yaw, _slot_index(Net.my_id()))
	add_child(player)
	player.yaw = level.spawn_yaw
	player.mobile_mode = GameSettings.control_mode == "mob"
	_sync_touch_ui()
	# v10: the other operators
	spectating = 0
	_pickup_n = 0
	hud.set_spectating("")
	if Net.active:
		for id in Net.peer_ids():
			if id == Net.my_id():
				continue
			var r := PlayerClass.new()
			r.remote = true
			r.peer_id = id
			r.nick = Net.peer_name(id)
			r.name = "Remote%d" % id
			r.position = _spawn_slot(d.player_spawn, level.spawn_yaw, _slot_index(id))
			add_child(r)
			r.yaw = level.spawn_yaw
			r.noise_made.connect(_on_noise)
			remotes[id] = r
	_update_crew_hud()

	monster = MonsterClass.new()
	monster.name = "Monster"
	monster.position = d.monster_spawn
	monster.puppet = not Net.is_authority()
	add_child(monster)
	monster.setup(level, player)
	monster_active = false
	hud.set_inventory(inventory.counts["water"], inventory.counts["battery"], int(inventory.counts.get("key", 0)))
	# on the deeper level it is already awake; the grace period is Level 0 only
	var grace: float = GameSettings.grace_minutes if lvl == 0 else minf(GameSettings.grace_minutes, 0.5)
	var scripted: bool = def.has("scripted")
	var own_creature: bool = def.get("scripted", "") == "backstage"
	_end_kind = ""
	if own_creature:
		# Level 2 has its own creature; the regular one never wakes here --
		# park it under the floor so its body can't be bumped into
		grace = 1e9
		monster_active = true
		monster.position = Vector3(0, -100, 0)
		monster.set_physics_process(false)
	elif scripted:
		# Level 3: the director wakes the creature itself (on the key pickup)
		grace = 1e9
	elif _bot or grace <= 0.0:
		monster_active = true
		monster.activate(d.monster_spawn)
		monster.awareness = 0.25
	else:
		var gm := grace
		get_tree().create_timer(9.0).timeout.connect(func():
				if state == State.PLAYING and not monster_active and GameSettings.subtitles and gm >= 1.0:
					hud.show_subtitle("Тихо. Слишком тихо. Гул ламп и больше ничего.", 5.0))
	_grace_override = grace

	phantom = PhantomClass.new()
	phantom.name = "Phantom"
	add_child(phantom)
	phantom.setup(level, player, float(def["intensity"]))
	phantom.enabled = GameSettings.stalker_events
	phantom.scare.connect(_on_phantom_scare)
	phantom.jumpscare.connect(_on_phantom_jumpscare)

	# pickups
	for p in d.water_points:
		_add_pickup(PickupClass.Type.WATER, d.grid_to_world(p))
	for p in d.battery_points:
		_add_pickup(PickupClass.Type.BATTERY, d.grid_to_world(p))

	# door wiring
	var exit_area: Area3D = level.get_meta("exit_area")
	if exit_area != null:
		exit_area.set_script(load("res://scripts/items/exit_area.gd"))
		exit_area.setup()

	# scripted encounter director
	director = null
	if scripted:
		if def["scripted"] == "level7":
			director = Level7Class.new()
		elif def["scripted"] == "run":
			director = RunDirectorClass.new()
		else:
			director = BackstageClass.new()
		director.name = "Director"
		add_child(director)
		director.setup(self, level, player)

	if OS.get_environment("BR_MODELDBG") == "1":
		var stack: Array = [monster.model]
		var mo: Vector3 = monster.model.global_position
		while not stack.is_empty():
			var n: Node = stack.pop_back()
			if n is MeshInstance3D:
				var mi: MeshInstance3D = n
				var ab := mi.get_aabb()
				var gt := mi.global_transform
				var lo := gt * ab.position - mo
				var hi := gt * ab.end - mo
				var chain := ""
				var a: Node = n.get_parent()
				while a != null and a != monster.model:
					chain = a.name + "/" + chain
					a = a.get_parent()
				print("MODEL %-14s chain=%-40s box=(%.2f..%.2f, %.2f..%.2f, %.2f..%.2f)" % [n.name, chain, minf(lo.x,hi.x), maxf(lo.x,hi.x), minf(lo.y,hi.y), maxf(lo.y,hi.y), minf(lo.z,hi.z), maxf(lo.z,hi.z)])
			for c in n.get_children():
				stack.append(c)
		for pv in [monster.model.hip_l, monster.model.hip_r, monster.model.sh_l, monster.model.sh_r, monster.model.upper]:
			print("PIVOT ", pv.name, " ", pv.global_position, " children=", pv.get_children().map(func(c): return c.name))
	if OS.get_environment("BR_GRIDDUMP") == "1":
		for z in range(-12, 4):
			var line := ""
			for x in range(-6, 8):
				line += "#" if level.is_wall_at(Vector3(x * 0.75, 1.2, z * 0.75)) else "."
			print("GRID z=%5.2f %s" % [z * 0.75, line])
	if OS.get_environment("BR_DEBUG") == "1":
		print("DBG level=%d grid=%dx%d cells=%d seed=%d door=%s" % [lvl, d.gw, d.gh, d.rooms.size(), run_seed, str(level.door_world_position())])

	# player signals
	player.noise_made.connect(_on_noise)
	player.interact_prompt.connect(func(t): hud.set_prompt(t))
	player.nvg_toggled.connect(func(on): bodycam.set_nvg(on))
	player.died.connect(_on_player_died)
	monster.attack_player.connect(_on_monster_attack)
	monster.spotted_player.connect(func():
			bodycam.burst(0.55))
	monster.state_changed.connect(_on_monster_state)
	monster.scare_player.connect(_on_stalker_scare)
	monster.vanished_unseen.connect(_on_stalker_gone)
	monster.fake_attack.connect(_on_fake_attack)
	monster.vanished_close.connect(_on_vanished_close)
	monster.stare_started.connect(_on_stare_started)
	monster.menace_changed.connect(_on_menace_changed)
	if OS.get_environment("BR_MENACE") != "":
		monster.set_menace(int(OS.get_environment("BR_MENACE")))

	hud.set_level(def["name"], def["objective"])
	hud.set_prompt("")
	hud.set_warning("")
	_start_lamp_buzzers()
	hud.show_subtitle(def["intro"], 6.0)
	if OS.get_environment("BR_POSE") != "":
		var pp := OS.get_environment("BR_POSE").split(",")
		player.position = Vector3(float(pp[0]), 0.0, float(pp[1]))
		player.yaw = deg_to_rad(float(pp[2]))
		if pp.size() > 3:
			player.pitch = deg_to_rad(float(pp[3]))
		if pp.size() > 4:
			player.position.y = float(pp[4])
	if OS.get_environment("BR_AT_PICKUP") == "1" and not d.water_points.is_empty():
		var wp: Vector3 = d.grid_to_world(d.water_points[0])
		player.position = wp + Vector3(0, 0.1, 1.4)
		player.yaw = 0.0
		player.pitch = -0.6
		print("DBG at pickup ", wp)
	if OS.get_environment("BR_AT_DOOR") == "1":
		var dp: Vector3 = level.door_world_position()
		# door local +Z faces the room: stand 1.6 m out on that side, look at it
		player.position = dp + Vector3(0, 0.1, 0) + Vector3(sin(level.door.rotation.y), 0, cos(level.door.rotation.y)) * 1.6
		player.yaw = level.door.rotation.y
	if OS.get_environment("BR_MONSTER_AT") != "":
		var mp := OS.get_environment("BR_MONSTER_AT").split(",")
		monster_active = true
		monster.activate(Vector3(float(mp[0]), 0.0, float(mp[1])))
		monster.rotation.y = deg_to_rad(float(mp[2]))
		if OS.get_environment("BR_NO_CHASE") != "1":
			monster.awareness = 1.0
			monster._set_state(monster.State.CHASE)
		if OS.get_environment("BR_MONSTER_FREEZE") == "1":
			monster.set_physics_process(false)

	if OS.get_environment("BR_GEOMDUMP") != "":
		# BR_GEOMDUMP=x0,y0,z0,x1,y1,z1 -> every level mesh whose AABB touches the box
		var b := OS.get_environment("BR_GEOMDUMP").split(",")
		var box := AABB(Vector3(float(b[0]), float(b[1]), float(b[2])), Vector3(float(b[3]) - float(b[0]), float(b[4]) - float(b[1]), float(b[5]) - float(b[2])))
		var st: Array[Node] = [level]
		while not st.is_empty():
			var n: Node = st.pop_back()
			if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
				var ab: AABB = (n as MeshInstance3D).global_transform * (n as MeshInstance3D).get_aabb()
				if ab.intersects(box):
					print("GEOM %s aabb=%s..%s" % [str(n.get_path()).right(40), str(ab.position), str(ab.end)])
			st.append_array(n.get_children())
	if OS.get_environment("BR_STATS") == "1":
		get_tree().create_timer(1.5).timeout.connect(func():
			var mi := 0
			var tris := 0
			var stack: Array[Node] = [get_tree().root]
			while not stack.is_empty():
				var n: Node = stack.pop_back()
				if n is MeshInstance3D and (n as MeshInstance3D).mesh != null and n.is_visible_in_tree():
					mi += 1
					var m: Mesh = (n as MeshInstance3D).mesh
					for si in range(m.get_surface_count()):
						var arr := m.surface_get_arrays(si)
						var idx = arr[Mesh.ARRAY_INDEX]
						tris += (idx.size() if idx != null else arr[Mesh.ARRAY_VERTEX].size()) / 3
				stack.append_array(n.get_children())
			var per := {}
			stack = [get_tree().root]
			while not stack.is_empty():
				var n: Node = stack.pop_back()
				if n is MeshInstance3D and n.is_visible_in_tree():
					var pth := str(n.get_path())
					var parts := pth.split("/")
					var key := "/".join(parts.slice(0, mini(5, parts.size())))
					per[key] = per.get(key, 0) + 1
				stack.append_array(n.get_children())
			print("STATS per-subtree: ", per)
			var nl := 0
			var nl_vis := 0
			var nmi := 0
			stack = [get_tree().root]
			while not stack.is_empty():
				var n: Node = stack.pop_back()
				if n is Light3D:
					nl += 1
					if n.is_visible_in_tree() and (n as Light3D).light_energy > 0.01:
						nl_vis += 1
				elif n is MeshInstance3D:
					nmi += 1
				stack.append_array(n.get_children())
			print("STATS lights=%d lit=%d mesh_nodes=%d menu_vp_visible=%s" % [nl, nl_vis, nmi, str(menus.lurk_vp.is_visible_in_tree())])
			# lights touching each map chunk (the mobile renderer evaluates every
			# such light for every pixel of the chunk, capped at 8)
			var lights: Array[OmniLight3D] = []
			stack = [level]
			while not stack.is_empty():
				var n: Node = stack.pop_back()
				if n is OmniLight3D and n.is_visible_in_tree() and (n as OmniLight3D).light_energy > 0.01:
					lights.append(n)
				stack.append_array(n.get_children())
			var hist := {}
			var chunks := 0
			var worst := 0
			var tot := 0
			stack = [level]
			while not stack.is_empty():
				var n: Node = stack.pop_back()
				if n is MeshInstance3D and (n as MeshInstance3D).mesh != null and n.is_visible_in_tree():
					var mi3 := n as MeshInstance3D
					var ab: AABB = mi3.global_transform * mi3.get_aabb()
					var c := 0
					for l in lights:
						var lp := l.global_position
						var q := Vector3(clampf(lp.x, ab.position.x, ab.end.x), clampf(lp.y, ab.position.y, ab.end.y), clampf(lp.z, ab.position.z, ab.end.z))
						if q.distance_to(lp) <= l.omni_range:
							c += 1
					hist[c] = hist.get(c, 0) + 1
					if c >= 8:
						print("STATS big-chunk %s lights=%d aabb=%s tris=%d" % [str(mi3.get_path()).right(60), c, str(ab), mi3.mesh.get_faces().size() / 3])
					chunks += 1
					tot += c
					worst = maxi(worst, c)
				stack.append_array(n.get_children())
			print("STATS lights/chunk: chunks=%d avg=%.1f worst=%d hist=%s" % [chunks, float(tot) / maxf(chunks, 1), worst, str(hist)])
			print("STATS mesh_instances=%d tris=%d lights=%d draw=%d prims=%d" % [mi, tris,
				get_tree().get_nodes_in_group("__none").size(),
				Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
				Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)]))
	hud.visible = true
	if OS.get_environment("BR_NOFX") == "1":
		GameSettings.bodycam_enabled = false
	if _bot or OS.get_environment("BR_FLASH") == "1":
		player.set_flashlight(true)
	if OS.get_environment("BR_NVG") == "1":
		player.set_nvg(true)
	if OS.get_environment("BR_MOVE_TEST") == "1":
		player.yaw = deg_to_rad(90.0)     # face world -X
		player.debug_move = Vector2(0, -1) # walk forward
		get_tree().create_timer(2.0).timeout.connect(func():
				print("MOVETEST pos=", player.global_position, " expect x decreasing, z ~ const"))

	if amb_hum == null:
		_start_ambience()
	state = State.PLAYING
	menus.show_screen(menus.Screen.NONE)
	player.look_enabled = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


var _grace_override := 3.0
var _phantom_forced := false
var _e_pressed := false
var _inv_opened := false
var _ambush_forced := false


func is_last_level() -> bool:
	return level_id >= LevelDefs.count() - 1


func door_locked() -> bool:
	return director != null and is_instance_valid(director) and director.door_locked


func director_door_prompt() -> String:
	## Scripted levels may override the door prompt ("" = default text).
	if director != null and is_instance_valid(director) and director.has_method("door_prompt"):
		return director.door_prompt()
	return ""


func director_door_interact() -> bool:
	## Returns true when the director handled the door press itself.
	if director != null and is_instance_valid(director) and director.has_method("on_door_interact"):
		return director.on_door_interact()
	return false


func on_spider_attack(sp: Node3D) -> void:
	_kill_target(sp)


func on_door_used() -> void:
	## Somebody opened the exit: the whole crew goes down together.
	if state != State.PLAYING and state != State.SPECTATE:
		return
	Net.send_event("door_used")


func _do_door_used() -> void:
	if state == State.WIN and _fall_t >= 0.0 and Net.active:
		# mid-fall while a partner made it out: the tape cuts to the descent
		_fall_t = -1.0
		player.camera.cull_mask = 0xFFFFF
		state = State.SPECTATE
	if state != State.PLAYING and state != State.SPECTATE:
		return
	if _transition_t >= 0.0:
		return
	if is_last_level():
		_do_win("")
		return
	# descend: fade to black, rebuild the world on the next level
	state = State.WIN   # reuse: freezes gameplay ticks; we override below
	_transition_t = 0.0
	_transition_done = false
	player.look_enabled = false
	player.alive = false
	bodycam.burst(0.9)
	AudioBank.play("distant_bang", 1.0, 0.6, "Ambience")
	if level_id == 2:
		hud.show_subtitle("За дверью — не выход. Обрыв, и далеко внизу — лабиринт.", 4.0)
	elif level_id == 3:
		hud.show_subtitle("Тоннель уходит вниз. Стены гудят. Что-то большое идёт следом.", 4.0)
	else:
		hud.show_subtitle("Ступени уходят вниз. Свет за спиной гаснет.", 4.0)
	_ensure_fade()
	_fade_rect.visible = true


func _ensure_fade() -> void:
	if _fade_rect != null and is_instance_valid(_fade_rect):
		return
	_fade_rect = ColorRect.new()
	_fade_rect.color = Color(0, 0, 0, 0)
	_fade_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fade_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fade_rect.visible = false
	hud.add_child(_fade_rect)
	_fade_rect.set_anchors_preset(Control.PRESET_FULL_RECT)


func _tick_transition(delta: float) -> void:
	_transition_t += delta
	var a := clampf(_transition_t / 1.4, 0.0, 1.0)
	if _transition_t < 1.6:
		_fade_rect.color.a = a
		return
	if not _transition_done:
		_transition_done = true
		total_time += run_time
		var nxt := level_id + 1
		# tear down current world
		for n in [level, player, monster, phantom, director]:
			if n != null and is_instance_valid(n):
				n.queue_free()
		director = null
		_free_remotes()
		for c in get_children():
			if c is Pickup:
				remove_child(c)   # free the name at once: the next level reuses it
				c.queue_free()
		for b in _buzzers:
			if b != null and is_instance_valid(b):
				b.queue_free()
		_buzzers.clear()
		_brownout_on = false
		level = null
		player = null
		monster = null
		phantom = null
		_spawn_level(nxt)
		bodycam.burst(0.6)
		AudioBank.play("door", 0.8, 0.9)
		_fade_rect.color.a = 1.0
	# fade back in
	var back := clampf((_transition_t - 1.6) / 1.2, 0.0, 1.0)
	_fade_rect.color.a = 1.0 - back
	if back >= 1.0:
		_fade_rect.visible = false
		_transition_t = -1.0
		state = State.PLAYING


func _add_pickup(type: int, at: Vector3) -> void:
	var p := PickupClass.new()
	p.type = type
	p.position = at
	p.name = "Pickup%d" % _pickup_n     # same name on every peer (same seed, same order)
	_pickup_n += 1
	add_child(p)


func pickup_taken(p: Node, kind: String) -> void:
	## A pickup was used by the local operator: everyone removes it; the key
	## is the crew's, water / batteries go to whoever grabbed them.
	Net.send_event("pick", [str(p.name), kind])


func _start_ambience() -> void:
	amb_hum = AudioBank.loop_2d("hum", "Ambience", 0.5)
	amb_room = AudioBank.loop_2d("ambience", "Ambience", 0.55)
	amb_dark = AudioBank.loop_2d("room_dark", "Ambience", 0.0)


# ================================================================== input
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause"):
		toggle_pause()
	elif event.is_action_pressed("inventory"):
		toggle_inventory()
	elif state == State.SPECTATE and menus.current == menus.Screen.NONE:
		if (event is InputEventMouseButton and event.pressed) or (event is InputEventScreenTouch and event.pressed) \
				or event.is_action_pressed("interact"):
			_spectate_next()


# ================================================================== inventory
func add_to_inventory(kind: String) -> void:
	inventory.add(kind)
	hud.set_inventory(inventory.counts["water"], inventory.counts["battery"], int(inventory.counts.get("key", 0)))
	if GameSettings.subtitles:
		var inv_key := "[РЮКЗАК]" if GameSettings.control_mode == "mob" else "[TAB]"
		if kind == "water":
			hud.show_subtitle("Миндальная вода — в рюкзак. %s чтобы выпить." % inv_key, 3.0)
		elif kind == "battery":
			hud.show_subtitle("Батарея — в рюкзак. %s чтобы вставить." % inv_key, 3.0)
		elif kind == "key":
			hud.show_subtitle("Ржавый ключ — в рюкзак. Он от какой-то двери.", 3.5)


func has_item(kind: String) -> bool:
	return inventory != null and int(inventory.counts.get(kind, 0)) > 0


func consume_item(kind: String) -> void:
	if has_item(kind):
		inventory.counts[kind] = int(inventory.counts[kind]) - 1
		hud.set_inventory(inventory.counts["water"], inventory.counts["battery"], int(inventory.counts.get("key", 0)))


func toggle_inventory() -> void:
	if inventory.is_open:
		inventory.close()
		return
	if state != State.PLAYING or player == null or not player.alive:
		return
	if menus.current != menus.Screen.NONE:
		return
	if not Net.active:
		state = State.PAUSED
		_freeze_world(true)
	player.look_enabled = false
	inventory.set_vitals(player.sanity, player.stamina, player.flash_battery, player.cam_battery)
	inventory.open()


func _freeze_world(on: bool) -> void:
	# the pause menu already freezes gameplay via `state`; the inventory also
	# stops the physics bodies so nothing moves while you rummage
	if Net.active:
		return                 # v10 co-op: nobody can stop the tape
	for n in [player, monster, phantom]:
		if n != null and is_instance_valid(n):
			n.set_physics_process(not on)
			n.set_process(not on)


func _on_inventory_closed() -> void:
	if state != State.PAUSED and not (Net.active and state == State.PLAYING):
		return
	_freeze_world(false)
	state = State.PLAYING
	if player != null:
		player.look_enabled = true
	if GameSettings.control_mode == "pc":
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _on_inventory_used(kind: String) -> void:
	if player == null:
		return
	match kind:
		"key":
			AudioBank.play("key_jingle", 0.7, 1.0)
			hud.show_subtitle("Ключ. Им открывают двери, а не рты.", 3.0)
			inventory.counts["key"] = int(inventory.counts.get("key", 0)) + 1   # not consumable here
		"water":
			AudioBank.play("pickup", 0.8, 0.9)
			player.add_sanity(38.0)
			player.stamina = minf(player.stamina + 40.0, 100.0)
			hud.show_subtitle("Миндальная вода. Стало легче дышать.", 3.0)
		"battery":
			AudioBank.play("zap", 0.6, 1.3, "SFX")
			player.refill_flash(55.0)
			player.refill_cam(35.0)
			hud.show_subtitle("Батарея: заряд фонаря и камеры восстановлен.", 3.0)
	inventory.set_vitals(player.sanity, player.stamina, player.flash_battery, player.cam_battery)
	hud.set_inventory(inventory.counts["water"], inventory.counts["battery"], int(inventory.counts.get("key", 0)))


func toggle_pause() -> void:
	if inventory != null and inventory.is_open:
		inventory.close()
		return
	if Net.active and (state == State.PLAYING or state == State.SPECTATE):
		# co-op: the tape keeps rolling for everyone; the menu only takes the controls
		if menus.current == menus.Screen.NONE:
			if player != null:
				player.look_enabled = false
			if GameSettings.control_mode == "pc":
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			menus.show_screen(menus.Screen.PAUSE)
		elif menus.current == menus.Screen.PAUSE:
			_on_resume()
		return
	if state == State.PLAYING:
		state = State.PAUSED
		if player != null:
			player.look_enabled = false
		_freeze_world(true)
		if GameSettings.control_mode == "pc":
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		menus.show_screen(menus.Screen.PAUSE)
	elif state == State.PAUSED:
		_on_resume()


func _on_settings_changed() -> void:
	if player != null:
		player.mobile_mode = GameSettings.control_mode == "mob"
		player.camera.fov = GameSettings.fov
	if monster != null:
		monster.speed = GameSettings.monster_speed()
	if phantom != null:
		phantom.enabled = GameSettings.stalker_events
	apply_graphics()
	bodycam._apply_settings()
	_sync_touch_ui()


func _sync_touch_ui() -> void:
	var mobile := GameSettings.control_mode == "mob"
	if mobile and touch_ui == null:
		touch_ui = load("res://scripts/ui/touch_ui.gd").new()
		touch_ui.name = "TouchUI"
		add_child(touch_ui)
	if touch_ui != null:
		touch_ui.visible = mobile
		if not mobile and player != null:
			player.touch_move = Vector2.ZERO
			player.touch_sprint = false
			player.touch_crouch = false
			player.touch_lean = 0.0


# ================================================================== loop
func _process(delta: float) -> void:
	_wall_t += delta
	# keep the cursor grabbed while playing (some OSes / editor windows release it)
	var mobile := GameSettings.control_mode == "mob"
	var in_world := (state == State.PLAYING or state == State.SPECTATE) and menus.current == menus.Screen.NONE and not inventory.is_open
	if in_world and not mobile and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif mobile and Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif not in_world and state != State.DYING and Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_tick_net(delta)
	if _shot_dir != "" and _shot_i < _shot_times.size() and _wall_t >= _shot_times[_shot_i]:
		var img := get_viewport().get_texture().get_image()
		img.save_png("%s/shot_%02d.png" % [_shot_dir, _shot_i])
		print("DBG shot %d saved" % _shot_i)
		_shot_i += 1
	if _transition_t >= 0.0:
		_tick_transition(delta)
	elif state == State.PLAYING:
		_tick_playing(delta)
	elif state == State.SPECTATE:
		_tick_spectate(delta)
	elif state == State.DYING:
		_tick_dying(delta)
	elif state == State.WIN and _fall_t >= 0.0:
		_tick_fall(delta)
	elif state == State.WIN:
		win_t += delta
		if win_t > 1.6:
			state = State.DEAD
			print("DBG win screen shown kind=%s" % _end_kind)
			menus.set_end_screen(true, _time_str(), level_id, _end_kind)


func _tick_playing(delta: float) -> void:
	run_time += delta
	if not monster_active and run_time >= _grace_override * 60.0 and Net.is_authority():
		_activate_monster()
	level.update_focus(player.global_position, delta)
	if OS.get_environment("BR_WIN") == "1" and run_time > 8.0 and state == State.PLAYING:
		win_game()
	if OS.get_environment("BR_USE_DOOR") == "1" and run_time > 4.0 and state == State.PLAYING and level_id == 0:
		on_door_used()
	if OS.get_environment("BR_PRESS_E") != "" and run_time > float(OS.get_environment("BR_PRESS_E")) and not _e_pressed:
		_e_pressed = true
		Input.action_press("interact")
		print("DBG pressed E, prompt='%s'" % hud.prompt_text)
		get_tree().create_timer(0.1).timeout.connect(func(): Input.action_release("interact"))
	if OS.get_environment("BR_OPEN_INV") != "" and run_time > float(OS.get_environment("BR_OPEN_INV")) and not _inv_opened:
		_inv_opened = true
		toggle_inventory()
		print("DBG inventory opened, counts=", inventory.counts)
		if OS.get_environment("BR_INV_CLOSE_BTN") == "1":
			get_tree().create_timer(0.6).timeout.connect(func():
					inventory.close_btn.emit_signal("pressed")
					print("DBG inventory close btn -> is_open=", inventory.is_open, " state=", state))
		if OS.get_environment("BR_USE_SLOT") == "1":
			get_tree().create_timer(0.5).timeout.connect(func():
					inventory.use_item("water")
					print("DBG used water, sanity=", player.sanity, " counts=", inventory.counts))
	if OS.get_environment("BR_FORCE_PHANTOM") != "" and run_time > 2.0 and phantom != null and phantom.mode == phantom.Mode.IDLE and not _phantom_forced:
		_phantom_forced = true
		match OS.get_environment("BR_FORCE_PHANTOM"):
			"peek":
				print("DBG force peek: ", phantom._start_peek())
			"behind":
				print("DBG force behind: ", phantom._start_behind())
			"glimpse":
				print("DBG force glimpse: ", phantom._start_glimpse())
	if OS.get_environment("BR_FORCE_AMBUSH") == "1" and run_time > 1.0 and monster != null and not _ambush_forced:
		_ambush_forced = true
		monster.ambush_cd = 0.0
		monster._maybe_start_ambush(1000.0)
		print("DBG forced ambush -> state=", monster.State.keys()[monster.state])
	if OS.get_environment("BR_FORCE_STALK") == "1" and run_time > 6.0 and monster != null:
		monster.stalk_cd = 0.0
		if monster.state == MonsterClass.State.WANDER:
			monster._maybe_start_stalk(1000.0)
	if _perf_log and state == State.PLAYING:
		_perf_acc += delta
		_perf_n += 1
		if _perf_acc >= 2.0:
			print("PERF fps=%.1f proc=%.2fms phys=%.2fms draw=%d prims=%d objs=%d vram=%.0fMB tex=%.0fMB" % [
				_perf_n / _perf_acc,
				Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
				Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
				Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
				Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
				Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME),
				Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
				Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0])
			_perf_acc = 0.0
			_perf_n = 0
	if _dbg_touch_pick and state == State.PLAYING and run_time > 1.5:
		if not _dbg_touch_done:
			_dbg_touch_done = true
			print("DBG before pick prompt='%s'" % hud.prompt.text)
			player.try_interact()
			print("DBG touch-pick at t=%.2f target=%s" % [run_time, str(player.interact_target())])
		_dbg_touch_acc += delta
		if _dbg_touch_acc > 0.25:
			_dbg_touch_acc = 0.0
			print("DBG t=%.2f sub='%s' sub_t=%.2f prompt='%s' tgt=%s phys=%s" % [run_time, hud.subtitle.text, hud.subtitle_t, hud.prompt.text, str(player.interact_target()), str(player.is_physics_processing())])
	if _bot:
		_tick_bot(delta)
		if not _bot_spawned and run_time > 20.0:
			_bot_spawned = true
			monster.global_position = player.global_position + Vector3(6, 0, 6)
			print("DBG monster teleported near player")
		if _bot_spawned and not _bot_chased and run_time > 32.0:
			_bot_chased = true
			var fwd := -player.transform.basis.z
			monster.global_position = player.global_position + fwd * 5.0
			var to_p := player.global_position - monster.global_position
			monster.rotation.y = atan2(to_p.x, to_p.z)
			monster._set_state(monster.State.CHASE)
			print("DBG forced chase")
		if _bot_chased and run_time > 40.0:
			player.debug_move = Vector2.ZERO
			player.debug_sprint = false
	_dbg_t -= delta
	if _dbg_t <= 0.0 and OS.get_environment("BR_DEBUG") == "1":
		_dbg_t = 2.0
		var ray_from := player.global_position + Vector3(0, 1.0, 0)
		var ray_to := ray_from - player.transform.basis.z * 2.5
		var rq := PhysicsRayQueryParameters3D.create(ray_from, ray_to)
		var rh := get_world_3d().direct_space_state.intersect_ray(rq)
		print("DBG t=%.1f pos=(%.1f,%.2f,%.1f) mon=%s d=%.1f mon_pos=%s path=%d/%d san=%.0f lit=%s wall_here=%s wall_ahead=%s ray=%s" % [
				run_time, player.global_position.x, player.global_position.y, player.global_position.z,
				monster.State.keys()[monster.state], player.global_position.distance_to(monster.global_position),
				monster.global_position, monster.path.size(), monster.path_i,
				player.sanity, str(level.is_lit_at(player.global_position)),
				str(level.is_wall_at(player.global_position)), str(level.is_wall_at(ray_to)),
				str(rh.is_empty())])

	# ---- lighting / exposure -------------------------------------------------
	var lit = level.is_lit_at(player.global_position) or player.flashlight_on or player.nvg_on

	# ---- fear & sanity -------------------------------------------------------
	var threat_pos := monster.global_position
	var threat_hunting := false
	if director != null and is_instance_valid(director):
		var tp: Vector3 = director.threat_position()
		if tp != Vector3.INF:
			threat_pos = tp
			threat_hunting = director.threat_sees_player()
	var d_mon := player.global_position.distance_to(threat_pos)
	# proximity only bites at close range and is blended with a slow random
	# "nerves" wave so camera static can't be read as a monster radar
	var prox := clampf(1.0 - d_mon / 9.0, 0.0, 1.0)
	prox = prox * prox
	var sees := monster.sees_player or threat_hunting
	var player_sees := _player_sees_monster()
	var nerves := 0.5 + 0.5 * sin(run_time * 0.11 + 1.7) * sin(run_time * 0.037)
	fear = clampf(prox * 0.55 + (0.4 if sees else 0.0) + (0.3 if player_sees else 0.0)
			+ nerves * 0.18 + (1.0 - player.sanity / 100.0) * 0.30, 0.0, 1.0)
	player.fear = fear
	bodycam.set_fear(fear)

	var drain := 0.0
	if player_sees:
		drain += 2.6
	if d_mon < 6.0:
		drain += 0.9 if player.hidden else 1.8
	if not level.is_lit_at(player.global_position) and not player.flashlight_on and not player.nvg_on:
		drain += 0.9
	if drain > 0.0:
		player.drain_sanity(delta, drain)
	else:
		player.add_sanity(delta * 1.1)

	# ---- dust follows, camera "auto-gain" reacts to light -----------------------
	if _dust != null and is_instance_valid(_dust):
		_dust.global_position = player.global_position + Vector3(0, 1.4, 0)
	# lit area: normal exposure; dark: the bodycam cranks gain (brighter,
	# noisier picture) -- with the torch on it settles back
	var want_exp := 1.0
	if not level.is_lit_at(player.global_position) and not player.nvg_on:
		want_exp = 1.35 if not player.flashlight_on else 1.12
	bodycam.set_exposure(want_exp)

	# ---- ambience mix ----------------------------------------------------------
	if amb_hum != null:
		amb_hum.volume_db = linear_to_db(lerpf(0.12, 0.6, 1.0 if lit else 0.4))
	if amb_dark != null and amb_room != null:
		var dark_amt := 0.0 if level.is_lit_at(player.global_position) else 1.0
		amb_dark.volume_db = linear_to_db(maxf(dark_amt * 0.7, 0.0001))
		amb_room.volume_db = linear_to_db(maxf(0.55 - dark_amt * 0.3, 0.0001))

	# ---- random dread events -----------------------------------------------------
	_event_t -= delta
	if _event_t <= 0.0:
		_event_t = rng.randf_range(14.0, 32.0)
		_random_event()
	if player.sanity < 30.0:
		_whisper_t -= delta
		if _whisper_t <= 0.0:
			_whisper_t = rng.randf_range(9.0, 22.0)
			AudioBank.play("whisper", lerpf(0.5, 0.9, (30.0 - player.sanity) / 30.0),
					randf_range(0.85, 1.15), "Monster")
			bodycam.burst(0.25)

	# ---- hud ----------------------------------------------------------------------
	hud.set_batteries(player.flash_battery, player.cam_battery)
	hud.set_vitals(player.stamina, player.sanity)
	if level != null and level.has_method("door_world_position"):
		var tgt: Vector3 = level.door_world_position()
		if director != null and is_instance_valid(director) and director.has_method("radar_target"):
			tgt = director.radar_target()
		var dvec: Vector3 = tgt - player.global_position
		dvec.y = 0.0
		var lv: Vector3 = player.global_transform.basis.inverse() * dvec
		hud.set_radar(Vector2(lv.x, -lv.z), dvec.length(), door_locked(), true)
	# No text ever announces the creature: the only on-screen warnings are
	# things the camera itself would print (signal loss) -- and those show
	# only during real interference, so they cannot be used as a radar.
	warn_t = maxf(warn_t - delta, 0.0)
	if warn_t > 0.0:
		hud.set_warning(warn_txt)
	elif bodycam.static_amt > 0.55:
		hud.set_warning("СИГНАЛ НЕСТАБИЛЕН")
	else:
		hud.set_warning("")


func _tick_bot(delta: float) -> void:
	_bot_t -= delta
	if _bot_t <= 0.0:
		_bot_t = rng.randf_range(1.2, 3.5)
		var r := rng.randf()
		if r < 0.55:
			player.debug_move = Vector2(0, -1)      # forward
		elif r < 0.75:
			player.debug_move = Vector2(rng.randf_range(-1, 1), -1).normalized()
		elif r < 0.85:
			player.debug_move = Vector2.ZERO
		else:
			player.debug_move = Vector2(0, 1)       # back
		player.yaw += rng.randf_range(-1.6, 1.6)
		player.debug_sprint = rng.randf() < 0.6
	# steer away from walls a bit using the nav grid
	if level.is_wall_at(player.global_position - player.transform.basis.z * -1.4):
		player.yaw += delta * 2.4


func _player_sees_monster() -> bool:
	if player == null or monster == null:
		return false
	var mpos := monster.global_position
	if monster.dormant:
		if director == null or not is_instance_valid(director):
			return false
		mpos = director.threat_position()
		if mpos == Vector3.INF:
			return false
	var to_m := mpos + Vector3(0, 1.8, 0) - player.camera.global_position
	var dist := to_m.length()
	if dist > 26.0:
		return false
	var fwd := -player.camera.global_transform.basis.z
	if fwd.dot(to_m.normalized()) < cos(deg_to_rad(50.0)):
		return false
	return not level.is_wall_at(Vector3(mpos.x, 1.4, mpos.z)) or dist < 3.0


func _random_event() -> void:
	## Atmosphere director. Nothing here reveals the creature -- every event is
	## the building itself: pipes, ventilation, dying tubes, water, distance.
	var roll := rng.randf()
	var at := _random_point_around(player.global_position, 6.0, 16.0)
	if roll < 0.16:
		AudioBank.play("distant_bang", rng.randf_range(0.4, 0.8), randf_range(0.85, 1.1), "Ambience")
		_maybe_sub(["Где-то далеко упало что-то тяжёлое.", "Глухой удар. Далеко. Или не очень."])
	elif roll < 0.32:
		AudioBank.play_variant_3d("pipe_knock", at, rng.randf_range(0.6, 1.0), randf_range(0.9, 1.1), "Ambience")
		_maybe_sub(["Стук в трубах. Как будто кто-то отвечает.", "Трубы в стенах стучат. Три раза."])
	elif roll < 0.46:
		AudioBank.play_variant_3d("creak", at, rng.randf_range(0.5, 0.9), randf_range(0.85, 1.1), "Ambience")
		_maybe_sub(["Стена скрипнула. Здание оседает.", "Перекрытия стонут под чем-то тяжёлым."])
	elif roll < 0.58:
		# a nearby fixture dies
		var f = level.nearest_flickerable(player.global_position)
		if f != null:
			level.kill_fixture(f)
			AudioBank.play("zap", 0.8, 1.0, "Ambience")
			bodycam.burst(0.35)
			_maybe_sub(["Лампа над тобой мигнула и погасла.", "Ещё одна трубка сдохла."])
	elif roll < 0.68:
		# flicker a lamp near you and buzz
		var f = level.nearest_flickerable(player.global_position)
		if f != null:
			level.flicker_fixture(f, rng.randf_range(0.8, 1.8))
		AudioBank.play("flicker", 0.5, randf_range(0.9, 1.2), "Ambience")
	elif roll < 0.78:
		AudioBank.play_3d("hvac_surge", at + Vector3(0, 2.5, 0), 0.9, randf_range(0.9, 1.1), "Ambience")
		_maybe_sub(["Вентиляция включилась. Воздух пахнет пылью и мокрым ковром.", "Из решётки в потолке потянуло холодом."])
	elif roll < 0.88:
		_brownout()
	elif roll < 0.95:
		AudioBank.play_3d("far_voices", _random_point_around(player.global_position, 18.0, 30.0) + Vector3(0, 1.5, 0), 0.8, randf_range(0.9, 1.05), "Ambience")
		_maybe_sub(["Голоса? Нет. Просто гул в вентиляции.", "Показалось, что кто-то говорит. Далеко."])
	else:
		AudioBank.play_3d("far_steps", _random_point_around(player.global_position, 14.0, 24.0), 0.85, randf_range(0.9, 1.1), "Ambience")
	# drips are independent and frequent in the dark
	if not level.is_lit_at(player.global_position) and rng.randf() < 0.5:
		AudioBank.play_variant_3d("drip", _random_point_around(player.global_position, 3.0, 9.0), 0.7, randf_range(0.9, 1.15), "Ambience")


func _maybe_sub(lines: Array) -> void:
	if GameSettings.subtitles and rng.randf() < 0.6:
		hud.show_subtitle(lines[rng.randi_range(0, lines.size() - 1)], 3.0)


func _random_point_around(c: Vector3, dmin: float, dmax: float) -> Vector3:
	var a := rng.randf_range(0.0, TAU)
	var d := rng.randf_range(dmin, dmax)
	return Vector3(c.x + cos(a) * d, c.y + 1.2, c.z + sin(a) * d)


var _buzzers: Array = []
var _dust: GPUParticles3D = null
var _brownout_on := false
func _brownout() -> void:
	## Power sag: every working lamp dips for a second, the hum drops an
	## octave, then it all thunks back. Pure dread, zero information.
	if _brownout_on or level == null:
		return
	_brownout_on = true
	AudioBank.play("brownout", 0.9, 1.0, "Ambience")
	bodycam.burst(0.25)
	var lamps: Array = level.lamp_lights
	var tw := create_tween()
	tw.set_parallel(true)
	for li in lamps:
		if li.visible and li.light_energy > 0.1:
			tw.tween_property(li, "light_energy", 0.35, 0.6).set_delay(0.3)
	if amb_hum != null:
		tw.tween_property(amb_hum, "pitch_scale", 0.55, 0.7).set_delay(0.2)
	tw.chain()
	tw.set_parallel(true)
	for li in lamps:
		if li.visible and li.light_energy > 0.1:
			tw.tween_property(li, "light_energy", 2.8, 0.15).set_delay(0.7)
	if amb_hum != null:
		tw.tween_property(amb_hum, "pitch_scale", 1.0, 0.25).set_delay(0.7)
	tw.chain().tween_callback(func(): _brownout_on = false)
	_maybe_sub(["Свет просел. На секунду стало совсем темно.", "Электричество здесь держится на честном слове."])


func _setup_dust(on: bool) -> void:
	## Slow dust motes drifting in a 12 m box around the camera (High / Ultra).
	if not on:
		if _dust != null and is_instance_valid(_dust):
			_dust.queue_free()
		_dust = null
		return
	if _dust != null and is_instance_valid(_dust):
		return
	_dust = GPUParticles3D.new()
	_dust.name = "Dust"
	_dust.amount = 420
	_dust.lifetime = 9.0
	_dust.preprocess = 6.0
	_dust.visibility_aabb = AABB(Vector3(-8, -4, -8), Vector3(16, 8, 16))
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(7, 2.2, 7)
	pm.direction = Vector3(0, -1, 0)
	pm.spread = 180.0
	pm.initial_velocity_min = 0.03
	pm.initial_velocity_max = 0.12
	pm.gravity = Vector3(0, -0.02, 0)
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = 0.25
	pm.turbulence_noise_scale = 3.0
	pm.scale_min = 0.5
	pm.scale_max = 1.0
	pm.color = Color(1.0, 0.95, 0.8, 0.55)
	_dust.process_material = pm
	var qm := QuadMesh.new()
	qm.size = Vector2(0.018, 0.018)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.albedo_color = Color(1.0, 0.95, 0.8, 0.4)
	mat.vertex_color_use_as_albedo = true
	mat.no_depth_test = false
	mat.distance_fade_mode = BaseMaterial3D.DISTANCE_FADE_PIXEL_ALPHA
	mat.distance_fade_min_distance = 0.3
	mat.distance_fade_max_distance = 0.0
	qm.material = mat
	_dust.draw_pass_1 = qm
	add_child(_dust)


func _start_lamp_buzzers() -> void:
	## A few broken tubes near the spawn buzz and sputter forever (3D loops).
	var lamps: Array = level.lamp_lights
	if lamps.is_empty():
		return
	var n := mini(4 + level_id * 3, lamps.size() / 6 + 1)
	var picked := {}
	for i in range(n):
		var idx := rng.randi_range(0, lamps.size() - 1)
		if picked.has(idx):
			continue
		picked[idx] = true
		var li: OmniLight3D = lamps[idx]
		var p := AudioBank.loop_3d("lamp_buzz", "Ambience", rng.randf_range(0.35, 0.6))
		if p != null:
			p.max_distance = 14.0
			p.unit_size = 3.0
			p.pitch_scale = rng.randf_range(0.92, 1.08)
			p.global_position = li.global_position
			_buzzers.append(p)
			li.set_meta("buzzing", true)


# ================================================================== events
func _on_noise(at: Vector3, radius: float) -> void:
	if monster != null:
		monster.hear(at, radius)


func _on_monster_state(s: String) -> void:
	if OS.get_environment("BR_DEBUG") == "1":
		print("DBG monster state -> ", s)
	match s:
		"APPROACH":
			bodycam.burst(0.3)


func _on_monster_attack() -> void:
	_kill_target(monster)


func _kill_target(who: Node3D) -> void:
	## Host side: `who` caught its current target. Tell everyone who died.
	if not Net.is_authority():
		return
	var victim: Player = who.player if ("player" in who) else player
	if victim == null or not is_instance_valid(victim) or not victim.alive:
		return
	var kind := "spider" if who is Spider else "monster"
	if OS.get_environment("BR_DEBUG") == "1":
		print("DBG kill: %s got peer %d" % [kind, victim.peer_id])
	Net.send_event("kill", [victim.peer_id, kind])
	if victim != player:
		# the victim runs its own death cam; here the creature just holds
		# the pose on them (guests see it through the puppet)
		if who == monster:
			monster.bite_remote(victim)
		elif who is Spider:
			(who as Spider).lunge_at_camera(victim.camera)
			get_tree().create_timer(2.0).timeout.connect(func():
					if is_instance_valid(who):
						who.set_physics_process(true))


func _die_by(who: Node3D) -> void:
	if state != State.PLAYING:
		return
	if inventory.is_open:
		inventory.close()
	if menus.current != menus.Screen.NONE:
		menus.show_screen(menus.Screen.NONE)
	state = State.DYING
	death_t = 0.0
	killer = who
	player.look_enabled = false
	if player.hidden:
		player.hidden = false
	player.kill()
	if OS.get_environment("BR_DEBUG") == "1":
		print("DBG attack by ", who.name, ": jumpscares=", GameSettings.jumpscares, " ts=", Engine.time_scale)
	if GameSettings.jumpscares and who != null:
		who.lunge_at_camera(player.camera)
		if who == monster:
			_build_jumpscare_face()
		Engine.time_scale = 0.35
		if OS.get_environment("BR_DEBUG") == "1":
			print("DBG attack: lunge done, ts=", Engine.time_scale, " js_face=", js_face != null)
	if who == monster:
		# THE scream: full-scale, on the Jumpscare bus (bypasses the Monster
		# volume slider, +6 dB, its own limiter) so it always slams
		AudioBank.play("jumpscare_scream", 1.0, randf_range(0.97, 1.03), "Jumpscare")
		AudioBank.play("jumpscare_scream", 0.7, 0.5, "Jumpscare")        # octave-down doubling
		AudioBank.play("stinger", 1.0, 0.8, "Jumpscare")
	else:
		AudioBank.play("spider_screech", 1.25, randf_range(1.05, 1.2), "Monster")
		AudioBank.play("stinger", 1.0, 1.0, "SFX")
	bodycam.burst(1.0)
	bodycam.set_damage(1.0)
	hud.set_warning("")
	_bite_n = 0


func _on_player_died() -> void:
	pass


var _dying_dbg := 0.0
var _bite_n := 0
var _bite_at := -9.0
func _tick_dying(delta: float) -> void:
	death_t += delta
	if OS.get_environment("BR_DEBUG") == "1":
		_dying_dbg -= delta
		if _dying_dbg <= 0.0:
			_dying_dbg = 0.4
			print("DBG dying t=%.2f ts=%.2f face=%s" % [death_t, Engine.time_scale, str(js_face != null and js_face.visible)])
	var is_mon := killer == monster and monster != null and is_instance_valid(monster)
	if is_mon:
		# the creature bites: face card flickers on every jaw snap
		# bite accents: a wet crunch + red flash + a few frames of the face
		# card each time the jaw slams shut (the 3D model does the biting)
		var bites_due := int(maxf(death_t - 0.30, 0.0) / 0.42) + (1 if death_t > 0.30 else 0)
		if js_face != null:
			js_face.visible = (death_t > 0.03 and death_t < 0.12) or (death_t - _bite_at < 0.07 and _bite_n > 0)
		if bites_due > _bite_n:
			_bite_n = bites_due
			_bite_at = death_t
			AudioBank.play_variant("step_monster", 1.3, randf_range(0.42, 0.55), "Jumpscare")
			AudioBank.play("noise_pulse", 1.0, randf_range(0.5, 0.7), "Jumpscare")
			bodycam.burst(0.9)
			bodycam.set_damage(1.0)
			player.camera.fov = 100.0
	elif js_face != null:
		js_face.visible = (death_t > 0.05 and death_t < 0.75) or (death_t > 1.15 and death_t < 1.35)
	if death_t > 0.75 and Engine.time_scale < 1.0:
		Engine.time_scale = 1.0
	var cam: Camera3D = player.camera
	var who: Node3D = killer if (killer != null and is_instance_valid(killer)) else monster
	if is_mon:
		# locked in its jaws: camera pinned to the face, violent shake
		# the head leans ~0.7 m forward during the bite (torso hunch + neck),
		# so take the real jaw pivot, not a fixed offset above the feet
		var mouth := who.global_position + Vector3(0, 3.08 * monster.model.MODEL_SCALE, 0)
		if monster.model.jaw != null:
			mouth = monster.model.jaw.global_position + Vector3(0, -0.05, 0)
		# the creature's face is on its +Z side (AI convention, see
		# monster._can_see_player): keep the camera in FRONT of the face
		var front := who.global_transform.basis.z
		front.y = 0.0
		front = front.normalized()
		var desired := mouth + front * lerpf(0.70, 0.42, clampf(death_t / 0.7, 0, 1))
		cam.global_position = cam.global_position.lerp(desired, delta * 12.0)
		cam.look_at(mouth, Vector3.UP)
		var sh := 0.06 + 0.05 * monster.model.bite_open
		cam.rotation.x += sin(death_t * 71.0) * sh
		cam.rotation.y += cos(death_t * 53.0) * sh
		cam.rotation.z += sin(death_t * 44.0) * sh * 1.5
		cam.fov = lerpf(cam.fov, 78.0, delta * 6.0)
	else:
		var target := who.global_position + Vector3(0, 1.5, 0)
		var desired := target + (cam.global_position - target).normalized() * lerpf(1.4, 0.55, clampf(death_t / 1.2, 0, 1))
		cam.global_position = cam.global_position.lerp(desired, delta * 7.0)
		cam.look_at(target, Vector3.UP)
		cam.rotation.z += sin(death_t * 34.0) * 0.04
		cam.fov = lerpf(cam.fov, 92.0, delta * 4.0)
	if death_t > 0.5 and death_t < 0.55:
		bodycam.burst(0.8)
	var end_t := 2.6 if is_mon else 1.9
	if death_t > end_t:
		state = State.DEAD
		Engine.time_scale = 1.0
		if js_face != null:
			js_face.visible = false
		if is_mon:
			monster.stop_biting()
		if _start_spectate():
			return
		print("DBG player dead, showing end screen kind=%s" % _end_kind)
		menus.set_end_screen(false, _time_str(), level_id, _end_kind)


func _activate_monster() -> void:
	if not Net.is_authority() or level == null or monster == null or not is_instance_valid(monster):
		return
	monster_active = true
	var d = level.data
	# wake up 18-45 m away from the player (world distance, map-agnostic)
	var best := Vector3.INF
	var best_d := 1e9
	for r in d.rooms:
		var c = d.grid_to_world(r)
		var dd = (c - player.global_position).length()
		if dd < 18.0 or dd > 45.0:
			continue
		if dd < best_d:
			best_d = dd
			best = c
	if best == Vector3.INF:
		best = d.monster_spawn
	monster.activate(best)
	if OS.get_environment("BR_DEBUG") == "1":
		print("DBG monster activated at ", best, " t=", run_time)
	# the crash that announces it (everybody hears it)
	Net.send_event("mon_wake")


func _announce_monster() -> void:
	monster_active = true
	AudioBank.play("distant_bang", 1.4, 0.75, "Ambience")
	AudioBank.play("stinger", 1.0, 0.95, "SFX")
	AudioBank.play("zap", 0.7, 0.7, "Ambience")
	bodycam.burst(0.7)
	if GameSettings.subtitles:
		hud.show_subtitle("Где-то далеко что-то обрушилось.", 4.0)


func _build_jumpscare_face() -> void:
	if js_face != null and is_instance_valid(js_face):
		return
	var tex: Texture2D = load("res://textures/jumpscare.png")
	if tex == null:
		return
	js_face = TextureRect.new()
	js_face.texture = tex
	js_face.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	js_face.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	js_face.mouse_filter = Control.MOUSE_FILTER_IGNORE
	js_face.visible = false
	hud.add_child(js_face)
	js_face.set_anchors_preset(Control.PRESET_FULL_RECT)


func _scare_for_target(kind: String) -> bool:
	## Host: the creature's intimidation plays on the screen of its target.
	## Returns true when the event was forwarded to another operator.
	if not Net.active or not Net.is_host or monster == null:
		return false
	var t: Player = monster.player
	if t == null or not is_instance_valid(t) or t == player:
		return false
	Net.send_event_to(t.peer_id, "mscare", [kind])
	return true


func _on_stalker_scare() -> void:
	if _scare_for_target("scare"):
		return
	if OS.get_environment("BR_DEBUG") == "1":
		print("DBG stalker scare fired")
	AudioBank.play("screech", 0.95, randf_range(1.05, 1.2), "Monster")
	AudioBank.play("stinger", 0.8, 1.2, "SFX")
	bodycam.burst(0.9)
	bodycam.set_damage(0.55)
	player.add_sanity(-25.0)


func _on_stare_started() -> void:
	if _scare_for_target("stare"):
		return
	if OS.get_environment("BR_DEBUG") == "1":
		print("DBG stare started, menace=", monster.menace)
	AudioBank.play("stinger", 0.4, 0.8, "SFX")
	bodycam.burst(0.35)
	player.add_sanity(-6.0)


func _on_vanished_close() -> void:
	if _scare_for_target("vanish"):
		return
	if OS.get_environment("BR_DEBUG") == "1":
		print("DBG vanished close, menace=", monster.menace)
	bodycam.burst(0.8)
	bodycam.set_damage(0.35)
	player.add_sanity(-14.0)


func _on_fake_attack() -> void:
	# the full death jumpscare -- but you wake up on the floor, alive
	if _scare_for_target("fake"):
		return
	if state != State.PLAYING:
		return
	if OS.get_environment("BR_DEBUG") == "1":
		print("DBG FAKE attack, menace=", monster.menace)
	if GameSettings.jumpscares:
		monster.lunge_at_camera(player.camera)
		_build_jumpscare_face()
		if js_face != null:
			js_face.visible = true
			get_tree().create_timer(0.35).timeout.connect(func():
					if js_face != null and is_instance_valid(js_face) and state == State.PLAYING:
						js_face.visible = false)
	AudioBank.play("jumpscare_scream", 0.8, randf_range(1.0, 1.08), "Jumpscare")
	AudioBank.play("stinger", 1.0, 1.0, "SFX")
	bodycam.burst(1.0)
	bodycam.set_damage(0.8)
	player.add_sanity(-30.0)
	get_tree().create_timer(0.6).timeout.connect(func():
			if monster != null and is_instance_valid(monster):
				monster.stop_biting())
	player.stamina = minf(player.stamina, 20.0)
	warn_txt = "СИГНАЛ ПОТЕРЯН"
	warn_t = 2.5
	if GameSettings.subtitles:
		hud.show_subtitle("...Ты ещё жив.", 4.0)


func _on_menace_changed(_v: int) -> void:
	pass


func _on_stalker_gone() -> void:
	if _scare_for_target("gone"):
		return
	if OS.get_environment("BR_DEBUG") == "1":
		print("DBG stalker vanished (player looked)")
	AudioBank.play("whisper", 0.5, 0.75, "Monster")
	bodycam.burst(0.35)
	player.add_sanity(-8.0)


# ================================================================== phantom
func _on_phantom_scare(kind: String) -> void:
	if OS.get_environment("BR_DEBUG") == "1":
		print("DBG phantom: ", kind)
	match kind:
		"behind":
			bodycam.burst(0.3)
		"growl_behind":
			bodycam.burst(0.4)
			player.add_sanity(-6.0)
		"steps_behind":
			player.add_sanity(-5.0)
		"charge":
			bodycam.burst(0.5)
		"charge_vanish":
			player.add_sanity(-18.0)
			bodycam.set_damage(0.45)
		"behind_vanish":
			player.add_sanity(-14.0)
			bodycam.set_damage(0.3)
		"peek_vanish", "glimpse_vanish":
			player.add_sanity(-8.0)
			bodycam.burst(0.45)
			AudioBank.play("whisper", 0.5, 0.8, "Monster")


func _on_phantom_jumpscare() -> void:
	if not GameSettings.jumpscares:
		return
	_build_jumpscare_face()
	if js_face != null:
		js_face.visible = true
		bodycam.burst(1.0)
		AudioBank.play("screech", 1.1, randf_range(1.05, 1.2), "Monster")
		get_tree().create_timer(0.22).timeout.connect(func():
				if js_face != null and is_instance_valid(js_face) and state == State.PLAYING:
					js_face.visible = false)


# ================================================================== objective
func on_subtitle(t: String) -> void:
	hud.show_subtitle(t, 4.0)


func exit_unlocked() -> void:
	exit_open = true
	bodycam.burst(0.3)


func win_game(kind := "") -> void:
	if state != State.PLAYING and state != State.SPECTATE:
		return
	Net.send_event("win", [kind])


func _do_win(kind: String) -> void:
	if state != State.PLAYING and state != State.SPECTATE:
		return
	if Net.active and director != null and is_instance_valid(director) and director.has_method("on_crew_win"):
		director.on_crew_win()
	_end_kind = kind
	state = State.WIN
	win_t = 0.0
	AudioBank.play("door", 1.0)
	bodycam.burst(0.7)
	hud.set_warning("")


var _end_kind := ""            # "" | "run" (Level 4 light) | "fall" (Level 3 chasm)
var _fall_t := -1.0
func fall_ending(stage: Vector3 = Vector3.INF) -> void:
	## v9: the player stepped into the chasm tunnel. A short scripted fall
	## (camera tumbles, wind, the light shrinks) and a dedicated end screen.
	## `stage` = top of the render-layer-2 shaft the level built for this.
	if state != State.PLAYING:
		return
	_end_kind = "fall"
	state = State.WIN               # freezes the gameplay tick like a win
	win_t = -99.0                   # end screen is shown by _tick_fall instead
	_fall_t = 0.0
	if Net.active:
		Net.send_event("fell", [Net.my_id()])
	player.look_enabled = false
	player.alive = false            # no input / footsteps; gravity still off (alive=false zeroes velocity)
	player.velocity = Vector3.ZERO
	player.shake = 0.0
	player.set_flashlight(false)
	if stage != Vector3.INF:
		player.global_position = stage + Vector3(0, -3.0, 0)   # camera (1.6 m up) starts inside the shaft
		player.camera.cull_mask = 1 << 1
		player.camera.rotation = Vector3(0.9, 0.0, 0.0)
		player.pitch = 0.9
	hud.set_prompt("")
	hud.set_warning("")
	AudioBank.play("fall_wind", 1.0, 1.0, "SFX")
	AudioBank.play("stinger", 0.7, 0.7, "SFX")
	bodycam.burst(0.9)
	_ensure_fade()
	_fade_rect.color = Color(0, 0, 0, 0)
	_fade_rect.visible = true
	print("DBG fall ending started")


func _tick_fall(delta: float) -> void:
	_fall_t += delta
	var t := _fall_t
	# the body drops, accelerating; the camera pitches down and rolls
	player.global_position.y -= (4.0 + 14.0 * t) * delta
	var cam: Camera3D = player.camera
	# looks up at the shrinking red mouth first, then tumbles
	var want_pitch := 1.25 if t < 1.1 else -0.9
	cam.rotation.x = lerpf(cam.rotation.x, want_pitch, delta * 3.0) + sin(t * 19.0) * 0.04
	cam.rotation.z += delta * (0.3 + t * 0.9) + sin(t * 13.0) * 0.02
	cam.fov = lerpf(cam.fov, 100.0, delta * 2.0)
	_fade_rect.color.a = clampf((t - 0.9) / 1.3, 0.0, 1.0)
	if t > 1.0 and t < 1.05:
		bodycam.burst(0.7)
	if t > 2.6:
		_fall_t = -1.0
		state = State.DEAD
		player.camera.cull_mask = 0xFFFFF
		_fade_rect.visible = false
		_fade_rect.color.a = 0.0
		if _start_spectate():
			return
		print("DBG fall end screen shown")
		menus.set_end_screen(false, _time_str(), level_id, "fall")


func _time_str() -> String:
	var s := int(run_time + total_time)
	return "%02d:%02d" % [s / 60, s % 60]


# ================================================================== v10: co-op
func _slot_index(id: int) -> int:
	if not Net.active:
		return 0
	return Net.peer_ids().find(id)


func _spawn_slot(base: Vector3, yaw: float, i: int) -> Vector3:
	## Operators start shoulder to shoulder behind the spawn point.
	if i <= 0:
		return base
	var right := Vector3(cos(yaw), 0, -sin(yaw))
	var back := Vector3(sin(yaw), 0, cos(yaw))
	var offs := [Vector3.ZERO, right * 0.9, -right * 0.9, back * 1.0]
	var p: Vector3 = base + offs[mini(i, 3)]
	if level != null and level.has_method("nearest_walkable"):
		p = level.nearest_walkable(p)
	return p


func _free_remotes() -> void:
	for id in remotes.keys():
		var r: Node = remotes[id]
		if r != null and is_instance_valid(r):
			r.queue_free()
	remotes.clear()


func all_players() -> Array:
	## Every operator in this world, local first.
	var out: Array = []
	if player != null and is_instance_valid(player):
		out.append(player)
	for id in remotes.keys():
		var r: Node = remotes[id]
		if r != null and is_instance_valid(r):
			out.append(r)
	return out


func living_players() -> Array:
	var out: Array = []
	for p in all_players():
		if p.alive:
			out.append(p)
	return out


func player_by_id(id: int) -> Player:
	if player != null and player.peer_id == id:
		return player
	if remotes.has(id):
		return remotes[id]
	return null


func nearest_living_player(from: Vector3, exclude_hidden := false) -> Player:
	var best: Player = null
	var bd := 1e9
	for p in living_players():
		if exclude_hidden and p.hidden:
			continue
		var d: float = from.distance_to(p.global_position)
		if d < bd:
			bd = d
			best = p
	return best


func _update_crew_hud() -> void:
	if hud == null:
		return
	if not Net.active:
		hud.set_crew([])
		return
	var lines: Array = []
	var i := 1
	for id in Net.peer_ids():
		var p := player_by_id(id)
		var alive := p != null and p.alive
		var me := "  ←" if id == Net.my_id() else ""
		lines.append("CAM %02d %s %s%s" % [i, "●" if alive else "■", Net.peer_name(id), me])
		i += 1
	hud.set_crew(lines)


# ---- events (reliable, everyone) -------------------------------------------
func net_event(kind: String, a: Array, from: int) -> void:
	match kind:
		"door_used":
			_do_door_used()
		"win":
			_do_win(str(a[0]) if a.size() > 0 else "")
		"kill":
			_apply_kill(int(a[0]), str(a[1]))
		"fell":
			var p := player_by_id(int(a[0]))
			if p != null and p != player and p.alive:
				p.remote_die()
				hud.show_subtitle("%s: КАМЕРА ПАДАЕТ. СИГНАЛ ПОТЕРЯН." % p.nick, 4.0)
				_update_crew_hud()
		"pick":
			_apply_pick(str(a[0]), str(a[1]), from)
		"mon_wake":
			_announce_monster()
		"mscare":
			_apply_scare(str(a[0]))
		"dir":
			# scripted-level director event (phase changes), replayed by the guests
			if director != null and is_instance_valid(director) and director.has_method("net_apply"):
				director.net_apply(a, from)
		"noise":
			if Net.is_authority() and monster != null and from != Net.my_id():
				monster.hear(a[0], float(a[1]))
		"sfx":
			# a 3D one-shot another operator made (dig, crate lid, ...)
			if from != Net.my_id():
				AudioBank.play_variant_3d(str(a[0]), a[1], float(a[2]), float(a[3]), "SFX")
		"subtitle":
			hud.show_subtitle(str(a[0]), float(a[1]) if a.size() > 1 else 4.0)
		"objective":
			hud.set_objective(str(a[0]))
		_:
			pass


func make_noise(at: Vector3, radius: float) -> void:
	## Non-footstep noise (digging): reaches the host's creature from any peer.
	_on_noise(at, radius)
	if Net.active and not Net.is_host:
		Net.send_event("noise", [at, radius])


func dir_event(a: Array) -> void:
	## Scripted-level directors broadcast their phase changes through here.
	Net.send_event("dir", a)


func world_running() -> bool:
	return state == State.PLAYING or state == State.SPECTATE


func _apply_kill(id: int, kind: String) -> void:
	var who: Node3D = monster
	if kind == "spider":
		var sp: Node = get_tree().get_first_node_in_group("spider")
		if sp != null:
			who = sp
	if id == Net.my_id():
		if state == State.PLAYING:
			_die_by(who)
	else:
		var p := player_by_id(id)
		if p != null and p.alive:
			p.remote_die()
			# the far scream: you hear your partner go
			AudioBank.play_3d("jumpscare_scream" if kind == "monster" else "spider_screech", p.global_position + Vector3(0, 1.5, 0), 0.8, 0.9, "Monster")
			bodycam.burst(0.5)
			hud.show_subtitle("%s: ЗАПИСЬ ПРЕРВАНА." % p.nick, 4.0)
	_update_crew_hud()
	# nobody left: game over for the whole crew
	if Net.active and living_players().is_empty() and state == State.SPECTATE:
		state = State.DEAD
		menus.set_end_screen(false, _time_str(), level_id, _end_kind)


func _apply_pick(pname: String, kind: String, from: int) -> void:
	var n: Node = get_node_or_null(pname)
	if n != null and is_instance_valid(n) and not n.is_queued_for_deletion():
		if from != Net.my_id():
			AudioBank.play_3d("pickup", (n as Node3D).global_position, 0.5, 1.0, "SFX")
		n.queue_free()
	if kind == "key":
		# the key is shared: whoever holds it can open the door for everyone
		if from == Net.my_id():
			add_to_inventory("key")
		else:
			var p := player_by_id(from)
			hud.show_subtitle("%s подобрал ржавый ключ." % (p.nick if p != null else "Напарник"), 3.5)
	elif from == Net.my_id():
		add_to_inventory(kind)


func _apply_scare(kind: String) -> void:
	## The creature is working on ME (host forwarded its intimidation).
	if state != State.PLAYING:
		return
	match kind:
		"scare":
			AudioBank.play("screech", 0.95, randf_range(1.05, 1.2), "Monster")
			AudioBank.play("stinger", 0.8, 1.2, "SFX")
			bodycam.burst(0.9)
			bodycam.set_damage(0.55)
			player.add_sanity(-25.0)
		"stare":
			AudioBank.play("stinger", 0.4, 0.8, "SFX")
			bodycam.burst(0.35)
			player.add_sanity(-6.0)
		"vanish":
			bodycam.burst(0.8)
			bodycam.set_damage(0.35)
			player.add_sanity(-14.0)
		"gone":
			AudioBank.play("whisper", 0.5, 0.75, "Monster")
			bodycam.burst(0.35)
			player.add_sanity(-8.0)
		"fake":
			if GameSettings.jumpscares and monster != null:
				monster.lunge_at_camera(player.camera)
				_build_jumpscare_face()
				if js_face != null:
					js_face.visible = true
					get_tree().create_timer(0.35).timeout.connect(func():
							if js_face != null and is_instance_valid(js_face):
								js_face.visible = false)
				get_tree().create_timer(0.6).timeout.connect(func():
						if monster != null and is_instance_valid(monster):
							monster.stop_biting())
			AudioBank.play("jumpscare_scream", 0.8, randf_range(1.0, 1.08), "Jumpscare")
			AudioBank.play("stinger", 1.0, 1.0, "SFX")
			bodycam.burst(1.0)
			bodycam.set_damage(0.8)
			player.add_sanity(-30.0)
			player.stamina = minf(player.stamina, 20.0)
			warn_txt = "СИГНАЛ ПОТЕРЯН"
			warn_t = 2.5
			if GameSettings.subtitles:
				hud.show_subtitle("...Ты ещё жив.", 4.0)


# ---- state streams (unreliable, 20 Hz) ---------------------------------------
func _tick_net(delta: float) -> void:
	if not Net.active or player == null or not is_instance_valid(player):
		return
	if state != State.PLAYING and state != State.SPECTATE and state != State.DYING:
		return
	if _transition_t >= 0.0:
		return
	_net_send_t -= delta
	if _net_send_t > 0.0:
		return
	_net_send_t = 1.0 / Net.SEND_HZ
	Net.send_player_state(player.global_position, player.yaw, player.pitch, player.net_flags(), player.velocity)
	if Net.is_host and monster != null and is_instance_valid(monster):
		var tid: int = monster.player.peer_id if (monster.player != null and is_instance_valid(monster.player)) else 0
		var mflags := 0
		if monster.visible:
			mflags |= 1
		if monster.dormant:
			mflags |= 2
		if monster.sees_player:
			mflags |= 4
		if monster.biting:
			mflags |= 8
		if monster_active:
			mflags |= 16
		Net.send_monster_state(0, monster.global_position, monster.rotation.y, monster.state, monster.velocity,
				tid, monster.awareness, mflags, monster.menace)
		var sp: Node = get_tree().get_first_node_in_group("spider")
		if sp != null and is_instance_valid(sp):
			var stid: int = sp.player.peer_id if (sp.player != null and is_instance_valid(sp.player)) else 0
			var sflags := 1 if sp.visible else 0
			Net.send_monster_state(1, sp.global_position, sp.rotation.y, sp.state, sp.velocity, stid, 0.0, sflags, 0)
	# the creature hunts whoever is closest (host only)
	if Net.is_host:
		_retarget_t -= delta
		if _retarget_t <= 0.0:
			_retarget_t = 0.5
			_retarget_ai()
	if OS.get_environment("BR_DEBUG") == "1":
		_net_dbg_t -= delta
		if _net_dbg_t <= 0.0:
			_net_dbg_t = 2.0
			var rs := ""
			for id in remotes.keys():
				var r: Player = remotes[id]
				rs += " r%d=(%.1f,%.1f)%s" % [id, r.global_position.x, r.global_position.z, "" if r.alive else "†"]
			print("NETDBG me=%d state=%s pos=(%.1f,%.1f) mon=%s@(%.1f,%.1f) tgt=%s%s" % [Net.my_id(), State.keys()[state],
					player.global_position.x, player.global_position.z,
					monster.State.keys()[monster.state] if monster != null else "-",
					monster.global_position.x if monster != null else 0.0, monster.global_position.z if monster != null else 0.0,
					str(monster.player.peer_id) if (monster != null and monster.player != null) else "-", rs])


func _retarget_ai() -> void:
	if monster == null or not is_instance_valid(monster):
		return
	var cur: Player = monster.player
	var cur_ok := cur != null and is_instance_valid(cur) and cur.alive
	# locked on while chasing / staring: switch only when the target dies
	# or somebody else walks right into it
	var best := nearest_living_player(monster.global_position, monster.state == monster.State.WANDER)
	if best == null:
		return
	if cur_ok and (monster.state == monster.State.CHASE or monster.state == monster.State.STARE
			or monster.state == monster.State.APPROACH or monster.state == monster.State.AMBUSH or monster.state == monster.State.STALK):
		var dc: float = monster.global_position.distance_to(cur.global_position)
		var db: float = monster.global_position.distance_to(best.global_position)
		if db > dc * 0.5 or db > 6.0:
			return
	if best != cur:
		monster.player = best
		if OS.get_environment("BR_DEBUG") == "1":
			print("DBG monster retarget -> peer %d" % best.peer_id)
	var sp: Node = get_tree().get_first_node_in_group("spider")
	if sp != null and is_instance_valid(sp):
		var sc: Player = sp.player
		var sc_ok := sc != null and is_instance_valid(sc) and sc.alive
		var sbest := nearest_living_player(sp.global_position, true)
		if sbest == null:
			sbest = nearest_living_player(sp.global_position, false)
		if sbest != null and (not sc_ok or sp.state != sp.State.CHASE or not sc_ok):
			if sbest != sc:
				sp.player = sbest
		elif sbest != null and sc_ok and sc.hidden and not sbest.hidden:
			sp.player = sbest


func net_player_state(id: int, pos: Vector3, yaw: float, pitch: float, flags: int, vel: Vector3) -> void:
	var r: Player = remotes.get(id)
	if r == null or not is_instance_valid(r):
		return
	if _transition_t >= 0.0:
		return
	r.net_apply(pos, yaw, pitch, flags, vel)


func net_monster_state(kind: int, pos: Vector3, yaw: float, st: int, vel: Vector3, target: int, aware: float, flags: int, extra: int) -> void:
	if Net.is_host:
		return
	if kind == 0:
		if monster == null or not is_instance_valid(monster):
			return
		if (flags & 16) != 0 and not monster_active:
			monster_active = true
		monster.puppet_apply(pos, yaw, st, vel, aware, flags, extra)
		var t := player_by_id(target)
		if t != null:
			monster.player = t
	else:
		var sp: Node = get_tree().get_first_node_in_group("spider")
		if sp != null and is_instance_valid(sp) and sp.has_method("puppet_apply"):
			sp.puppet_apply(pos, yaw, st, vel, flags)
			var t := player_by_id(target)
			if t != null:
				sp.player = t


# ---- spectating ---------------------------------------------------------------
func _start_spectate() -> bool:
	## Dead in co-op: watch a living partner's camera. False = nobody left.
	if not Net.active:
		return false
	_update_crew_hud()
	if living_players().is_empty():
		return false
	state = State.SPECTATE
	Engine.time_scale = 1.0
	player.look_enabled = false
	player.camera.fov = GameSettings.fov
	if js_face != null and is_instance_valid(js_face):
		js_face.visible = false
	bodycam.set_damage(0.0)
	hud.set_prompt("")
	hud.set_warning("")
	spectating = 0
	_spectate_next()
	hud.show_subtitle("Твоя плёнка кончилась. Смотри глазами напарника: ЛКМ / E — другая камера.", 5.0)
	return true


func _spectate_next() -> void:
	var ids: Array = []
	for p in living_players():
		if p != player:
			ids.append(p.peer_id)
	if ids.is_empty():
		spectating = 0
		hud.set_spectating("")
		if state == State.SPECTATE:
			state = State.DEAD
			menus.set_end_screen(false, _time_str(), level_id, _end_kind)
		return
	ids.sort()
	var i: int = ids.find(spectating)
	spectating = ids[(i + 1) % ids.size()]
	var t := player_by_id(spectating)
	hud.set_spectating("● КАМЕРА: %s  ·  ЛКМ / E — ПЕРЕКЛЮЧИТЬ" % (t.nick if t != null else "?"))
	bodycam.burst(0.6)
	AudioBank.play("click", 0.6, 0.8, "UI")


func _tick_spectate(delta: float) -> void:
	run_time += delta
	if not monster_active and run_time >= _grace_override * 60.0 and Net.is_authority():
		_activate_monster()
	var t := player_by_id(spectating)
	if t == null or not is_instance_valid(t) or not t.alive:
		_spectate_next()
		t = player_by_id(spectating)
		if t == null:
			return
	# our own camera rides on the partner's head: their yaw / pitch, their torch
	var cam: Camera3D = player.camera
	var head: Vector3 = t.neck.global_position
	cam.global_position = cam.global_position.lerp(head + Vector3(0, 0.02, 0), clampf(delta * 18.0, 0.0, 1.0))
	var want := Basis.from_euler(Vector3(t.pitch, t.yaw, 0.0))
	cam.global_transform.basis = cam.global_transform.basis.slerp(want, clampf(delta * 16.0, 0.0, 1.0))
	if player.flashlight != null:
		player.flashlight.light_energy = 1.7 if t.flashlight_on else 0.0
	t.set_body_visible(false)
	t.flashlight.visible = false          # ours stands in for it
	for p in all_players():
		if p != t and p != player:
			p.set_body_visible(true)
			p.flashlight.visible = true
	level.update_focus(t.global_position, delta)
	# their fear is our static
	var threat_pos := monster.global_position if monster != null else Vector3.INF
	if director != null and is_instance_valid(director):
		var tp: Vector3 = director.threat_position()
		if tp != Vector3.INF:
			threat_pos = tp
	var d_mon: float = t.global_position.distance_to(threat_pos) if threat_pos != Vector3.INF else 99.0
	var prox := clampf(1.0 - d_mon / 9.0, 0.0, 1.0)
	fear = clampf(prox * prox * 0.6 + 0.12, 0.0, 1.0)
	bodycam.set_fear(fear)
	bodycam.set_exposure(1.0 if level.is_lit_at(t.global_position) else 1.3)
	hud.set_batteries(t.flash_battery, t.cam_battery)
	hud.set_vitals(t.stamina, t.sanity)
	if level != null and level.has_method("door_world_position"):
		var tgt: Vector3 = level.door_world_position()
		if director != null and is_instance_valid(director) and director.has_method("radar_target"):
			tgt = director.radar_target()
		var dvec: Vector3 = tgt - t.global_position
		dvec.y = 0.0
		var lv: Vector3 = Basis(Vector3.UP, t.yaw).inverse() * dvec
		hud.set_radar(Vector2(lv.x, -lv.z), dvec.length(), door_locked(), true)
	hud.set_warning("")
