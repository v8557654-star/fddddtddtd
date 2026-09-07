extends Node
## Level 3 ("The Pit", Rec Room Backstage of Reality Level 7 by Lol_o9).
## Escape quest: find the rusty key somewhere in the maze -> unlock the
## iron door in the east -> dig the earth pile out of the stair nook (hold
## E; the creature closes in while you dig) -> climb the stairs -> the final
## run to the hatch. The regular creature is used; it wakes up the moment
## the key leaves the floor.
## v9: behind the hatch there is no sky -- a concrete vestibule and two
## identical tunnels. One drops you into Level 4 ("run or die"); the floor
## of the other one gives way (the "chasm" ending). Which is which is
## decided per run from the seed.

enum Phase { SEARCH_KEY, TO_DOOR, DIG, CLIMB, TUNNELS, DONE }

const PickupClass := preload("res://scripts/items/pickup.gd")

var game: Node = null
var level: Node = null
var player: Player = null
var phase: int = Phase.SEARCH_KEY
var door_locked := true          # read by main.door_locked()

var key_item: Node3D = null
var rubble: Node3D = null        # earth pile (Area3D "RubbleArea" + meshes)
var rubble_area: Area3D = null
var rubble_body: StaticBody3D = null
var rubble_meshes: Array[MeshInstance3D] = []
var stairs: Node3D = null
var hatch: Node3D = null         # exit door on the landing
var hatch_area: Area3D = null

var dig_progress := 0.0          # 0..1
var dig_sfx_t := 0.0
var dig_hint_t := 0.0
var dig_started := false
var _t := 0.0
var _armed := false              # creature awake
var _chase_started := false
var _door_open := false
var _hatch_pos := Vector3.ZERO
var _rubble_cells: Array[Vector2i] = []
var _door_cells: Array[Vector2i] = []
var _nook_lights: Array[OmniLight3D] = []
# v9 tunnels
var tunnels: Node3D = null
var pit_left := false             # which mouth (seen from the hatch, facing +z) is the trap
var _run_x := 0.0                 # world x of the "run" tunnel centre
var _pit_x := 0.0
var _tun_z0 := 0.0                # mouth z (north wall of the vestibule)
var _tun_z1 := 0.0                # far end z
var _vest_c := Vector3.ZERO       # vestibule centre (floor)
var _trap_body: StaticBody3D = null
var _trap_mesh: MeshInstance3D = null
var _trap_z := 0.0
var _hatch_open := false
var _hatch_leaf: MeshInstance3D = null
var _in_tunnel := ""              # "", "run", "pit"
var fall_stage_top := Vector3.INF
var _tunnel_lamps: Array[OmniLight3D] = []
var _tun_flicker_t := 0.0


func setup(g: Node, lvl: Node, pl: Player) -> void:
	game = g
	level = lvl
	player = pl
	var def: Dictionary = level.def
	# ---- key ---------------------------------------------------------------
	var kg: Array = def["key_glb"]
	var kpos: Vector3 = level.nearest_walkable(level.glb_to_world(float(kg[0]), float(kg[1])))
	key_item = PickupClass.new()
	key_item.type = PickupClass.Type.KEY
	key_item.name = "KeyItem"          # v10: same path on every co-op peer
	key_item.position = kpos
	game.add_child(key_item)
	key_item.tree_exited.connect(_on_key_taken)

	# ---- iron door: block the gap for walking + nav ------------------------
	for c in def.get("door_cells_glb", []):
		_door_cells.append(level.data.world_to_grid(level.glb_to_world(float(c[0]), float(c[1]))))
	_set_cells_solid(_door_cells, true)

	# ---- rubble pile in the nook gap ----------------------------------------
	var rg: Array = def["rubble_glb"]
	var rpos: Vector3 = level.glb_to_world(float(rg[0]), float(rg[1]))
	for c in def.get("rubble_cells_glb", []):
		_rubble_cells.append(level.data.world_to_grid(level.glb_to_world(float(c[0]), float(c[1]))))
	_set_cells_solid(_rubble_cells, true)
	_build_rubble(rpos)

	# ---- stairs + hatch -----------------------------------------------------
	_build_stairs(def)
	# ---- v9: the vestibule + two tunnels behind the hatch --------------------
	var trng := RandomNumberGenerator.new()
	trng.seed = int(game.run_seed) * 31 + 4242
	pit_left = trng.randf() < 0.5
	if OS.get_environment("BR_L7_PIT") == "left":
		pit_left = true
	elif OS.get_environment("BR_L7_PIT") == "right":
		pit_left = false
	_build_tunnels(def)

	# the nook is sealed until the dig: keep the creature from being
	# teleported into it (vanish / wander targets pick from data.rooms)
	var nook_x0: float = level.glb_to_world(89.8, 0.0).x
	var nz0: float = level.glb_to_world(0.0, -35.0).z
	var nz1: float = level.glb_to_world(0.0, -18.5).z
	var keep: Array[Vector2i] = []
	for c in level.data.rooms:
		var w: Vector3 = level.data.grid_to_world(c)
		if w.x > nook_x0 and w.z > minf(nz0, nz1) and w.z < maxf(nz0, nz1):
			continue
		keep.append(c)
	level.data.rooms = keep
	player.floor_max_angle = deg_to_rad(52.0)   # the stair ramp is ~42 deg

	# a couple of dead-orange work lamps in the nook so the stairs read
	var sx: float = level.glb_to_world(float(def["stairs_x_glb"]), 0.0).x
	var z0: float = level.glb_to_world(0.0, float(def["stairs_z0_glb"])).z
	var z1: float = level.glb_to_world(0.0, float(def["stairs_z1_glb"])).z
	for k in range(3):
		var l := OmniLight3D.new()
		l.light_color = Color(1.0, 0.55, 0.25)
		l.light_energy = 1.3
		l.omni_range = 6.0
		l.omni_attenuation = 1.5
		l.shadow_enabled = false
		l.position = Vector3(sx + (k - 1) * 0.4, 2.4 + k * 1.1, lerpf(z0, z1, float(k) / 2.0))
		level.add_child(l)
		_nook_lights.append(l)

	if OS.get_environment("BR_DEBUG") == "1":
		print("DBG level7: key=%s door=%s rubble=%s hatch=%s pit_left=%s run_x=%.2f pit_x=%.2f" % [str(kpos), str(level.door_world_position()), str(rpos), str(_hatch_pos), str(pit_left), _run_x, _pit_x])
	# test hooks
	if OS.get_environment("BR_L7_KEY") == "1":
		game.get_tree().create_timer(0.5).timeout.connect(func():
			if key_item != null and is_instance_valid(key_item):
				key_item.interact(player))
	if OS.get_environment("BR_L7_PHASE") != "":
		game.get_tree().create_timer(0.6).timeout.connect(func(): _jump_to(OS.get_environment("BR_L7_PHASE")))


