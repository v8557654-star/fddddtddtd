class_name RunLevel
extends Node3D
## Level 4 -- "БЕГИ ИЛИ УМРИ". A fully procedural service tunnel: one long
## straight corridor, red emergency lamps, a white light at the far end.
## Exposes the same "level API" as CustomMap (grid, nav, lamps, door) so the
## creature, the spider, the phantom and main.gd work unchanged.

const CELL := 0.75
const LENGTH := 150.0        # metres from spawn to the light
const BACK := 22.0           # metres of tunnel behind the spawn (where they come from)
const WIDTH := 3.4
const HEIGHT := 3.6

var def: Dictionary = {}
var level_id := 4
var data: CustomMap.CMapData = CustomMap.CMapData.new()
var astar: AStarGrid2D = null
var lights_on: Array[Vector3] = []
var lamp_lights: Array[OmniLight3D] = []
var lamp_panels: Array[MeshInstance3D] = []
var rng := RandomNumberGenerator.new()
var door: Node3D = null
var spawn_yaw := 0.0
var glb_shift := Vector3.ZERO
var glb_scale := 1.0

var mat_concrete: StandardMaterial3D
var mat_floor: StandardMaterial3D
var mat_beam: StandardMaterial3D
var mat_lamp: StandardMaterial3D
var gate_light: OmniLight3D = null
var gate_glow: OmniLight3D = null
var gate_pos := Vector3(0, 0, -LENGTH)


func build(seedv: int = -1, lvl: int = 4) -> void:
	level_id = lvl
	def = LevelDefs.get_def(lvl)
	if seedv >= 0:
		rng.seed = seedv + lvl * 7919
	else:
		rng.randomize()
	_materials()
	_grid()
	_shell()
	_dressing()
	_lamps()
	_gate()
	apply_graphics()


# ------------------------------------------------------------------ build
func _materials() -> void:
	mat_concrete = StandardMaterial3D.new()
	mat_concrete.albedo_texture = load("res://textures/concrete.png")
	mat_concrete.normal_texture = load("res://textures/concrete_n.png")
	mat_concrete.normal_enabled = true
	mat_concrete.albedo_color = Color(0.62, 0.60, 0.56)
	mat_concrete.roughness = 0.95
	mat_concrete.uv1_scale = Vector3(0.5, 0.5, 0.5)
	mat_concrete.uv1_triplanar = true
	mat_floor = mat_concrete.duplicate()
	mat_floor.albedo_color = Color(0.40, 0.39, 0.37)
	mat_floor.uv1_scale = Vector3(0.7, 0.7, 0.7)
	mat_beam = StandardMaterial3D.new()
	mat_beam.albedo_texture = load("res://textures/metal.png")
	mat_beam.normal_texture = load("res://textures/metal_n.png")
	mat_beam.normal_enabled = true
	mat_beam.albedo_color = Color(0.30, 0.27, 0.24)
	mat_beam.roughness = 0.7
	mat_beam.metallic = 0.4
	mat_beam.uv1_scale = Vector3(2.0, 2.0, 2.0)
	mat_beam.uv1_triplanar = true
	mat_lamp = StandardMaterial3D.new()
	mat_lamp.albedo_color = Color(0.5, 0.08, 0.05)
	mat_lamp.emission_enabled = true
	mat_lamp.emission = Color(1.0, 0.16, 0.08)
	mat_lamp.emission_energy_multiplier = 2.2