func _jump_to(ph: String) -> void:
	## Screenshot / test helper: skip straight to a quest phase.
	if ph == "door" or ph == "dig" or ph == "climb":
		if key_item != null and is_instance_valid(key_item):
			key_item.queue_free()
		if not game.has_item("key"):
			game.add_to_inventory("key")
	if ph == "dig" or ph == "climb":
		_unlock_door(true)
	if ph == "climb" or ph == "tunnels":
		dig_progress = 1.0
		_finish_dig(true)
	if ph == "tunnels":
		# straight to the landing with the hatch already open
		if OS.get_environment("BR_POSE") == "":
			player.global_position = _hatch_pos + Vector3(0, 0.1, -1.0)
			player.yaw = PI
		_open_hatch(true)


# =================================================================== builders
func _set_cells_solid(cells: Array[Vector2i], on: bool) -> void:
	var d = level.data
	for c in cells:
		if c.x < 0 or c.y < 0 or c.x >= d.gw or c.y >= d.gh:
			continue
		d.solid[d.idx(c.x, c.y)] = 1 if on else 0
		if level.astar != null:
			level.astar.set_point_solid(c, on)


func _build_rubble(at: Vector3) -> void:
	rubble = Node3D.new()
	rubble.name = "Rubble"
	rubble.position = at
	level.add_child(rubble)
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = load("res://textures/metal.png")
	mat.albedo_color = Color(0.30, 0.24, 0.17)
	mat.roughness = 1.0
	mat.metallic = 0.0
	mat.uv1_scale = Vector3(0.6, 0.6, 0.6)
	var mat_rock := StandardMaterial3D.new()
	mat_rock.albedo_texture = load("res://textures/metal_r.png")
	mat_rock.albedo_color = Color(0.28, 0.27, 0.25)
	mat_rock.roughness = 0.95
	var rng := RandomNumberGenerator.new()
	rng.seed = 7007
	# main mound: a squashed sphere, plus a dozen lumps / stones
	var mound := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.9
	sm.height = 1.6
	sm.material = mat
	mound.mesh = sm
	mound.position = Vector3(0, 0.15, 0)
	mound.scale = Vector3(1.0, 1.0, 1.35)
	rubble.add_child(mound)
	rubble_meshes.append(mound)
	for i in range(14):
		var lump := MeshInstance3D.new()
		var lm := SphereMesh.new()
		var r := rng.randf_range(0.14, 0.34)
		lm.radius = r
		lm.height = r * 1.6
		lm.material = mat if rng.randf() < 0.6 else mat_rock
		lump.mesh = lm
		lump.position = Vector3(rng.randf_range(-0.55, 0.55), rng.randf_range(0.05, 1.1), rng.randf_range(-1.0, 1.0))
		lump.rotation = Vector3(rng.randf() * 3.0, rng.randf() * 3.0, rng.randf() * 3.0)
		rubble.add_child(lump)
		rubble_meshes.append(lump)
	# blocking body
	rubble_body = StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(1.4, 2.4, 2.2)
	cs.shape = bs
	cs.position = Vector3(0, 1.2, 0)
	rubble_body.add_child(cs)
	rubble.add_child(rubble_body)
	# interaction area
	rubble_area = Area3D.new()
	rubble_area.name = "RubbleArea"
	rubble_area.collision_layer = 4
	rubble_area.collision_mask = 0
	rubble_area.monitoring = false
	var acs := CollisionShape3D.new()
	var abs_ := BoxShape3D.new()
	abs_.size = Vector3(2.0, 2.4, 2.8)
	acs.shape = abs_
	acs.position = Vector3(0, 1.2, 0)
	rubble_area.add_child(acs)
	rubble_area.set_script(load("res://scripts/items/rubble_area.gd"))
	rubble_area.director = self
	rubble.add_child(rubble_area)


func _build_stairs(def: Dictionary) -> void:
	var sx: float = level.glb_to_world(float(def["stairs_x_glb"]), 0.0).x
	var z0: float = level.glb_to_world(0.0, float(def["stairs_z0_glb"])).z
	var z1: float = level.glb_to_world(0.0, float(def["stairs_z1_glb"])).z
	var w: float = def.get("stairs_w", 2.6)
	var top: float = float(def.get("ceiling_h", 4.3)) + 0.4     # landing just above the lid
	stairs = Node3D.new()
	stairs.name = "Stairs"
	level.add_child(stairs)
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = load("res://textures/metal.png")
	mat.normal_texture = load("res://textures/metal_n.png")
	mat.normal_enabled = true
	mat.albedo_color = Color(0.22, 0.21, 0.19)
	mat.roughness = 0.75
	mat.metallic = 0.5
	mat.uv1_scale = Vector3(2.5, 2.5, 2.5)
	var mat_rail := StandardMaterial3D.new()
	mat_rail.albedo_texture = load("res://textures/metal.png")
	mat_rail.albedo_color = Color(0.36, 0.22, 0.13)
	mat_rail.roughness = 0.7
	mat_rail.metallic = 0.6
	var body := StaticBody3D.new()
	stairs.add_child(body)
	var run := absf(z1 - z0) - 1.3       # the last 1.3 m is the landing
	var dir := signf(z1 - z0)
	var n := 22
	var rise := top / float(n)
	var tread := run / float(n)
	for i in range(n):
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(w, rise, tread + 0.05)
		bm.material = mat
		mi.mesh = bm
		var zc := z0 + dir * (tread * (i + 0.5))
		mi.position = Vector3(sx, rise * (i + 0.5), zc)
		stairs.add_child(mi)
		# a single ramp collider is smoother than 22 boxes: added below
	# ramp collider (a rotated box) + step-up friendly
	var ramp := CollisionShape3D.new()
	var rb := BoxShape3D.new()
	var ln := sqrt(run * run + top * top)
	# the ramp overshoots 0.25 m at both ends so its top face passes *above*
	# the landing edge (a capsule treats a 4 cm lip on a 42 deg slope as a wall)
	rb.size = Vector3(w, 0.25, ln + 0.5)
	ramp.shape = rb
	ramp.position = Vector3(sx, top * 0.5 - 0.12, z0 + dir * run * 0.5)
	ramp.rotation.x = -dir * atan2(top, run)
	body.add_child(ramp)
	# landing
	var land := MeshInstance3D.new()
	var lbm := BoxMesh.new()
	lbm.size = Vector3(w, 0.15, 1.5)
	lbm.material = mat
	land.mesh = lbm
	land.position = Vector3(sx, top - 0.075, z0 + dir * (run + 0.75))
	stairs.add_child(land)
	var lcs := CollisionShape3D.new()
	var lbs := BoxShape3D.new()
	lbs.size = Vector3(w, 0.15, 1.5)
	lcs.shape = lbs
	lcs.position = land.position
	body.add_child(lcs)
	# side rails (visual) + side walls so you can't fall off
	for side in [-1.0, 1.0]:
		var rail := MeshInstance3D.new()
		var rm := BoxMesh.new()
		rm.size = Vector3(0.04, 0.04, ln)
		rm.material = mat_rail
		rail.mesh = rm
		rail.position = Vector3(sx + side * (w * 0.5 - 0.05), top * 0.5 + 0.95, z0 + dir * run * 0.5)
		rail.rotation.x = -dir * atan2(top, run)
		stairs.add_child(rail)
		var wall := CollisionShape3D.new()
		var wb := BoxShape3D.new()
		wb.size = Vector3(0.1, top + 3.0, absf(z1 - z0) + 0.5)
		wall.shape = wb
		wall.position = Vector3(sx + side * (w * 0.5 + 0.05), (top + 3.0) * 0.5, (z0 + z1) * 0.5)
		body.add_child(wall)
	# back wall of the shaft: solid below the landing, a 1.4 x 2.4 doorway
	# (the hatch stands in it) above -- v9: the hatch opens into the tunnels
	var bz := z1 + dir * 0.35
	var pieces: Array = [
		[Vector3(w + 0.4, top, 0.2), Vector3(sx, top * 0.5, bz)],                      # below the landing
		[Vector3((w + 0.4 - 1.4) * 0.5, 3.2, 0.2), Vector3(sx - (w + 0.4 + 1.4) * 0.25, top + 1.6, bz)],
		[Vector3((w + 0.4 - 1.4) * 0.5, 3.2, 0.2), Vector3(sx + (w + 0.4 + 1.4) * 0.25, top + 1.6, bz)],
		[Vector3(1.4, 0.8, 0.2), Vector3(sx, top + 2.8, bz)],                          # lintel
	]
	for pc in pieces:
		var pcs := CollisionShape3D.new()
		var pbs := BoxShape3D.new()
		pbs.size = pc[0]
		pcs.shape = pbs
		pcs.position = pc[1]
		body.add_child(pcs)
		var pmi := MeshInstance3D.new()
		var pbm := BoxMesh.new()
		pbm.size = pc[0]
		pbm.material = mat
		pmi.mesh = pbm
		pmi.position = pc[1]
		stairs.add_child(pmi)
	# shaft walls (visual) above the lid on both sides
	for side in [-1.0, 1.0]:
		var sw := MeshInstance3D.new()
		var swm := BoxMesh.new()
		swm.size = Vector3(0.2, 4.0, absf(z1 - z0) + 0.5)
		swm.material = mat
		sw.mesh = swm
		sw.position = Vector3(sx + side * (w * 0.5 + 0.1), float(def.get("ceiling_h", 4.3)) + 2.0, (z0 + z1) * 0.5)
		stairs.add_child(sw)
	# hatch: the exit door on the landing, set into the back wall
	_hatch_pos = Vector3(sx, top, z1 + dir * 0.2)
	var yaw := atan2(0.0, dir)           # direction into the back wall
	hatch = level._make_door(_hatch_pos, yaw, true, false, top + 3.0)
	hatch.name = "Hatch"
	hatch_area = hatch.get_node("DoorArea")
	hatch_area.set_script(load("res://scripts/items/hatch_area.gd"))
	hatch_area.director = self
	hatch_area.setup()
	_hatch_leaf = hatch.get_node("Leaf")


# =================================================================== v9 tunnels
func _tbox(parent: Node, body: StaticBody3D, size: Vector3, pos: Vector3, mat: Material, collide := true) -> MeshInstance3D:
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