func _grid() -> void:
	var gw := 5
	var gh := int(ceil((LENGTH + BACK + 8.0) / CELL))
	data.gw = gw
	data.gh = gh
	data.origin = Vector3(-gw * CELL * 0.5, 0.0, -LENGTH - 4.0)
	data.solid.resize(gw * gh)
	data.floor_h.resize(gw * gh)
	data.ceil_h.resize(gw * gh)
	data.zone.resize(gw * gh)
	data.floor_h.fill(0.0)
	data.ceil_h.fill(HEIGHT)
	data.zone.fill(CustomMap.CMapData.Zone.LIT)
	for y in range(gh):
		for x in range(gw):
			var c := data.grid_to_world(Vector2i(x, y))
			var free := absf(c.x) <= WIDTH * 0.5 - 0.45 and c.z >= -LENGTH + 0.3 and c.z <= BACK - 0.8
			var i := data.idx(x, y)
			data.solid[i] = 0 if free else 1
			if free:
				data.rooms.append(Vector2i(x, y))
	astar = AStarGrid2D.new()
	astar.region = Rect2i(0, 0, gw, gh)
	astar.cell_size = Vector2.ONE
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_MANHATTAN
	astar.update()
	for y in range(gh):
		for x in range(gw):
			if data.solid[data.idx(x, y)] == 1:
				astar.set_point_solid(Vector2i(x, y), true)
	data.player_spawn = Vector3(0, 0.15, 0)
	data.monster_spawn = Vector3(0, 0.05, BACK - 6.0)
	data.exit_point = _clamp_grid(data.world_to_grid(Vector3(0, 0, -LENGTH + 0.6)))
	data.water_points.clear()
	data.battery_points.clear()
	spawn_yaw = 0.0        # facing -Z: down the tunnel, towards the light


func _box(parent: Node, size: Vector3, pos: Vector3, mat: Material, collide := true, body: StaticBody3D = null) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	bm.material = mat
	mi.mesh = bm
	mi.position = pos
	parent.add_child(mi)
	if collide and body != null:
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = size
		cs.shape = bs
		cs.position = pos
		body.add_child(cs)
	return mi


func _shell() -> void:
	var shell := Node3D.new()
	shell.name = "Shell"
	add_child(shell)
	var body := StaticBody3D.new()
	body.name = "MapBody"
	shell.add_child(body)
	var total := LENGTH + BACK + 4.0
	var zc := (-LENGTH + BACK) * 0.5
	var hw := WIDTH * 0.5
	# floor / ceiling / walls in 30 m slabs (keeps the triplanar UVs sane and
	# lets the renderer cull what is behind you)
	var seg := 30.0
	var z := -LENGTH - 2.0
	while z < BACK + 2.0:
		var ln := minf(seg, BACK + 2.0 - z)
		var zm := z + ln * 0.5
		_box(shell, Vector3(WIDTH + 0.6, 0.3, ln), Vector3(0, -0.15, zm), mat_floor, true, body)
		_box(shell, Vector3(WIDTH + 0.6, 0.3, ln), Vector3(0, HEIGHT + 0.15, zm), mat_concrete, true, body)
		_box(shell, Vector3(0.3, HEIGHT + 0.6, ln), Vector3(-hw - 0.15, HEIGHT * 0.5, zm), mat_concrete, true, body)
		_box(shell, Vector3(0.3, HEIGHT + 0.6, ln), Vector3(hw + 0.15, HEIGHT * 0.5, zm), mat_concrete, true, body)
		z += ln
	# back wall with a black mouth (where you came from -- and where they come from)
	_box(shell, Vector3(WIDTH + 0.6, HEIGHT + 0.6, 0.3), Vector3(0, HEIGHT * 0.5, BACK + 0.15), mat_concrete, true, body)
	var mouth := MeshInstance3D.new()
	var mm := PlaneMesh.new()
	mm.size = Vector2(2.4, 2.8)
	var black := StandardMaterial3D.new()
	black.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	black.albedo_color = Color(0, 0, 0)
	black.cull_mode = BaseMaterial3D.CULL_DISABLED
	mm.material = black
	mouth.mesh = mm
	mouth.rotation_degrees.x = 90.0
	mouth.rotation_degrees.y = 180.0
	mouth.position = Vector3(0, 1.4, BACK - 0.02)
	shell.add_child(mouth)
	# ribs: a steel beam across the ceiling + pilasters every 6 m
	var n := int(total / 6.0)
	for i in range(n + 1):
		var bz := BACK - 3.0 - i * 6.0
		if bz < -LENGTH + 1.0:
			break
		_box(shell, Vector3(WIDTH, 0.28, 0.32), Vector3(0, HEIGHT - 0.14, bz), mat_beam, false)
		_box(shell, Vector3(0.22, HEIGHT, 0.32), Vector3(-hw + 0.11, HEIGHT * 0.5, bz), mat_beam, true, body)
		_box(shell, Vector3(0.22, HEIGHT, 0.32), Vector3(hw - 0.11, HEIGHT * 0.5, bz), mat_beam, true, body)
	# two rusty pipes along the right wall, a cable tray on the left
	for k in range(2):
		var pipe := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.09
		cm.bottom_radius = 0.09
		cm.height = total
		cm.radial_segments = 8
		var pm := mat_beam.duplicate()
		pm.albedo_color = Color(0.34, 0.20, 0.12)
		cm.material = pm
		pipe.mesh = cm
		pipe.rotation_degrees.x = 90.0
		pipe.position = Vector3(hw - 0.35, HEIGHT - 0.55 - k * 0.28, zc)
		shell.add_child(pipe)
	_box(shell, Vector3(0.30, 0.06, total), Vector3(-hw + 0.35, HEIGHT - 0.45, zc), mat_beam, false)