func _build_tunnels(def: Dictionary) -> void:
	## Vestibule behind the hatch (on top of the lid, at landing height) and
	## two identical 2 x 2.4 m concrete tunnels running north from it. The
	## whole thing lives above the ceiling slab, where the source mesh has
	## nothing (everything above the pit rim was culled).
	var sx: float = level.glb_to_world(float(def["stairs_x_glb"]), 0.0).x
	var z0: float = level.glb_to_world(0.0, float(def["stairs_z0_glb"])).z
	var z1: float = level.glb_to_world(0.0, float(def["stairs_z1_glb"])).z
	var dir := signf(z1 - z0)
	var top: float = float(def.get("ceiling_h", 4.3)) + 0.4
	var w: float = def.get("stairs_w", 2.6)
	tunnels = Node3D.new()
	tunnels.name = "Tunnels"
	level.add_child(tunnels)
	var body := StaticBody3D.new()
	tunnels.add_child(body)
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = load("res://textures/concrete.png")
	mat.normal_texture = load("res://textures/concrete_n.png")
	mat.normal_enabled = true
	mat.albedo_color = Color(0.55, 0.53, 0.50)
	mat.roughness = 0.95
	mat.uv1_scale = Vector3(0.5, 0.5, 0.5)
	mat.uv1_triplanar = true
	var mat_floor: StandardMaterial3D = mat.duplicate()
	mat_floor.albedo_color = Color(0.36, 0.35, 0.33)
	var mat_tun: StandardMaterial3D = mat.duplicate()
	mat_tun.albedo_color = Color(0.42, 0.40, 0.37)
	var black := StandardMaterial3D.new()
	black.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	black.albedo_color = Color(0, 0, 0)
	# ---- vestibule ----------------------------------------------------------
	var zv0 := z1 + dir * 0.45                       # just past the shaft back wall
	var depth := 4.2
	var zv1 := zv0 + dir * depth
	var vx0 := sx - 5.2
	var vx1 := sx + w * 0.5 - 0.05
	var vcx := (vx0 + vx1) * 0.5
	var vw := vx1 - vx0
	var vzc := (zv0 + zv1) * 0.5
	var h := 3.0
	_vest_c = Vector3(vcx, top, vzc)
	_tbox(tunnels, body, Vector3(vw + 0.4, 0.2, depth + 0.4), Vector3(vcx, top - 0.1, vzc), mat_floor)
	_tbox(tunnels, body, Vector3(vw + 0.4, 0.2, depth + 0.4), Vector3(vcx, top + h + 0.1, vzc), mat)
	# south wall: the part west of the shaft back wall
	var sxw0 := vx0
	var sxw1 := sx - (w + 0.4) * 0.5
	_tbox(tunnels, body, Vector3(sxw1 - sxw0 + 0.2, h + 0.4, 0.2), Vector3((sxw0 + sxw1) * 0.5 - 0.1, top + h * 0.5, z1 + dir * 0.35), mat)
	# west / east walls
	_tbox(tunnels, body, Vector3(0.2, h + 0.4, depth + 0.6), Vector3(vx0 - 0.1, top + h * 0.5, vzc), mat)
	_tbox(tunnels, body, Vector3(0.2, h + 0.4, depth + 0.6), Vector3(vx1 + 0.1, top + h * 0.5, vzc), mat)
	# north wall with the two mouths
	var tw := 2.0
	var th := 2.4
	var xa := vx0 + 0.55 + tw * 0.5                  # left mouth (west)
	var xb := vx1 - 0.65 - tw * 0.5                  # right mouth (east)
	var nz := zv1 + dir * 0.1
	var segs: Array = [[vx0, xa - tw * 0.5], [xa + tw * 0.5, xb - tw * 0.5], [xb + tw * 0.5, vx1]]
	for sg in segs:
		var a: float = sg[0]
		var b: float = sg[1]
		if b - a > 0.02:
			_tbox(tunnels, body, Vector3(b - a, h + 0.4, 0.2), Vector3((a + b) * 0.5, top + h * 0.5, nz), mat)
	for mx in [xa, xb]:
		_tbox(tunnels, body, Vector3(tw, h - th + 0.2, 0.2), Vector3(mx, top + th + (h - th + 0.2) * 0.5, nz), mat)
	# one dead-orange work lamp in the vestibule, a red cage lamp over each mouth
	var vl := OmniLight3D.new()
	vl.light_color = Color(1.0, 0.6, 0.3)
	vl.light_energy = 1.6
	vl.omni_range = 7.0
	vl.omni_attenuation = 1.4
	vl.shadow_enabled = false
	vl.position = Vector3(vcx, top + h - 0.3, vzc)
	tunnels.add_child(vl)
	_tunnel_lamps.append(vl)
	var mat_red := StandardMaterial3D.new()
	mat_red.albedo_color = Color(0.5, 0.06, 0.04)
	mat_red.emission_enabled = true
	mat_red.emission = Color(1.0, 0.15, 0.08)
	mat_red.emission_energy_multiplier = 2.0
	for mx in [xa, xb]:
		_tbox(tunnels, null, Vector3(0.3, 0.12, 0.12), Vector3(mx, top + th + 0.15, nz - dir * 0.16), mat_red, false)
		var rl := OmniLight3D.new()
		rl.light_color = Color(1.0, 0.18, 0.1)
		rl.light_energy = 1.4
		rl.omni_range = 5.0
		rl.omni_attenuation = 1.5
		rl.shadow_enabled = false
		rl.position = Vector3(mx, top + th - 0.1, nz - dir * 0.4)
		tunnels.add_child(rl)
		_tunnel_lamps.append(rl)
	# ---- the two tunnels ------------------------------------------------------
	var L := 15.0
	_tun_z0 = nz + dir * 0.1
	_tun_z1 = _tun_z0 + dir * L
	_pit_x = xa if pit_left else xb
	_run_x = xb if pit_left else xa
	_trap_z = _tun_z0 + dir * 7.8
	for mx in [xa, xb]:
		var is_pit := absf(mx - _pit_x) < 0.01
		var zc := (_tun_z0 + _tun_z1) * 0.5
		# walls + ceiling
		_tbox(tunnels, body, Vector3(0.2, th + 0.4, L + 0.2), Vector3(mx - tw * 0.5 - 0.1, top + th * 0.5, zc), mat_tun)
		_tbox(tunnels, body, Vector3(0.2, th + 0.4, L + 0.2), Vector3(mx + tw * 0.5 + 0.1, top + th * 0.5, zc), mat_tun)
		_tbox(tunnels, body, Vector3(tw + 0.4, 0.2, L + 0.2), Vector3(mx, top + th + 0.1, zc), mat_tun)
		# floor: whole, or in three parts with the middle one on its own body
		if not is_pit:
			_tbox(tunnels, body, Vector3(tw + 0.4, 0.2, L + 0.2), Vector3(mx, top - 0.1, zc), mat_floor)
		else:
			var gap := 3.4
			var za := _tun_z0
			var zb := _trap_z - dir * gap * 0.5
			var zc2 := _trap_z + dir * gap * 0.5
			var zd := _tun_z1
			_tbox(tunnels, body, Vector3(tw + 0.4, 0.2, absf(zb - za) + 0.1), Vector3(mx, top - 0.1, (za + zb) * 0.5), mat_floor)
			_tbox(tunnels, body, Vector3(tw + 0.4, 0.2, absf(zd - zc2) + 0.1), Vector3(mx, top - 0.1, (zc2 + zd) * 0.5), mat_floor)
			_trap_body = StaticBody3D.new()
			tunnels.add_child(_trap_body)
			_trap_mesh = _tbox(tunnels, _trap_body, Vector3(tw + 0.4, 0.2, gap), Vector3(mx, top - 0.1, _trap_z), mat_floor)
			# the void: rendered on its own stage high above the map (see
			# _build_fall_stage) -- there is a maze right under this floor
			_build_fall_stage(Vector3(mx, top + 80.0, _trap_z))
			# trigger: a thin band a step past the edge
			var ta := Area3D.new()
			ta.collision_layer = 0
			ta.collision_mask = 1
			ta.monitorable = false
			var tcs := CollisionShape3D.new()
			var tbs := BoxShape3D.new()
			tbs.size = Vector3(tw, 1.6, gap - 1.2)
			tcs.shape = tbs
			ta.add_child(tcs)
			ta.position = Vector3(mx, top + 0.8, _trap_z)
			tunnels.add_child(ta)
			ta.body_entered.connect(_on_trap_entered)
		# a black cap at the far end (it "goes on"), a dead-red glimmer before it
		_tbox(tunnels, body, Vector3(tw + 0.4, th + 0.4, 0.1), Vector3(mx, top + th * 0.5, _tun_z1 + dir * 0.05), black)
		var fl := OmniLight3D.new()
		fl.light_color = Color(1.0, 0.2, 0.1)
		fl.light_energy = 0.7
		fl.omni_range = 6.0
		fl.omni_attenuation = 1.6
		fl.shadow_enabled = false
		fl.position = Vector3(mx, top + th - 0.2, _tun_z1 - dir * 1.5)
		tunnels.add_child(fl)
		_tunnel_lamps.append(fl)
		# entry trigger (which tunnel did you pick)
		var ea := Area3D.new()
		ea.collision_layer = 0
		ea.collision_mask = 1
		ea.monitorable = false
		var ecs := CollisionShape3D.new()
		var ebs := BoxShape3D.new()
		ebs.size = Vector3(tw, 2.0, 1.0)
		ecs.shape = ebs
		ea.add_child(ecs)
		ea.position = Vector3(mx, top + 1.0, _tun_z0 + dir * 2.0)
		ea.set_meta("kind", "pit" if is_pit else "run")
		tunnels.add_child(ea)
		ea.body_entered.connect(_on_tunnel_entered.bind(ea))
		if not is_pit:
			# the far trigger: past it the tunnel drops into Level 4
			var ra := Area3D.new()
			ra.collision_layer = 0
			ra.collision_mask = 1
			ra.monitorable = false
			var rcs := CollisionShape3D.new()
			var rbs := BoxShape3D.new()
			rbs.size = Vector3(tw, 2.0, 1.0)
			rcs.shape = rbs
			ra.add_child(rcs)
			ra.position = Vector3(mx, top + 1.0, _tun_z1 - dir * 2.2)
			tunnels.add_child(ra)
			ra.body_entered.connect(_on_run_exit)
	# debris on the vestibule floor
	var drng := RandomNumberGenerator.new()
	drng.seed = 9091
	for i in range(10):
		var s := drng.randf_range(0.12, 0.3)
		var dm := _tbox(tunnels, null, Vector3(s, s * 0.5, s * 1.2), Vector3(drng.randf_range(vx0 + 0.4, vx1 - 0.4), top + s * 0.25, drng.randf_range(zv0 + 0.4, zv1 - 0.4)), mat_tun, false)
		dm.rotation.y = drng.randf_range(0, TAU)


func _build_fall_stage(at: Vector3) -> void:
	## The chasm. A 70 m concrete shaft that exists only on render layer 2,
	## parked 80 m above the map where nothing else is. On the trap the
	## camera is switched to that layer and dropped down it: walls and ribs
	## streak past, the red glimmer of the tunnel above shrinks, then black.
	fall_stage_top = at
	var st := Node3D.new()
	st.name = "FallStage"
	st.position = at
	tunnels.add_child(st)
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = load("res://textures/concrete.png")
	mat.normal_texture = load("res://textures/concrete_n.png")
	mat.normal_enabled = true
	mat.albedo_color = Color(0.62, 0.60, 0.56)
	mat.roughness = 0.95
	mat.uv1_scale = Vector3(0.5, 0.5, 0.5)
	mat.uv1_triplanar = true
	var mat_rib := StandardMaterial3D.new()
	mat_rib.albedo_texture = load("res://textures/metal.png")
	mat_rib.albedo_color = Color(0.25, 0.18, 0.14)
	mat_rib.roughness = 0.8
	mat_rib.metallic = 0.4
	var black := StandardMaterial3D.new()
	black.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	black.albedo_color = Color(0, 0, 0)
	var depth := 70.0
	var w := 2.4
	var d := 3.4
	var parts: Array[MeshInstance3D] = []
	for side in [-1.0, 1.0]:
		parts.append(_tbox(st, null, Vector3(0.2, depth, d + 0.4), Vector3(side * (w * 0.5 + 0.1), -depth * 0.5, 0), mat, false))
		parts.append(_tbox(st, null, Vector3(w + 0.4, depth, 0.2), Vector3(0, -depth * 0.5, side * (d * 0.5 + 0.1)), mat, false))
	parts.append(_tbox(st, null, Vector3(w + 0.4, 0.2, d + 0.4), Vector3(0, -depth, 0), black, false))
	# ribs every 2.5 m give the eye something to measure the speed against
	var y := -1.5
	while y > -depth + 1.0:
		for side in [-1.0, 1.0]:
			parts.append(_tbox(st, null, Vector3(0.12, 0.16, d), Vector3(side * (w * 0.5 - 0.06), y, 0), mat_rib, false))
			parts.append(_tbox(st, null, Vector3(w, 0.16, 0.12), Vector3(0, y, side * (d * 0.5 - 0.06)), mat_rib, false))
		y -= 2.5
	# the tunnel's red glow, seen from below, plus a couple of dead-dim
	# lamps further down so the walls never vanish completely
	var lt := OmniLight3D.new()
	lt.light_color = Color(1.0, 0.25, 0.12)
	lt.light_energy = 3.0
	lt.omni_range = 26.0
	lt.omni_attenuation = 1.2
	lt.shadow_enabled = false
	lt.position = Vector3(0, 0.6, 0)
	st.add_child(lt)
	for k in range(7):
		var dl := OmniLight3D.new()
		dl.light_color = Color(0.9, 0.55, 0.35) if k % 2 == 0 else Color(1.0, 0.25, 0.12)
		dl.light_energy = 2.2
		dl.omni_range = 13.0
		dl.omni_attenuation = 1.3
		dl.shadow_enabled = false
		dl.position = Vector3(0.9 if k % 2 == 0 else -0.9, -8.0 - k * 9.0, 0)
		st.add_child(dl)
		# the lamp itself: a small dead-orange cage on the wall
		var mat_l := StandardMaterial3D.new()
		mat_l.albedo_color = dl.light_color * 0.5
		mat_l.emission_enabled = true
		mat_l.emission = dl.light_color
		mat_l.emission_energy_multiplier = 1.6
		parts.append(_tbox(st, null, Vector3(0.12, 0.22, 0.22), Vector3(dl.position.x * 1.2, dl.position.y, 0), mat_l, false))
	# the mouth above: the tunnel's red ceiling, shrinking as you drop
	var mat_m := StandardMaterial3D.new()
	mat_m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat_m.albedo_color = Color(0.55, 0.09, 0.05)
	parts.append(_tbox(st, null, Vector3(w, 0.05, d), Vector3(0, 2.4, 0), mat_m, false))
	for side in [-1.0, 1.0]:
		parts.append(_tbox(st, null, Vector3(0.2, 2.4, d + 0.4), Vector3(side * (w * 0.5 + 0.1), 1.2, 0), mat, false))
		parts.append(_tbox(st, null, Vector3(w + 0.4, 2.4, 0.2), Vector3(0, 1.2, side * (d * 0.5 + 0.1)), mat, false))
	for m in parts:
		m.layers = 2
		m.visibility_range_end = 0.0
	# lights are VisualInstances too: a camera that only sees layer 2 culls
	# layer-1 lights along with everything else
	for n in st.get_children():
		if n is Light3D:
			(n as Light3D).layers = 2