func _dressing() -> void:
	# concrete chunks along the walls (no collision: they never catch a foot)
	var root := Node3D.new()
	root.name = "Debris"
	add_child(root)
	var crng := RandomNumberGenerator.new()
	crng.seed = rng.seed + 77
	var chunk := mat_concrete.duplicate()
	chunk.albedo_color = Color(0.5, 0.48, 0.45)
	for i in range(70):
		var s := crng.randf_range(0.18, 0.55)
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(s, s * crng.randf_range(0.4, 0.8), s * crng.randf_range(0.7, 1.3))
		bm.material = chunk
		mi.mesh = bm
		var side := -1.0 if crng.randf() < 0.5 else 1.0
		mi.position = Vector3(side * crng.randf_range(WIDTH * 0.5 - 0.6, WIDTH * 0.5 - 0.15),
				bm.size.y * 0.5, crng.randf_range(-LENGTH + 2.0, BACK - 2.0))
		mi.rotation.y = crng.randf_range(0.0, TAU)
		mi.rotation.z = crng.randf_range(-0.2, 0.2)
		mi.visibility_range_end = 60.0
		root.add_child(mi)


func _lamps() -> void:
	var step: float = float(def.get("lamp_step", 6.0))
	var on_chance: float = def.get("lamp_on", 0.8)
	var z := BACK - 6.0
	while z > -LENGTH + 2.0:
		var on := rng.randf() < on_chance
		var pn := MeshInstance3D.new()
		var pm := BoxMesh.new()
		pm.size = Vector3(0.9, 0.12, 0.3)
		pm.material = mat_lamp
		pn.mesh = pm
		pn.position = Vector3(0.0, HEIGHT - 0.06, z)
		pn.visible = on
		pn.visibility_range_end = 90.0
		add_child(pn)
		if on:
			var li := OmniLight3D.new()
			li.light_color = Color(1.0, 0.14, 0.08)
			li.light_energy = float(def.get("lamp_energy", 2.4))
			li.omni_range = 9.0
			li.omni_attenuation = 1.3
			li.shadow_enabled = false
			li.distance_fade_enabled = true
			li.distance_fade_begin = 38.0
			li.distance_fade_length = 12.0
			li.position = Vector3(0.0, HEIGHT - 0.4, z)
			li.set_meta("lamp_i", lamp_lights.size())
			add_child(li)
			lamp_lights.append(li)
			lamp_panels.append(pn)
			lights_on.append(Vector3(0.0, 1.4, z))
		z -= step