func _open_hatch(silent: bool) -> void:
	if _hatch_open:
		return
	_hatch_open = true
	phase = Phase.TUNNELS
	# swing the leaf on its hinge, drop the blocking body
	if _hatch_leaf != null:
		var tw := _hatch_leaf.create_tween()
		tw.tween_method(_hatch_swing, 0.0, -1.9, 0.9).set_ease(Tween.EASE_OUT)
	for c in hatch.get_children():
		if c is StaticBody3D:
			(c as StaticBody3D).set_deferred("collision_layer", 0)
			for cc in c.get_children():
				if cc is CollisionShape3D:
					(cc as CollisionShape3D).set_deferred("disabled", true)
		elif c is MeshInstance3D and c.mesh is CylinderMesh:
			c.visible = false        # the handle stays with the leaf, conceptually
	if not silent:
		AudioBank.play("door", 1.0, 0.85)
		AudioBank.play("pipe_knock_1", 0.6, 0.6, "SFX")
		game.bodycam.burst(0.4)
		game.hud.show_subtitle("Не небо. Бетон. Два тоннеля — одинаковых. Оно уже на лестнице.", 4.5)
	game.hud.set_objective("ЦЕЛЬ: ДВА ТОННЕЛЯ. ВЫБЕРИ ОДИН")
	game.hud.set_prompt("")


func _hatch_swing(a: float) -> void:
	## Leaf on its hinge (left post), swinging away from the landing.
	if _hatch_leaf == null or not is_instance_valid(_hatch_leaf):
		return
	var hinge := Vector3(-0.54, 1.10, 0.0)
	_hatch_leaf.rotation.y = a
	_hatch_leaf.position = hinge + Basis(Vector3.UP, a) * Vector3(0.54, 0.0, 0.0)


func _on_tunnel_entered(b: Node, area: Area3D) -> void:
	if b != player or _in_tunnel != "" or game.state != game.State.PLAYING:
		return
	_in_tunnel = str(area.get_meta("kind"))
	if OS.get_environment("BR_DEBUG") == "1":
		print("DBG l7: entered tunnel '%s'" % _in_tunnel)
	game.hud.set_objective("ЦЕЛЬ: ВПЕРЁД. НЕ ОГЛЯДЫВАЙСЯ")
	AudioBank.play("distant_bang", 0.6, 0.55, "Ambience")
	if Net.active:
		game.dir_event(["tunnel", _in_tunnel])


func _on_run_exit(b: Node) -> void:
	if b != player or phase == Phase.DONE or game.state != game.State.PLAYING:
		return
	phase = Phase.DONE
	print("DBG l7: run tunnel -> level 4")
	game.on_door_used()          # v10: the whole crew descends together


func _on_trap_entered(b: Node) -> void:
	if b != player or phase == Phase.DONE or game.state != game.State.PLAYING:
		return
	if _trap_gone:
		return
	if not Net.active:
		phase = Phase.DONE
	print("DBG l7: trap floor -> fall")
	_drop_trap()
	if Net.active:
		game.dir_event(["trap"])
	game.fall_ending(fall_stage_top)


var _trap_gone := false
func _drop_trap() -> void:
	# the slab tips and goes; whoever stood on it goes with it
	if _trap_gone:
		return
	_trap_gone = true
	if _trap_body != null and is_instance_valid(_trap_body):
		for cc in _trap_body.get_children():
			if cc is CollisionShape3D:
				(cc as CollisionShape3D).set_deferred("disabled", true)
	if _trap_mesh != null and is_instance_valid(_trap_mesh):
		_trap_mesh.visible = false
	AudioBank.play("collapse", 1.0, 1.1, "SFX")


# =================================================================== flow
func _process(delta: float) -> void:
	if game == null or player == null or not is_instance_valid(player):
		return
	if not game.world_running():
		return
	_t += delta
	if OS.get_environment("BR_L7_AUTO") == "1" and player.alive:
		_auto(delta)
	match phase:
		Phase.DIG:
			_tick_dig(delta)
		Phase.TUNNELS:
			player.on_metal_stairs = false
			_tun_flicker_t -= delta
			if _tun_flicker_t <= 0.0 and not _tunnel_lamps.is_empty():
				_tun_flicker_t = randf_range(1.5, 4.0)
				var li: OmniLight3D = _tunnel_lamps[randi() % _tunnel_lamps.size()]
				if is_instance_valid(li):
					var e0 := li.light_energy
					var tw := li.create_tween()
					for k in range(3):
						tw.tween_property(li, "light_energy", e0 * 0.15, 0.05)
						tw.tween_property(li, "light_energy", e0, randf_range(0.06, 0.18))
		Phase.CLIMB:
			player.on_metal_stairs = player.global_position.y > 0.3
			_dbg_t -= delta
			if _dbg_t <= 0.0 and OS.get_environment("BR_DEBUG") == "1":
				_dbg_t = 1.0
				var info := ""
				for i in range(player.get_slide_collision_count()):
					var c := player.get_slide_collision(i)
					info += " | %s n=%s at=%s" % [str(c.get_collider().name), str(c.get_normal()), str(c.get_position())]
				print("DBG l7 climb pos=%s floor=%s vel=%s%s" % [str(player.global_position), str(player.is_on_floor()), str(player.velocity), info])
		_:
			pass


func _on_key_taken() -> void:
	if phase != Phase.SEARCH_KEY or not is_inside_tree() or game == null or not game.world_running():
		return
	phase = Phase.TO_DOOR
	key_item = null
	game.hud.set_objective("ЦЕЛЬ: ЖЕЛЕЗНАЯ ДВЕРЬ НА ВОСТОКЕ")
	# the creature wakes up the moment the key leaves the floor
	if not _armed:
		_armed = true
		if Net.is_authority():
			game.call_deferred("_activate_monster")
	game.get_tree().create_timer(2.5).timeout.connect(func():
		if game.state == game.State.PLAYING:
			game.hud.show_subtitle("Что-то в лабиринте проснулось.", 4.0))


func door_prompt() -> String:
	match phase:
		Phase.SEARCH_KEY:
			return "ЖЕЛЕЗНАЯ ДВЕРЬ — ЗАПЕРТА. НУЖЕН КЛЮЧ"
		Phase.TO_DOOR:
			return "ЖЕЛЕЗНАЯ ДВЕРЬ — ОТКРЫТЬ КЛЮЧОМ"
		_:
			return "ЖЕЛЕЗНАЯ ДВЕРЬ — ОТКРЫТА"


func on_door_interact() -> bool:
	## The iron door. Handled entirely here (never descends a level).
	if phase == Phase.SEARCH_KEY or (phase == Phase.TO_DOOR and not game.has_item("key")):
		AudioBank.play("deny", 0.8, 0.8)
		AudioBank.play("pipe_knock_2", 0.7, 0.6, "SFX")
		if phase == Phase.TO_DOOR and Net.active:
			game.hud.show_subtitle("Заперто. Ключ у напарника — пусть откроет.", 3.5)
		else:
			game.hud.show_subtitle("Заперто. Замочная скважина забита ржавчиной, но ключ сюда войдёт.", 3.5)
		return true
	if phase == Phase.TO_DOOR:
		if Net.active:
			game.dir_event(["unlock"])      # everyone swings the leaf
		else:
			_unlock_door(false)
		return true
	# already open: just walk through
	return true


func _unlock_door(silent: bool) -> void:
	if _door_open:
		return
	_door_open = true
	door_locked = false
	phase = Phase.DIG
	if game.has_item("key"):
		game.consume_item("key")
	_set_cells_solid(_door_cells, false)
	# swing the leaf open (rotate around its hinge) and drop its blocker
	var d: Node3D = level.door
	var leaf: Node3D = d.get_node_or_null("Leaf")
	for c in d.get_children():
		if c is StaticBody3D:
			c.queue_free()
	if leaf != null:
		var hinge := Node3D.new()
		hinge.position = Vector3(-0.54, 0, 0)
		d.add_child(hinge)
		leaf.reparent(hinge)
		var tw := create_tween()
		tw.tween_property(hinge, "rotation:y", -1.9, 1.4).set_ease(Tween.EASE_OUT)
	if not silent:
		AudioBank.play("unlock", 1.0, 1.0)
		AudioBank.play("door", 0.8, 0.85)
		game.bodycam.burst(0.3)
		game.hud.show_subtitle("Замок поддался. За дверью — тупик и куча земли. Лестница где-то за ней.", 5.0)
	game.hud.set_objective("ЦЕЛЬ: РАЗГРЕБИ ЗАВАЛ (ДЕРЖИ E)")


# ---- digging ---------------------------------------------------------------
func rubble_prompt() -> String:
	if phase == Phase.DIG:
		return "ЗАВАЛ — ДЕРЖИ E, ЧТОБЫ КОПАТЬ  (%d%%)" % int(dig_progress * 100.0)
	if phase == Phase.SEARCH_KEY or phase == Phase.TO_DOOR:
		return "ЗАВАЛ"
	return ""


var _dig_net_t := 0.0
var _dig_net_acc := 0.0
func _tick_dig(delta: float) -> void:
	var digging := false
	var tgt: Node = player.interact_target()
	if tgt == rubble_area and player.interact_held() and player.alive and player.look_enabled:
		digging = true
	if OS.get_environment("BR_L7_AUTO") == "1" and player.alive and player.global_position.distance_to(rubble.global_position) < 2.4:
		digging = true
	if digging:
		if not dig_started:
			dig_started = true
			game.hud.show_subtitle("Земля сухая, сыплется сквозь пальцы. Это надолго. Оно услышит.", 4.0)
		var inc := delta / 22.0
		dig_progress = minf(dig_progress + inc, 1.0)
		dig_sfx_t -= delta
		if dig_sfx_t <= 0.0:
			dig_sfx_t = randf_range(0.55, 0.8)
			AudioBank.play_variant_3d("dig", rubble.global_position + Vector3(0, 0.8, 0), 0.9, randf_range(0.9, 1.1), "SFX")
			if Net.active:
				Net.send_event("sfx", ["dig", rubble.global_position + Vector3(0, 0.8, 0), 0.9, 1.0])
			# every scoop is noise: the creature homes in on it
			game.make_noise(player.global_position, 26.0)
			if Net.is_authority() and game.monster != null and not game.monster.dormant and game.monster.menace < 1:
				game.monster.set_menace(1)
		game.player.stamina = maxf(game.player.stamina - delta * 2.0, 0.0)
		# v10: two shovels dig twice as fast -- share our increments
		if Net.active:
			_dig_net_acc += inc
			_dig_net_t -= delta
			if _dig_net_t <= 0.0:
				_dig_net_t = 0.25
				game.dir_event(["dig", _dig_net_acc])
				_dig_net_acc = 0.0
		if dig_progress >= 1.0:
			if Net.active:
				game.dir_event(["dug"])
			else:
				_finish_dig(false)
	else:
		dig_hint_t -= delta
	_shape_rubble()
	if game.hud != null and tgt == rubble_area:
		game.hud.set_prompt(rubble_prompt())


func _shape_rubble() -> void:
	# the pile shrinks as it is dug
	var k := 1.0 - dig_progress * 0.85
	for i in range(rubble_meshes.size()):
		var m: MeshInstance3D = rubble_meshes[i]
		if is_instance_valid(m):
			m.scale = Vector3(1.0, k, 1.35 if i == 0 else 1.0)


func net_apply(a: Array, from: int = 0) -> void:
	## v10: replay a director event from another operator.
	if a.is_empty():
		return
	match str(a[0]):
		"unlock":
			if phase == Phase.TO_DOOR:
				_unlock_door(false)
		"dig":
			if phase == Phase.DIG and from != Net.my_id():
				dig_progress = minf(dig_progress + float(a[1]), 1.0)
				dig_started = true
		"dug":
			if phase == Phase.DIG:
				dig_progress = 1.0
				_finish_dig(false)
		"hatch":
			if phase == Phase.CLIMB:
				_open_hatch(false)
		"tunnel":
			if from != Net.my_id() and _in_tunnel == "":
				game.hud.set_objective("ЦЕЛЬ: НАПАРНИК В ТОННЕЛЕ. ВЫБИРАЙ")
		"trap":
			# a partner stepped on the slab: it is gone for everyone
			_drop_trap()
		_:
			pass


func _finish_dig(silent: bool) -> void:
	if phase == Phase.CLIMB or phase == Phase.DONE:
		return
	phase = Phase.CLIMB
	_set_cells_solid(_rubble_cells, false)
	if rubble_body != null:
		rubble_body.queue_free()
	if rubble_area != null:
		rubble_area.queue_free()
		rubble_area = null
	# what's left: a low spread of earth you can walk over
	for m in rubble_meshes:
		if is_instance_valid(m):
			m.scale = Vector3(1.3, 0.12, 1.3)
	if not silent:
		AudioBank.play("collapse", 1.0, 1.0)
		game.bodycam.burst(0.5)
		game.hud.show_subtitle("Проход открыт. Лестница! Наверх — и не оглядывайся.", 4.0)
	game.hud.set_objective("ЦЕЛЬ: ПО ЛЕСТНИЦЕ НАВЕРХ. БЕГИ")
	game.hud.set_prompt("")
	# the final run: a beat of silence, then the creature comes through the
	# iron door behind you, fully lethal
	game.get_tree().create_timer(2.0 if not silent else 0.5).timeout.connect(_start_final_chase)