func _gate() -> void:
	## The white light at the end: an opening in the end wall, a blinding
	## unshaded panel behind it and two lights so it glows down the tunnel.
	var g := Node3D.new()
	g.name = "Gate"
	add_child(g)
	var body := StaticBody3D.new()
	g.add_child(body)
	var hw := WIDTH * 0.5
	# end wall pieces around a 2.2 x 2.7 doorway
	_box(g, Vector3(0.6 + 0.3, HEIGHT + 0.6, 0.3), Vector3(-hw + 0.15, HEIGHT * 0.5, -LENGTH - 0.15), mat_concrete, true, body)
	_box(g, Vector3(0.6 + 0.3, HEIGHT + 0.6, 0.3), Vector3(hw - 0.15, HEIGHT * 0.5, -LENGTH - 0.15), mat_concrete, true, body)
	_box(g, Vector3(WIDTH + 0.6, HEIGHT - 2.7 + 0.3, 0.3), Vector3(0, HEIGHT - (HEIGHT - 2.7) * 0.5 + 0.15, -LENGTH - 0.15), mat_concrete, true, body)
	# the light itself: a short bright vestibule
	var white := StandardMaterial3D.new()
	white.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	white.albedo_color = Color(1.0, 0.98, 0.94)
	white.emission_enabled = true
	white.emission = Color(1.0, 0.98, 0.94)
	white.emission_energy_multiplier = 6.0
	var panel := MeshInstance3D.new()
	var pm := BoxMesh.new()
	pm.size = Vector3(2.2, 2.7, 0.05)
	pm.material = white
	panel.mesh = pm
	panel.position = Vector3(0, 1.35, -LENGTH - 1.6)
	g.add_child(panel)
	_box(g, Vector3(2.4, 0.1, 1.8), Vector3(0, -0.05, -LENGTH - 0.9), mat_floor, true, body)
	_box(g, Vector3(0.1, 2.8, 1.8), Vector3(-1.15, 1.35, -LENGTH - 0.9), mat_concrete, true, body)
	_box(g, Vector3(0.1, 2.8, 1.8), Vector3(1.15, 1.35, -LENGTH - 0.9), mat_concrete, true, body)
	_box(g, Vector3(2.4, 0.1, 1.8), Vector3(0, 2.75, -LENGTH - 0.9), mat_concrete, true, body)
	gate_light = OmniLight3D.new()
	gate_light.light_color = Color(1.0, 0.97, 0.9)
	gate_light.light_energy = 9.0
	gate_light.omni_range = 30.0
	gate_light.omni_attenuation = 1.0
	gate_light.shadow_enabled = false
	gate_light.position = Vector3(0, 1.6, -LENGTH - 0.6)
	g.add_child(gate_light)
	gate_glow = OmniLight3D.new()
	gate_glow.light_color = Color(1.0, 0.97, 0.9)
	gate_glow.light_energy = 3.0
	gate_glow.omni_range = 40.0
	gate_glow.omni_attenuation = 0.8
	gate_glow.shadow_enabled = false
	gate_glow.position = Vector3(0, 2.0, -LENGTH + 8.0)
	g.add_child(gate_glow)
	# a far-visible beacon: a spotlight cone pointing back up the tunnel
	var beam := SpotLight3D.new()
	beam.light_color = Color(1.0, 0.97, 0.9)
	beam.light_energy = 4.0
	beam.spot_range = 60.0
	beam.spot_angle = 30.0
	beam.shadow_enabled = false
	beam.position = Vector3(0, 1.4, -LENGTH - 0.4)
	beam.rotation_degrees.y = 180.0
	g.add_child(beam)
	# "door" node + exit area: what the HUD scope points at
	door = Node3D.new()
	door.name = "LevelDoor"
	door.position = Vector3(0, 0, -LENGTH)
	door.rotation.y = 0.0
	g.add_child(door)
	var area := Area3D.new()
	area.name = "DoorArea"
	area.collision_layer = 4
	area.collision_mask = 0
	area.monitoring = false
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(2.4, 2.6, 1.6)
	cs.shape = bs
	area.add_child(cs)
	area.position = Vector3(0, 1.3, 0.6)
	door.add_child(area)
	set_meta("exit_area", area)
	gate_pos = Vector3(0, 0, -LENGTH)