func _start_final_chase() -> void:
	if _chase_started or OS.get_environment("BR_L7_NOCHASE") == "1":
		return
	_chase_started = true
	var m = game.monster
	if m == null:
		return
	if not Net.is_authority():
		# v10 guest: the host's creature comes through; we only play the sting
		AudioBank.play("stinger", 0.9, 0.9, "SFX")
		AudioBank.play("distant_bang", 1.0, 1.1, "SFX")
		game.bodycam.burst(0.4)
		game.hud.show_subtitle("ОНО ЗДЕСЬ. НАВЕРХ!", 2.5)
		return
	var tgt: Player = game.nearest_living_player(level.door_world_position()) if Net.active else player
	if tgt != null:
		m.player = tgt
	var def: Dictionary = level.def
	var cg: Array = def.get("chase_from_glb", [86.0, -32.0])
	var from: Vector3 = level.nearest_walkable(level.glb_to_world(float(cg[0]), float(cg[1])))
	if m.dormant:
		game.monster_active = true
		m.activate(from)
	else:
		m.global_position = from
		m.visible = true
	m.set_menace(3)
	m.awareness = 1.0
	m.last_known = m.player.global_position if m.player != null else player.global_position
	m._set_state(m.State.CHASE)
	AudioBank.play("screech", 1.0, 0.95, "Monster")
	AudioBank.play("stinger", 0.9, 0.9, "SFX")
	AudioBank.play("distant_bang", 1.0, 1.1, "SFX")
	game.bodycam.burst(0.4)
	game.hud.show_subtitle("ОНО ЗДЕСЬ. НАВЕРХ!", 2.5)


# ---- hatch (the exit on the landing) ---------------------------------------
func hatch_prompt() -> String:
	if phase == Phase.CLIMB:
		return "ЛЮК НАВЕРХ — ОТКРЫТЬ"
	if _hatch_open:
		return ""
	return "ЛЮК — ЗАПЕРТ СНАРУЖИ"


func on_hatch_interact() -> void:
	if _hatch_open:
		return
	if phase != Phase.CLIMB:
		AudioBank.play("deny", 0.8, 0.8)
		return
	if Net.active:
		game.dir_event(["hatch"])
	else:
		_open_hatch(false)


func hatch_position() -> Vector3:
	return _hatch_pos


func radar_target() -> Vector3:
	## What the HUD scope points at in each phase.
	match phase:
		Phase.SEARCH_KEY:
			return key_item.global_position if (key_item != null and is_instance_valid(key_item)) else level.door_world_position()
		Phase.TO_DOOR:
			return level.door_world_position()
		Phase.DIG:
			return rubble.global_position if rubble != null else level.door_world_position()
		Phase.TUNNELS, Phase.DONE:
			if _in_tunnel == "run":
				return Vector3(_run_x, _hatch_pos.y, _tun_z1)
			if _in_tunnel == "pit":
				return Vector3(_pit_x, _hatch_pos.y, _tun_z1)
			return Vector3((_run_x + _pit_x) * 0.5, _hatch_pos.y, _tun_z0)
		_:
			return _hatch_pos


func threat_position() -> Vector3:
	return Vector3.INF     # the regular creature: main.gd tracks it itself


func threat_sees_player() -> bool:
	return false


# ---- headless test driver ---------------------------------------------------
var _auto_done := false
var _dbg_t := 0.0
func _auto(_delta: float) -> void:
	if _auto_done:
		return
	match phase:
		Phase.SEARCH_KEY:
			if key_item == null or not is_instance_valid(key_item):
				return
			var dist := _auto_steer(key_item.global_position)
			player.debug_sprint = true
			if dist < 1.4:
				key_item.interact(player)
		Phase.TO_DOOR:
			var dp: Vector3 = level.door_world_position() + level.door.transform.basis.z * 1.2
			var dist := _auto_steer(dp)
			player.debug_sprint = true
			if dist < 1.3:
				player.debug_move = Vector2.ZERO
				on_door_interact()
		Phase.DIG:
			var rp: Vector3 = rubble.global_position - Vector3(0, 0, 1.6)   # the pile is entered from the north side
			var dist := _auto_steer(rp)
			if dist < 0.9:
				player.debug_move = Vector2.ZERO
				player.yaw = atan2(-(rubble.global_position.x - player.global_position.x), -(rubble.global_position.z - player.global_position.z))
		Phase.CLIMB:
			# path-follow to the foot of the stairs, then straight up the ramp
			var foot := Vector3(_hatch_pos.x, 0.0, rubble.global_position.z + (_hatch_pos.z - rubble.global_position.z) * 0.25)
			var dist: float
			if player.global_position.y < 0.3 and Vector2(player.global_position.x - foot.x, player.global_position.z - foot.z).length() > 1.0:
				dist = _auto_steer(foot)
				dist = 99.0
			else:
				dist = _auto_steer(_hatch_pos, true)
			player.debug_sprint = true
			if dist < 1.5 and absf(player.global_position.y - _hatch_pos.y) < 1.2:
				player.debug_move = Vector2.ZERO
				on_hatch_interact()
				print("DBG l7 auto: hatch used at t=%.1f state=%d" % [_t, game.state])
		Phase.TUNNELS:
			# through the vestibule into the chosen tunnel (BR_L7_GO=run|pit)
			var go := OS.get_environment("BR_L7_GO")
			var tx := _pit_x if go == "pit" else _run_x
			var y := _hatch_pos.y
			var here := player.global_position
			var dz := signf(_tun_z1 - _tun_z0)
			var wps: Array[Vector3] = [
				Vector3(_hatch_pos.x, y, _vest_c.z - dz * 1.2),
				Vector3(tx, y, _vest_c.z + dz * 0.6),
				Vector3(tx, y, _tun_z0 + dz * 1.5),
				Vector3(tx, y, _tun_z1 - dz * 0.6)]
			var tgt := wps[wps.size() - 1]
			for wp in wps:
				if (wp.z - here.z) * dz > 0.5 or (absf(wp.x - here.x) > 0.5 and absf(wp.z - here.z) < 1.0 and wp != wps[0]):
					tgt = wp
					break
			_auto_steer(tgt, true)
			player.debug_sprint = true
			_dbg_t -= _delta
			if _dbg_t <= 0.0:
				_dbg_t = 1.0
				print("DBG l7 auto tunnels: pos=%s tgt=%s in=%s" % [str(here), str(tgt), _in_tunnel])


func _auto_steer(tgt: Vector3, straight := false) -> float:
	var here := player.global_position
	var to := tgt - here
	var dist := Vector2(to.x, to.z).length()
	var wp := tgt
	if dist > 2.0 and not straight:
		var path: PackedVector3Array = level.get_nav_path(here, tgt)
		for i in range(path.size()):
			if Vector2(path[i].x - here.x, path[i].z - here.z).length() > 1.2:
				wp = path[i]
				break
	var d := wp - here
	player.yaw = atan2(-d.x, -d.z)
	player.debug_move = Vector2(0, -1)
	return dist