# ------------------------------------------------------------------ Level API
func apply_graphics() -> void:
	var g := GameSettings
	var dens := g.gfx_lamp_density()
	var mul := g.gfx_light_range_mul()
	var far := g.gfx_far()
	for i in range(lamp_lights.size()):
		var li := lamp_lights[i]
		var keep := dens >= 0.999 or (fposmod(float(i) * 0.6180339887, 1.0) < dens)
		li.visible = keep
		li.omni_range = 9.0 * mul
		li.light_energy = float(def.get("lamp_energy", 2.4)) if keep else 0.0
		li.distance_fade_begin = minf(38.0, far * 0.55)
	for pn in lamp_panels:
		pn.visibility_range_end = minf(90.0, maxf(far * 0.9, 40.0))


func glb_to_world(gx: float, gz: float) -> Vector3:
	return Vector3(gx, 0.0, gz)


func nearest_walkable(w: Vector3) -> Vector3:
	var g := _nearest_free(_clamp_grid(data.world_to_grid(w)))
	return data.grid_to_world(g)


func is_reachable(a: Vector3, b: Vector3) -> bool:
	return get_nav_path(a, b).size() > 0


func door_world_position() -> Vector3:
	return door.global_position if door != null else gate_pos


func update_focus(_p: Vector3, _delta: float) -> void:
	pass


func nearest_flickerable(p: Vector3) -> Variant:
	var best := -1
	var bd := 14.0
	for i in range(lamp_lights.size()):
		var li := lamp_lights[i]
		if not li.visible or li.light_energy <= 0.05:
			continue
		var d := Vector2(li.global_position.x - p.x, li.global_position.z - p.z).length()
		if d < bd:
			bd = d
			best = i
	return best if best >= 0 else null


func kill_fixture(i: int) -> void:
	if i < 0 or i >= lamp_lights.size():
		return
	var li := lamp_lights[i]
	var pn := lamp_panels[i] if i < lamp_panels.size() else null
	var tw := create_tween()
	for k in range(4):
		tw.tween_property(li, "light_energy", 0.3, 0.05)
		tw.tween_property(li, "light_energy", 2.4, 0.07 + k * 0.03)
	tw.tween_property(li, "light_energy", 0.0, 0.05)
	if pn != null:
		tw.tween_callback(func(): pn.visible = false)


func flicker_fixture(i: int, dur := 1.2) -> void:
	if i < 0 or i >= lamp_lights.size():
		return
	var li := lamp_lights[i]
	var e0 := li.light_energy
	var tw := create_tween()
	var t := 0.0
	while t < dur:
		var step := randf_range(0.04, 0.16)
		tw.tween_property(li, "light_energy", randf_range(0.1, 1.2), step * 0.4)
		tw.tween_property(li, "light_energy", e0, step * 0.6)
		t += step
	tw.tween_property(li, "light_energy", e0, 0.05)


func get_nav_path(from_world: Vector3, to_world: Vector3) -> PackedVector3Array:
	var out := PackedVector3Array()
	if astar == null:
		return out
	var a := _nearest_free(_clamp_grid(data.world_to_grid(from_world)))
	var b := _nearest_free(_clamp_grid(data.world_to_grid(to_world)))
	for p in astar.get_point_path(a, b):
		out.append(data.grid_to_world(Vector2i(int(p.x), int(p.y))))
	return out


func _clamp_grid(p: Vector2i) -> Vector2i:
	return Vector2i(clampi(p.x, 0, data.gw - 1), clampi(p.y, 0, data.gh - 1))


func _nearest_free(p: Vector2i) -> Vector2i:
	if not astar.is_point_solid(p):
		return p
	for r in range(1, 8):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				var q := p + Vector2i(dx, dy)
				if q.x < 0 or q.y < 0 or q.x >= data.gw or q.y >= data.gh:
					continue
				if not astar.is_point_solid(q):
					return q
	return p


func is_wall_at(w: Vector3) -> bool:
	var g := data.world_to_grid(w)
	if g.x < 0 or g.y < 0 or g.x >= data.gw or g.y >= data.gh:
		return true
	return data.solid[data.idx(g.x, g.y)] == 1


func is_lit_at(_p: Vector3) -> bool:
	return true
