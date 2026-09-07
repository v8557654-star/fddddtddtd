class_name CustomMap
extends Node3D
## A GLB level (see LevelDefs). Bakes trimesh collision, derives a
## walkability grid straight from the triangles, adds lamps, spawns,
## pickups and the level door, and exposes the level API used by
## main.gd / monster.gd.

const CELL := 0.75

var def: Dictionary = {}
var level_id := 0
var data: CMapData = CMapData.new()
var astar: AStarGrid2D = null
var lights_on: Array[Vector3] = []
var lamp_lights: Array[OmniLight3D] = []     # working lamps (for graphics presets / flicker)
var lamp_panels: Array[MeshInstance3D] = []
var rng := RandomNumberGenerator.new()
var door: Node3D = null

var mat_panel: StandardMaterial3D
var mat_exit: StandardMaterial3D
var glb_shift := Vector3.ZERO      # world = glb * glb_scale + glb_shift
var glb_scale := 1.0
var spawn_yaw := 0.0               # player facing at spawn (radians)


class CMapData:
	enum Zone { LIT, DIM, DARK, WET }
	var gw := 0
	var gh := 0
	var solid: PackedByteArray = PackedByteArray()
	var zone: PackedByteArray = PackedByteArray()
	var floor_h: PackedFloat32Array = PackedFloat32Array()
	var ceil_h: PackedFloat32Array = PackedFloat32Array()
	var rooms: Array[Vector2i] = []
	var origin := Vector3.ZERO
	var player_spawn := Vector3.ZERO
	var monster_spawn := Vector3.ZERO
	var exit_point := Vector2i.ZERO
	var water_points: Array[Vector2i] = []
	var battery_points: Array[Vector2i] = []

	func idx(x: int, y: int) -> int:
		return y * gw + x

	func is_solid(x: int, y: int) -> bool:
		if x < 0 or y < 0 or x >= gw or y >= gh:
			return true
		return solid[idx(x, y)] == 1

	func grid_to_world(p: Vector2i) -> Vector3:
		var y := 0.0
		var i := idx(p.x, p.y)
		if i >= 0 and i < floor_h.size():
			y = floor_h[i]
		return origin + Vector3(p.x * CELL + CELL * 0.5, y, p.y * CELL + CELL * 0.5)

	func world_to_grid(w: Vector3) -> Vector2i:
		return Vector2i(int(floor((w.x - origin.x) / CELL)), int(floor((w.z - origin.z) / CELL)))

	func room_center(p: Vector2i) -> Vector3:
		return grid_to_world(p)


func build(seedv: int = -1, lvl: int = 0) -> void:
	level_id = lvl
	def = LevelDefs.get_def(lvl)
	if seedv >= 0:
		rng.seed = seedv + lvl * 7919
	else:
		rng.randomize()
	var ps: PackedScene = load(def["path"])
	if ps == null:
		push_error("CustomMap: missing " + str(def["path"]))
		return
	var inst: Node3D = ps.instantiate() as Node3D
	var sc: float = def["scale"]
	inst.scale = Vector3(sc, sc, sc)
	add_child(inst)
	_cull_boxes(inst)
	if def.has("albedo_min"):
		_restyle(inst, float(def["albedo_min"]))
	var t0 := Time.get_ticks_msec()
	_bake(inst)
	if OS.get_environment("BR_DEBUG") == "1":
		print("DBG map bake %d ms" % (Time.get_ticks_msec() - t0))
	# fold the 1000+ tiny GLB nodes into ~14 m chunks, one surface per
	# material: same pixels, a fraction of the draw calls / node overhead
	t0 = Time.get_ticks_msec()
	var folded := 0
	if OS.get_environment("BR_NOMERGE") != "1":
		folded = MeshMerge.merge_subtree(inst, 14.0 / sc, true, true)
	_collision(inst)
	if OS.get_environment("BR_DEBUG") == "1":
		print("DBG map merge %d meshes folded, %d ms" % [folded, Time.get_ticks_msec() - t0])


func _collision(inst: Node3D) -> void:
	# one static body, one trimesh shape per (merged) mesh instance
	var mis: Array[MeshInstance3D] = []
	_collect(inst, mis)
	var body := StaticBody3D.new()
	body.name = "MapBody"
	for mi in mis:
		if mi.mesh == null:
			continue
		var sh := mi.mesh.create_trimesh_shape()
		if sh == null:
			continue
		sh.backface_collision = true   # some community meshes have flipped floors
		var cs := CollisionShape3D.new()
		cs.shape = sh
		cs.transform = mi.transform
		var holder := mi.get_parent()
		while holder != null and holder != inst:
			cs.transform = holder.transform * cs.transform
			holder = holder.get_parent()
		cs.transform = inst.transform * cs.transform
		body.add_child(cs)
	add_child(body)


func _cull_boxes(inst: Node3D) -> void:
	## Removes props whose AABB lies inside one of def["cull_glb"] boxes
	## ([x0,y0,z0, x1,y1,z1] in GLB coordinates) -- e.g. a cabinet the level
	## author parked in front of the service corridor.
	if not def.has("cull_glb") and not def.has("cull_above_glb") and not def.has("clip_glb"):
		return
	var mis: Array[MeshInstance3D] = []
	_collect(inst, mis)
	var removed := 0
	# whole-scene filters (Level 7: the maze is a pit under a huge terrain
	# mesh; everything above the wall tops and outside the pit slab is
	# decoration that would only confuse the walkability grid)
	if def.has("cull_above_glb") or def.has("clip_glb"):
		var y_cut: float = def.get("cull_above_glb", INF)
		var clip: Array = def.get("clip_glb", [])
		for mi in mis:
			var ab := mi.get_aabb()
			var xf := inst.global_transform.affine_inverse() * mi.global_transform
			var mn := Vector3(INF, INF, INF)
			var mx := -mn
			for k in range(8):
				var c := xf * ab.get_endpoint(k)
				mn = mn.min(c)
				mx = mx.max(c)
			var drop := mn.y > y_cut
			if not drop and clip.size() == 4:
				drop = mx.x < float(clip[0]) or mx.z < float(clip[1]) or mn.x > float(clip[2]) or mn.z > float(clip[3])
			if drop:
				mi.get_parent().remove_child(mi)
				mi.queue_free()
				removed += 1
	for b in def.get("cull_glb", []):
		var lo := Vector3(b[0], b[1], b[2])
		var hi := Vector3(b[3], b[4], b[5])
		for mi in mis:
			if not is_instance_valid(mi) or mi.is_queued_for_deletion():
				continue
			var ab := mi.get_aabb()
			var xf := inst.global_transform.affine_inverse() * mi.global_transform
			var mn := Vector3(INF, INF, INF)
			var mx := -mn
			for k in range(8):
				var c := xf * ab.get_endpoint(k)
				mn = mn.min(c)
				mx = mx.max(c)
			if mn.x >= lo.x and mn.y >= lo.y and mn.z >= lo.z and mx.x <= hi.x and mx.y <= hi.y and mx.z <= hi.z:
				mi.get_parent().remove_child(mi)
				mi.queue_free()
				removed += 1
	if OS.get_environment("BR_DEBUG") == "1":
		print("DBG map cull removed %d meshes" % removed)


# ------------------------------------------------------------------ baking
func _bake(inst: Node3D) -> void:
	var mis: Array[MeshInstance3D] = []
	_collect(inst, mis)
	if mis.is_empty():
		return
	# world-space bounds + floor top
	var gmin := Vector3(INF, INF, INF)
	var gmax := Vector3(-INF, -INF, -INF)
	var floor_top := -INF
	var surf_verts: Array = []
	var surf_tris: Array = []
	for mi in mis:
		var gt := mi.global_transform
		for si in range(mi.mesh.get_surface_count()):
			var arrs := mi.mesh.surface_get_arrays(si)
			var verts: PackedVector3Array = arrs[Mesh.ARRAY_VERTEX]
			var idxs: PackedInt32Array = arrs[Mesh.ARRAY_INDEX]
			var wv := PackedVector3Array()
			wv.resize(verts.size())
			for i in range(verts.size()):
				var w := gt * verts[i]
				wv[i] = w
				gmin = gmin.min(w)
				gmax = gmax.max(w)
			surf_verts.append(wv)
			surf_tris.append(idxs)
	# floor top = the upward height bucket carrying the most surface area
	var buckets := {}
	for k in range(surf_tris.size()):
		var wv: PackedVector3Array = surf_verts[k]
		var ix: PackedInt32Array = surf_tris[k]
		for t in range(0, ix.size() - 2, 3):
			var a := wv[ix[t]]
			var b := wv[ix[t + 1]]
			var c := wv[ix[t + 2]]
			var n := (b - a).cross(c - a)
			var area := n.length() * 0.5
			if area < 1e-9:
				continue
			n = n.normalized()
			var ymax := maxf(maxf(a.y, b.y), c.y)
			if absf(n.y) > 0.6 and ymax < 0.65:
				var bk := int(round(ymax * 10.0))
				buckets[bk] = buckets.get(bk, 0.0) + area
	var best_area := 0.0
	for bk in buckets:
		if buckets[bk] > best_area:
			best_area = buckets[bk]
			floor_top = float(bk) / 10.0
	if floor_top == -INF:
		floor_top = gmin.y
	if def.has("floor_y_glb"):
		floor_top = float(def["floor_y_glb"]) * float(def["scale"])
	inst.position.y -= floor_top
	inst.position.x -= (gmin.x + gmax.x) * 0.5
	inst.position.z -= (gmin.z + gmax.z) * 0.5
	var shift := Vector3(-(gmin.x + gmax.x) * 0.5, -floor_top, -(gmin.z + gmax.z) * 0.5)
	glb_shift = shift
	glb_scale = float(def["scale"])

	# occupancy grid from the (shifted) triangles
	var sx := gmax.x - gmin.x
	var sz := gmax.z - gmin.z
	var gw := int(ceil(sx / CELL)) + 1
	var gh := int(ceil(sz / CELL)) + 1
	data.gw = gw
	data.gh = gh
	data.origin = Vector3(gmin.x + shift.x, 0.0, gmin.z + shift.z)
	if def.has("clip_glb"):
		# deterministic lattice anchored to the playable slab (scripted cell
		# coordinates in the level def rely on it)
		var cb: Array = def["clip_glb"]
		gw = int(ceil((float(cb[2]) - float(cb[0])) * glb_scale / CELL)) + 1
		gh = int(ceil((float(cb[3]) - float(cb[1])) * glb_scale / CELL)) + 1
		data.gw = gw
		data.gh = gh
		data.origin = Vector3(float(cb[0]) * glb_scale + shift.x, 0.0, float(cb[1]) * glb_scale + shift.z)
	# "fine" mode (narrow service corridors): a cell counts as floor/wall only
	# if its centre is really on / near the triangle, not merely inside its
	# bounding box -- otherwise a 1.3 m corridor between two 20 m walls
	# collapses into solid rock
	var fine: bool = def.get("fine_walls", false)
	# wall clearance (m): a cell whose centre is closer than this to a wall
	# triangle is solid. 0.18 = the old "touching" test; Level 7 uses ~0.37
	# (half the creature's width) so diagonal cell-to-cell steps can't leak
	# through 0.5 m walls
	var wall_clear: float = def.get("wall_clear", 0.18)
	if OS.get_environment("BR_WALLCLEAR") != "":
		wall_clear = float(OS.get_environment("BR_WALLCLEAR"))
	var wall_pad := int(ceil(wall_clear / CELL))
	var floor_c := PackedByteArray()
	var wall_c := PackedByteArray()
	var head_c := PackedByteArray()
	var fh_arr := PackedFloat32Array()
	var ch_arr := PackedFloat32Array()
	floor_c.resize(gw * gh)
	wall_c.resize(gw * gh)
	head_c.resize(gw * gh)
	fh_arr.resize(gw * gh)
	fh_arr.fill(-INF)
	ch_arr.resize(gw * gh)
	ch_arr.fill(INF)
	for k in range(surf_tris.size()):
		var wv: PackedVector3Array = surf_verts[k]
		var ix: PackedInt32Array = surf_tris[k]
		for t in range(0, ix.size() - 2, 3):
			var a := wv[ix[t]] + shift
			var b := wv[ix[t + 1]] + shift
			var c := wv[ix[t + 2]] + shift
			var n := (b - a).cross(c - a)
			if n.length() < 1e-9:
				continue
			n = n.normalized()
			var ymin := minf(a.y, minf(b.y, c.y))
			var ymax := maxf(a.y, maxf(b.y, c.y))
			var horiz := absf(n.y) > 0.6
			var tall := (ymax - ymin) > 1.2
			var pad := 0 if (horiz or not fine) else wall_pad
			var x0 := clampi(int(floor((minf(a.x, minf(b.x, c.x)) - data.origin.x) / CELL)) - pad, 0, gw - 1)
			var x1 := clampi(int(floor((maxf(a.x, maxf(b.x, c.x)) - data.origin.x) / CELL)) + pad, 0, gw - 1)
			var z0 := clampi(int(floor((minf(a.z, minf(b.z, c.z)) - data.origin.z) / CELL)) - pad, 0, gh - 1)
			var z1 := clampi(int(floor((maxf(a.z, maxf(b.z, c.z)) - data.origin.z) / CELL)) + pad, 0, gh - 1)
			var a2 := Vector2(a.x, a.z)
			var b2 := Vector2(b.x, b.z)
			var c2 := Vector2(c.x, c.z)
			for zy in range(z0, z1 + 1):
				for zx in range(x0, x1 + 1):
					var ci := zy * gw + zx
					if fine:
						var cc := Vector2(data.origin.x + (zx + 0.5) * CELL, data.origin.z + (zy + 0.5) * CELL)
						var dd := _dist_tri2(cc, a2, b2, c2)
						if horiz and dd > 0.08:
							continue
						if not horiz and dd > wall_clear:
							continue
					# coordinates are already floor-relative here (floor top = 0)
					if horiz and ymax < 0.6 and ymax > -0.6:
						floor_c[ci] = 1
						if ymax > fh_arr[ci]:
							fh_arr[ci] = ymax
					elif horiz and ymin > 0.7 and ymin < 2.0:
						head_c[ci] = 1
					elif horiz and ymin >= 2.0:
						if ymin < ch_arr[ci]:
							ch_arr[ci] = ymin
					elif not horiz and tall and ymin < 1.9 and ymax > 0.25:
						wall_c[ci] = 1
	data.solid.resize(gw * gh)
	data.floor_h.resize(gw * gh)
	data.ceil_h.resize(gw * gh)
	for i in range(gw * gh):
		data.solid[i] = 0 if (floor_c[i] == 1 and wall_c[i] == 0 and head_c[i] == 0) else 1
		data.floor_h[i] = 0.0 if fh_arr[i] == -INF else fh_arr[i]
		data.ceil_h[i] = 3.1 if ch_arr[i] == INF else ch_arr[i]
	if def.has("ceiling_h"):
		# open-top maze: a procedural slab closes it (built in _finish_map)
		data.ceil_h.fill(float(def["ceiling_h"]))
	if OS.get_environment("BR_MAPDBG") == "2":
		for y in range(gh):
			var row := ""
			for x in range(gw):
				var i := y * gw + x
				var ch := "."
				if floor_c[i] == 0:
					ch = "_"          # no floor
				elif wall_c[i] == 1:
					ch = "W"
				elif head_c[i] == 1:
					ch = "H"
				row += ch
			print("CMAPRAW %3d %s" % [y, row])
		print("CMAPRAW origin=%s" % str(data.origin))
	_keep_main_component()
	_finish_map()


static func _dist_seg2(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var l2 := ab.length_squared()
	if l2 < 1e-12:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / l2, 0.0, 1.0)
	return p.distance_to(a + ab * t)


static func _dist_tri2(p: Vector2, a: Vector2, b: Vector2, c: Vector2) -> float:
	# 0 inside the (possibly degenerate) triangle, else distance to its edges
	var d1 := (b - a).cross(p - a)
	var d2 := (c - b).cross(p - b)
	var d3 := (a - c).cross(p - c)
	var has_neg := d1 < 0.0 or d2 < 0.0 or d3 < 0.0
	var has_pos := d1 > 0.0 or d2 > 0.0 or d3 > 0.0
	if not (has_neg and has_pos):
		return 0.0
	return minf(_dist_seg2(p, a, b), minf(_dist_seg2(p, b, c), _dist_seg2(p, c, a)))


func _collect(n: Node, out: Array[MeshInstance3D]) -> void:
	for c in n.get_children():
		if c is MeshInstance3D:
			out.append(c)
		_collect(c, out)


func _keep_main_component() -> void:
	# flood fill from the walkable cell nearest the centre (or the scripted
	# spawn point when the level has one); seal the rest
	var start := -1
	var cx := data.gw / 2
	var cy := data.gh / 2
	if def.has("spawn_glb"):
		var sg: Array = def["spawn_glb"]
		var sw := Vector3(float(sg[0]) * glb_scale + glb_shift.x, 0.0, float(sg[1]) * glb_scale + glb_shift.z)
		var sc := data.world_to_grid(sw)
		cx = clampi(sc.x, 0, data.gw - 1)
		cy = clampi(sc.y, 0, data.gh - 1)
	var best := 1e9
	for y in range(data.gh):
		for x in range(data.gw):
			if data.solid[y * data.gw + x] == 0:
				var dd := (x - cx) * (x - cx) + (y - cy) * (y - cy)
				if dd < best:
					best = dd
					start = y * data.gw + x
	if start < 0:
		return
	var seen := PackedByteArray()
	seen.resize(data.gw * data.gh)
	var stack: Array[int] = [start]
	seen[start] = 1
	while not stack.is_empty():
		var cur: int = stack.pop_back()
		var x := cur % data.gw
		var y := cur / data.gw
		for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nx := x + d.x
			var ny := y + d.y
			if nx < 0 or ny < 0 or nx >= data.gw or ny >= data.gh:
				continue
			var ni := ny * data.gw + nx
			if seen[ni] == 0 and data.solid[ni] == 0:
				seen[ni] = 1
				stack.append(ni)
	for i in range(data.solid.size()):
		if data.solid[i] == 0 and seen[i] == 0:
			data.solid[i] = 1


func _finish_map() -> void:
	for y in range(data.gh):
		for x in range(data.gw):
			if data.solid[y * data.gw + x] == 0:
				data.rooms.append(Vector2i(x, y))
	if data.rooms.is_empty():
		return
	# nav grid
	astar = AStarGrid2D.new()
	astar.region = Rect2i(0, 0, data.gw, data.gh)
	astar.cell_size = Vector2.ONE
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_MANHATTAN
	astar.update()
	for y in range(data.gh):
		for x in range(data.gw):
			if data.solid[y * data.gw + x] == 1:
				astar.set_point_solid(Vector2i(x, y), true)
	# cells hugging a wall cost more, so paths stay centred in corridors
	# (the creature's capsule is wider than half a cell)
	for y in range(data.gh):
		for x in range(data.gw):
			if data.solid[y * data.gw + x] == 1:
				continue
			var near := false
			for dd: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
					Vector2i(1, 1), Vector2i(-1, 1), Vector2i(1, -1), Vector2i(-1, -1)]:
				if data.is_solid(x + dd.x, y + dd.y):
					near = true
					break
			if near:
				astar.set_point_weight_scale(Vector2i(x, y), 3.5)
	# bfs distances from the centre cell = player spawn (or a scripted point)
	var spawn_cell := data.rooms[0]
	if def.has("spawn_glb"):
		var sg: Array = def["spawn_glb"]
		spawn_cell = _nearest_free(_clamp_grid(data.world_to_grid(glb_to_world(sg[0], sg[1]))))
		spawn_yaw = deg_to_rad(float(def.get("spawn_yaw_deg", 0.0)))
	else:
		var bc := Vector2(data.gw * 0.5, data.gh * 0.5)
		var bd := 1e9
		for p in data.rooms:
			var dd := (Vector2(p.x, p.y) - bc).length()
			if dd < bd:
				bd = dd
				spawn_cell = p
	data.player_spawn = data.grid_to_world(spawn_cell) + Vector3(0, 0.15, 0)
	var dist := _bfs(spawn_cell)
	var far_cell := spawn_cell
	var far_d := -1
	if def.has("door_glb"):
		var dg: Array = def["door_glb"]
		far_cell = _nearest_free(_clamp_grid(data.world_to_grid(glb_to_world(dg[0], dg[1]))))
		far_d = dist[data.idx(far_cell.x, far_cell.y)]
	else:
		for p in data.rooms:
			var dv := dist[data.idx(p.x, p.y)]
			if dv > far_d:
				far_d = dv
				far_cell = p
	data.exit_point = far_cell
	# monster: far from player, not next to the exit
	var mon_cell := spawn_cell
	var mon_d := -1
	for p in data.rooms:
		var dv := dist[data.idx(p.x, p.y)]
		var de := absi(p.x - far_cell.x) + absi(p.y - far_cell.y)
		if dv > mon_d and de > 8:
			mon_d = dv
			mon_cell = p
	data.monster_spawn = data.grid_to_world(mon_cell) + Vector3(0, 0.05, 0)
	_lights(dist)
	if def.has("ceiling_h"):
		_ceiling_slab()
	if OS.get_environment("BR_MAPDBG") == "1":
		_dbg_dump()
	_zones()
	_pickups(spawn_cell, dist)
	_exit(far_cell)
	_clutter(spawn_cell, far_cell)


func _bfs(start: Vector2i) -> PackedInt32Array:
	var dist := PackedInt32Array()
	dist.resize(data.gw * data.gh)
	dist.fill(-1)
	dist[data.idx(start.x, start.y)] = 0
	var q: Array[Vector2i] = [start]
	var head := 0
	while head < q.size():
		var cur := q[head]
		head += 1
		var d0 := dist[data.idx(cur.x, cur.y)]
		for dd: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n := cur + dd
			if n.x < 0 or n.y < 0 or n.x >= data.gw or n.y >= data.gh:
				continue
			if data.solid[data.idx(n.x, n.y)] == 1:
				continue
			if dist[data.idx(n.x, n.y)] == -1:
				dist[data.idx(n.x, n.y)] = d0 + 1
				q.append(n)
	return dist


func _dbg_dump() -> void:
	var walk := 0
	for i in range(data.solid.size()):
		if data.solid[i] == 0:
			walk += 1
	print("CMAP gw=%d gh=%d walkable=%d lights=%d rooms=%d spawn=%s mon=%s" % [
		data.gw, data.gh, walk, lights_on.size(), data.rooms.size(),
		data.player_spawn, data.monster_spawn])
	for y in range(0, data.gh, 1):
		var row := ""
		for x in range(0, data.gw, 1):
			row += "." if data.solid[y * data.gw + x] == 0 else "#"
		print("CMAPROW %3d %s" % [y, row])


func _lights(dist: PackedInt32Array) -> void:
	mat_panel = StandardMaterial3D.new()
	mat_panel.albedo_color = Color(0.9, 0.88, 0.8)
	mat_panel.emission_enabled = true
	mat_panel.emission = Color(1.0, 0.95, 0.82)
	mat_panel.emission_energy_multiplier = 1.4
	var step := int(round(float(def.get("lamp_step", 5.0)) / CELL))
	var on_chance: float = def.get("lamp_on", 0.74)
	# typical ceiling height = most common bucket; cells with odd values
	# (beams, holes in the mesh) get no lamp so nothing floats mid-air
	var hist := {}
	for i in range(data.ceil_h.size()):
		if data.solid[i] == 0:
			var k := int(round(data.ceil_h[i] * 4.0))
			hist[k] = hist.get(k, 0) + 1
	var best_k := 0
	var best_n := -1
	for k in hist:
		if hist[k] > best_n:
			best_n = hist[k]
			best_k = k
	var typ_ceil := best_k / 4.0
	for y in range(2, data.gh - 2, step):
		for x in range(2, data.gw - 2, step):
			if data.solid[data.idx(x, y)] == 1:
				continue
			if absf(data.ceil_h[data.idx(x, y)] - typ_ceil) > 0.4:
				continue
			var w := data.grid_to_world(Vector2i(x, y))
			var on := rng.randf() < on_chance
			var li: OmniLight3D = null
			if on:
				# dead lamps get no light node at all (they used to be energy 0 lights)
				li = OmniLight3D.new()
				li.light_color = Color(1.0, 0.93, 0.78)
				li.light_energy = float(def.get("lamp_energy", 2.8))
				li.omni_range = 10.0
				li.omni_attenuation = 1.3
				li.shadow_enabled = false
				li.distance_fade_enabled = true
				li.distance_fade_begin = 38.0
				li.distance_fade_length = 12.0
				li.position = Vector3(w.x, data.ceil_h[data.idx(x, y)] - 0.35, w.z)
				li.set_meta("lamp_i", lamp_lights.size())
				add_child(li)
				lamp_lights.append(li)
			var pn := MeshInstance3D.new()
			var pm := PlaneMesh.new()
			pm.size = Vector2(1.1, 1.1)
			pm.material = mat_panel
			pn.mesh = pm
			pn.rotation_degrees.x = 90
			pn.position = Vector3(w.x, data.ceil_h[data.idx(x, y)] - 0.10, w.z)
			pn.visible = on
			pn.visibility_range_end = 70.0
			pn.visibility_range_end_margin = 5.0
			add_child(pn)
			if on:
				lamp_panels.append(pn)
				lights_on.append(Vector3(w.x, w.y + 1.4, w.z))
	apply_graphics()


func apply_graphics() -> void:
	## Lamp density / radius per graphics preset. The emissive panels always
	## stay (they are cheap); only the OmniLights are thinned out.
	var g := GameSettings
	var dens := g.gfx_lamp_density()
	var mul := g.gfx_light_range_mul()
	var far := g.gfx_far()
	for i in range(lamp_lights.size()):
		var li := lamp_lights[i]
		# deterministic thinning so the same lamps stay dark between calls
		var keep := dens >= 0.999 or (fposmod(float(i) * 0.6180339887, 1.0) < dens)
		li.visible = keep
		li.omni_range = 10.0 * mul
		li.light_energy = float(def.get("lamp_energy", 2.8)) if keep else 0.0
		li.distance_fade_begin = minf(38.0, far * 0.55)
	# far plane governs how far the emissive panels are drawn
	for pn in lamp_panels:
		pn.visibility_range_end = minf(70.0, far * 0.9)


func _zones() -> void:
	data.zone.resize(data.gw * data.gh)
	for y in range(data.gh):
		for x in range(data.gw):
			var i := data.idx(x, y)
			if data.solid[i] == 1:
				data.zone[i] = CMapData.Zone.DARK
				continue
			var w := data.grid_to_world(Vector2i(x, y))
			var best := 1e9
			for l in lights_on:
				var dd := (l - w).length()
				if dd < best:
					best = dd
			if best < 7.0:
				data.zone[i] = CMapData.Zone.LIT
			elif best < 10.5:
				data.zone[i] = CMapData.Zone.DIM
			else:
				data.zone[i] = CMapData.Zone.DARK
			if data.zone[i] == CMapData.Zone.LIT and rng.randf() < 0.06:
				data.zone[i] = CMapData.Zone.WET


func _pickups(_spawn: Vector2i, dist: PackedInt32Array) -> void:
	var pool: Array[Vector2i] = data.rooms.duplicate()
	_seeded_shuffle(pool, rng)      # v10: identical on every co-op peer
	var picked: Array[Vector2i] = []
	var want: int = def.get("pickups", 6)
	for p in pool:
		var dv := dist[data.idx(p.x, p.y)]
		if dv < 6:
			continue
		var ok := true
		for q in picked:
			if (q - p).length() < 9:
				ok = false
				break
		if ok:
			picked.append(p)
		if picked.size() >= want:
			break
	data.water_points.clear()
	data.battery_points.clear()
	for i in range(picked.size()):
		if i % 3 == 2:
			data.battery_points.append(picked[i])
		else:
			data.water_points.append(picked[i])


func _exit(cell: Vector2i) -> void:
	# A real door in a frame, standing in the walkable cell farthest from
	# the spawn. Facing = towards the nearest solid wall so it reads as
	# "set into" the wall; if none is close it just stands free.
	var w := data.grid_to_world(cell)
	var ch := data.ceil_h[data.idx(cell.x, cell.y)]
	var yaw := 0.0
	var best := 99
	for dir: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		for r in range(1, 6):
			var q := cell + dir * r
			if data.is_solid(q.x, q.y):
				if r < best:
					best = r
					yaw = atan2(float(dir.x), float(dir.y))
				break
	var pos := w
	if best < 99:
		var dir_v := Vector3(sin(yaw), 0, cos(yaw))
		pos = w + dir_v * (best * CELL - CELL * 0.55)
	if def.has("door_yaw_deg") and def.has("door_glb"):
		# scripted levels: the door stands exactly in a gap of the source
		# mesh, facing a known direction (yaw = direction *into* the wall /
		# away from the player)
		yaw = deg_to_rad(float(def["door_yaw_deg"]))
		var dg: Array = def["door_glb"]
		var dw := glb_to_world(float(dg[0]), float(dg[1]))
		pos = Vector3(dw.x, w.y, dw.z)
	var is_exit: bool = def.get("door_is_exit", false) or def.get("door_red", false)
	var iron: bool = def.get("door_style", "") == "iron"
	door = _make_door(Vector3(pos.x, w.y, pos.z), yaw, is_exit, iron, ch)
	set_meta("exit_area", door.get_node("DoorArea"))
	data.exit_point = cell


func _make_door(pos: Vector3, yaw: float, is_exit: bool, iron: bool, ch: float = 3.0) -> Node3D:
	## Builds a door prop at `pos`; `yaw` = direction into the wall (the
	## visible side / handle / lights face the opposite way). Child
	## "DoorArea" (layer 4) is the interaction area; the caller wires it.
	var dn := Node3D.new()
	dn.name = "LevelDoor"
	dn.position = pos
	# local +Z = towards the player (away from the wall): the handle, rivets,
	# wheel and the two lights all sit on the visible side
	dn.rotation.y = yaw + PI
	add_child(dn)

	var mat_frame := StandardMaterial3D.new()
	mat_frame.albedo_color = Color(0.16, 0.15, 0.14)
	mat_frame.roughness = 0.6
	mat_frame.metallic = 0.5
	var mat_door := StandardMaterial3D.new()
	mat_door.albedo_texture = load("res://textures/metal.png")
	mat_door.normal_texture = load("res://textures/metal_n.png")
	mat_door.normal_enabled = true
	mat_door.albedo_color = Color(0.45, 0.14, 0.10) if is_exit else Color(0.30, 0.31, 0.30)
	mat_door.roughness = 0.55
	mat_door.metallic = 0.35
	if iron:
		# heavy riveted steel: darker, colder, rustier
		mat_door.albedo_color = Color(0.20, 0.21, 0.22)
		mat_door.roughness = 0.42
		mat_door.metallic = 0.85
		mat_frame.albedo_color = Color(0.10, 0.10, 0.11)
		mat_frame.metallic = 0.8
	var mat_sign := StandardMaterial3D.new()
	mat_sign.albedo_color = Color(0.1, 0.5, 0.2)
	mat_sign.emission_enabled = true
	mat_sign.emission = Color(0.25, 1.0, 0.45) if is_exit else Color(1.0, 0.55, 0.2)
	mat_sign.emission_energy_multiplier = 2.4
	mat_exit = mat_sign

	# frame
	for sx in [-1.0, 1.0]:
		var post := MeshInstance3D.new()
		var pm := BoxMesh.new()
		pm.size = Vector3(0.14, 2.35, 0.22)
		pm.material = mat_frame
		post.mesh = pm
		post.position = Vector3(sx * 0.62, 1.175, 0)
		dn.add_child(post)
	var lintel := MeshInstance3D.new()
	var lm := BoxMesh.new()
	lm.size = Vector3(1.38, 0.14, 0.22)
	lm.material = mat_frame
	lintel.mesh = lm
	lintel.position = Vector3(0, 2.28, 0)
	dn.add_child(lintel)
	# leaf
	var leaf := MeshInstance3D.new()
	var lfm := BoxMesh.new()
	lfm.size = Vector3(1.08, 2.18, 0.08)
	lfm.material = mat_door
	leaf.mesh = lfm
	leaf.name = "Leaf"
	leaf.position = Vector3(0, 1.10, 0)
	dn.add_child(leaf)
	# handle
	var handle := MeshInstance3D.new()
	var hm := CylinderMesh.new()
	hm.top_radius = 0.02
	hm.bottom_radius = 0.02
	hm.height = 0.16
	hm.material = mat_frame
	handle.mesh = hm
	handle.rotation.z = PI / 2.0
	handle.position = Vector3(0.40, 1.02, 0.07)
	dn.add_child(handle)
	if iron:
		lfm.size = Vector3(1.08, 2.18, 0.14)
		# rivet rows along the edges + two cross straps + a locking wheel
		var mat_rivet := StandardMaterial3D.new()
		mat_rivet.albedo_color = Color(0.32, 0.30, 0.27)
		mat_rivet.metallic = 0.9
		mat_rivet.roughness = 0.35
		var rm := SphereMesh.new()
		rm.radius = 0.022
		rm.height = 0.044
		rm.material = mat_rivet
		for ry in range(8):
			for rx in [-0.46, 0.46]:
				var rv := MeshInstance3D.new()
				rv.mesh = rm
				rv.position = Vector3(rx, 0.18 + ry * 0.265, 0.075)
				dn.add_child(rv)
		for sy in [0.55, 1.65]:
			var strap := MeshInstance3D.new()
			var stm := BoxMesh.new()
			stm.size = Vector3(1.0, 0.12, 0.03)
			stm.material = mat_rivet
			strap.mesh = stm
			strap.position = Vector3(0, sy, 0.085)
			dn.add_child(strap)
		handle.visible = false
		var wheel := MeshInstance3D.new()
		var wm := TorusMesh.new()
		wm.inner_radius = 0.13
		wm.outer_radius = 0.17
		wm.material = mat_rivet
		wheel.mesh = wm
		wheel.rotation.x = PI / 2.0
		wheel.position = Vector3(0.0, 1.05, 0.14)
		dn.add_child(wheel)
		for sa in [0.0, PI / 3.0, 2.0 * PI / 3.0]:
			var spoke := MeshInstance3D.new()
			var spm := BoxMesh.new()
			spm.size = Vector3(0.30, 0.025, 0.025)
			spm.material = mat_rivet
			spoke.mesh = spm
			spoke.rotation.z = sa
			spoke.position = Vector3(0.0, 1.05, 0.14)
			dn.add_child(spoke)
		# warning plate instead of the exit sign (applied below)
		mat_sign.albedo_color = Color(0.35, 0.12, 0.05)
		mat_sign.emission = Color(1.0, 0.45, 0.15)
		mat_sign.emission_energy_multiplier = 1.2
	# small window slit + sign above
	var sign := MeshInstance3D.new()
	var sm := BoxMesh.new()
	sm.size = Vector3(0.7, 0.22, 0.05)
	sm.material = mat_sign
	sign.mesh = sm
	sign.position = Vector3(0, 2.52, 0.0)
	if iron:
		sm.size = Vector3(0.36, 0.30, 0.05)
	dn.add_child(sign)
	var gl := OmniLight3D.new()
	gl.light_color = mat_sign.emission
	gl.light_energy = 1.3
	gl.omni_range = 5.0
	gl.shadow_enabled = false
	gl.position = Vector3(0, 2.4, 0.5)
	dn.add_child(gl)
	# a dim ceiling lamp near the door so it's never in pitch dark
	var li := OmniLight3D.new()
	li.light_color = Color(1.0, 0.93, 0.78)
	li.light_energy = 1.6
	li.omni_range = 7.0
	li.shadow_enabled = false
	li.position = Vector3(0, minf(ch, 3.0) - 0.4, 1.0)
	dn.add_child(li)
	# blocking body so you can't walk through the closed leaf
	var body := StaticBody3D.new()
	var bcs := CollisionShape3D.new()
	var bb := BoxShape3D.new()
	bb.size = Vector3(1.38, 2.4, 0.2)
	bcs.shape = bb
	bcs.position = Vector3(0, 1.2, 0)
	body.add_child(bcs)
	dn.add_child(body)
	# interaction area
	var area := Area3D.new()
	area.name = "DoorArea"
	area.collision_layer = 4
	area.collision_mask = 0
	area.monitoring = false
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(1.5, 2.4, 1.2)
	cs.shape = bs
	area.add_child(cs)
	area.position = Vector3(0, 1.2, 0.0)
	dn.add_child(area)
	return dn


func glb_to_world(gx: float, gz: float) -> Vector3:
	## Point given in the source GLB's own coordinates -> world (floor height
	## taken from the walkability grid).
	var w := Vector3(gx * glb_scale + glb_shift.x, 0.0, gz * glb_scale + glb_shift.z)
	var g := data.world_to_grid(w)
	if g.x >= 0 and g.y >= 0 and g.x < data.gw and g.y < data.gh:
		w.y = data.floor_h[data.idx(g.x, g.y)]
	return w


func nearest_walkable(w: Vector3) -> Vector3:
	var g := _nearest_free(_clamp_grid(data.world_to_grid(w)))
	return data.grid_to_world(g)


func is_reachable(a: Vector3, b: Vector3) -> bool:
	return get_nav_path(a, b).size() > 1


func door_world_position() -> Vector3:
	return door.global_position if door != null else data.grid_to_world(data.exit_point)


# ------------------------------------------------------------------ Level API
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
	# a few stutters, then dark
	var tw := create_tween()
	for k in range(5):
		tw.tween_property(li, "light_energy", 0.3, 0.05)
		tw.tween_property(li, "light_energy", 2.8, 0.07 + k * 0.03)
	tw.tween_property(li, "light_energy", 0.0, 0.05)
	if pn != null:
		tw.tween_callback(func(): pn.visible = false)


func flicker_fixture(i: int, dur := 1.2) -> void:
	if i < 0 or i >= lamp_lights.size():
		return
	var li := lamp_lights[i]
	var tw := create_tween()
	var t := 0.0
	while t < dur:
		var step := randf_range(0.04, 0.16)
		tw.tween_property(li, "light_energy", randf_range(0.2, 1.4), step * 0.4)
		tw.tween_property(li, "light_energy", 2.8, step * 0.6)
		t += step
	tw.tween_property(li, "light_energy", 2.8, 0.05)


func get_nav_path(from_world: Vector3, to_world: Vector3) -> PackedVector3Array:
	var out := PackedVector3Array()
	if astar == null:
		return out
	var a := _clamp_grid(data.world_to_grid(from_world))
	var b := _clamp_grid(data.world_to_grid(to_world))
	a = _nearest_free(a)
	b = _nearest_free(b)
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


func is_lit_at(p: Vector3) -> bool:
	var g := data.world_to_grid(p)
	if g.x < 0 or g.y < 0 or g.x >= data.gw or g.y >= data.gh:
		return false
	var z := data.zone[data.idx(g.x, g.y)]
	return z != CMapData.Zone.DARK


# ---------------------------------------------------------------------------
#  set dressing: knocked-over chairs (Kenney Furniture Kit, CC0) and paper
#  scattered on the floor. Collision only for the player (layer 16) so the
#  creatures never snag on them; nav cells with a chair cost extra so their
#  paths tend to go around.
# ---------------------------------------------------------------------------
const CHAIR_SCENES := ["res://models/props/chair.glb", "res://models/props/chair_desk.glb", "res://models/props/chair_cushion.glb"]
var _paper_mats: Array[StandardMaterial3D] = []


func _clutter(spawn_cell: Vector2i, door_cell: Vector2i) -> void:
	var n_chairs: int = def.get("chairs", 0)
	var n_paper: int = def.get("papers", 0)
	if n_chairs <= 0 and n_paper <= 0:
		return
	var crng := RandomNumberGenerator.new()
	crng.seed = rng.seed + 101
	var keep_out: Array[Vector2i] = [spawn_cell, door_cell]
	if def.has("crate_glb"):
		var cg: Array = def["crate_glb"]
		keep_out.append(_clamp_grid(data.world_to_grid(glb_to_world(cg[0], cg[1]))))
	# never on (or hugging) the main spawn->door route: chairs must be scenery,
	# not an obstacle course
	var route := {}
	for pp in astar.get_point_path(spawn_cell, door_cell):
		route[Vector2i(int(pp.x), int(pp.y))] = true
	var pool: Array[Vector2i] = data.rooms.duplicate()
	_seeded_shuffle(pool, crng)     # v10: identical on every co-op peer
	var root := Node3D.new()
	root.name = "Clutter"
	add_child(root)
	# --- chairs: need a 3x3 free block (never inside tight corridors) --------
	var used: Array[Vector2i] = []
	var placed := 0
	var scenes: Array[PackedScene] = []
	for sp in CHAIR_SCENES:
		var ps: PackedScene = load(sp)
		if ps != null:
			scenes.append(ps)
	if not scenes.is_empty():
		for c in pool:
			if placed >= n_chairs:
				break
			if not _clear_around(c, 2) or _near_any(c, keep_out, 4) or _near_any(c, used, 5):
				continue
			if _near_route(c, route, 2):
				continue
			used.append(c)
			_spawn_chair(root, c, scenes[crng.randi_range(0, scenes.size() - 1)], crng)
			astar.set_point_weight_scale(c, 4.0)
			placed += 1
	# --- paper: clusters of 3..8 sheets ---------------------------------------
	if n_paper > 0:
		_make_paper_mats()
		var mesh := QuadMesh.new()
		mesh.size = Vector2(0.21, 0.297)
		mesh.orientation = PlaneMesh.FACE_Y
		var clusters := 0
		var pused: Array[Vector2i] = []
		var proot := Node3D.new()
		proot.name = "Paper"
		root.add_child(proot)
		for c in pool:
			if clusters >= n_paper:
				break
			if data.is_solid(c.x, c.y) or _near_any(c, keep_out, 2) or _near_any(c, pused, 4):
				continue
			pused.append(c)
			clusters += 1
			var centre := data.grid_to_world(c)
			var cnt := crng.randi_range(3, 8)
			for k in range(cnt):
				var off := Vector3(crng.randf_range(-1.1, 1.1), 0, crng.randf_range(-1.1, 1.1))
				var wp := centre + off
				var gc := data.world_to_grid(wp)
				if data.is_solid(gc.x, gc.y):
					continue
				var mi := MeshInstance3D.new()
				mi.mesh = mesh
				mi.material_override = _paper_mats[crng.randi_range(0, _paper_mats.size() - 1)]
				mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				mi.position = Vector3(wp.x, data.grid_to_world(gc).y + 0.006 + k * 0.002, wp.z)
				mi.rotation.y = crng.randf_range(0.0, TAU)
				mi.scale = Vector3.ONE * crng.randf_range(0.9, 1.15)
				proot.add_child(mi)
		# hundreds of A4 quads -> a handful of chunked meshes (4 paper materials)
		MeshMerge.merge_subtree(proot, 14.0, true, false)
	if OS.get_environment("BR_DEBUG") == "1":
		print("DBG clutter: %d chairs, %d paper clusters" % [placed, n_paper])


func _clear_around(c: Vector2i, r: int) -> bool:
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			if data.is_solid(c.x + dx, c.y + dy):
				return false
	return true


func _near_route(c: Vector2i, route: Dictionary, r: int) -> bool:
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			if route.has(c + Vector2i(dx, dy)):
				return true
	return false


func _near_any(c: Vector2i, arr: Array[Vector2i], r: int) -> bool:
	for q in arr:
		if absi(q.x - c.x) <= r and absi(q.y - c.y) <= r:
			return true
	return false


func _spawn_chair(root: Node3D, c: Vector2i, ps: PackedScene, crng: RandomNumberGenerator) -> void:
	var base := data.grid_to_world(c)
	var holder := Node3D.new()
	holder.position = base + Vector3(crng.randf_range(-0.25, 0.25), 0.0, crng.randf_range(-0.25, 0.25))
	holder.rotation.y = crng.randf_range(0.0, TAU)
	root.add_child(holder)
	var inst: Node3D = ps.instantiate() as Node3D
	# Kenney chairs are ~0.47 units tall -> real size
	var sc := 1.9 * crng.randf_range(0.95, 1.05)
	inst.scale = Vector3.ONE * sc
	var toppled := crng.randf() < 0.45
	if toppled:
		# lying on its side: rotate about Z, model origin sits at a base corner
		inst.rotation.z = PI / 2.0 if crng.randf() < 0.5 else -PI / 2.0
		if inst.rotation.z < 0.0:
			inst.position.y = 0.2 * sc
	else:
		inst.rotation.x = crng.randf_range(-0.03, 0.03)
	holder.add_child(inst)
	_grime(inst)
	# player-only collision (layer 16)
	var body := StaticBody3D.new()
	body.collision_layer = 16
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	if toppled:
		shape.size = Vector3(0.95, 0.42, 0.55)
		cs.position = Vector3(-0.45, 0.21, -0.2)
	else:
		shape.size = Vector3(0.42, 0.95, 0.42)
		cs.position = Vector3(0.2, 0.47, -0.2)
	cs.shape = shape
	body.add_child(cs)
	holder.add_child(body)


func _restyle(inst: Node3D, min_lum: float) -> void:
	## Some Rec Room exports ship near-black albedo factors (0.009) on top of
	## a proper texture: under our lamps that reads as a void. Lift every
	## material darker than `min_lum` up to it, keeping the hue.
	var mis: Array[MeshInstance3D] = []
	_collect(inst, mis)
	var done := {}
	for mi in mis:
		if mi.mesh == null:
			continue
		for si in range(mi.mesh.get_surface_count()):
			var m := mi.mesh.surface_get_material(si)
			if m == null or done.has(m.get_instance_id()):
				continue
			done[m.get_instance_id()] = true
			if m is StandardMaterial3D:
				var sm: StandardMaterial3D = m
				var a := sm.albedo_color
				var lum := a.r * 0.3 + a.g * 0.59 + a.b * 0.11
				if lum < min_lum:
					var k := min_lum / maxf(lum, 0.002)
					sm.albedo_color = Color(minf(a.r * k, 1.0), minf(a.g * k, 1.0), minf(a.b * k, 1.0), a.a)
				sm.roughness = maxf(sm.roughness, 0.85)
				sm.metallic = 0.0


func _ceiling_slab() -> void:
	## Open-top pits (Level 7) get a flat concrete lid at def["ceiling_h"] so
	## the lamps have something to hang from; def["ceiling_hole_glb"]
	## [x0, z0, x1, z1] leaves a rectangular opening (the stair shaft).
	var h := float(def["ceiling_h"])
	var x0 := data.origin.x - 2.0
	var z0 := data.origin.z - 2.0
	var x1 := data.origin.x + data.gw * CELL + 2.0
	var z1 := data.origin.z + data.gh * CELL + 2.0
	var rects: Array = []
	if def.has("ceiling_hole_glb"):
		var hg: Array = def["ceiling_hole_glb"]
		var a := glb_to_world(float(hg[0]), float(hg[1]))
		var b := glb_to_world(float(hg[2]), float(hg[3]))
		var hx0 := minf(a.x, b.x)
		var hx1 := maxf(a.x, b.x)
		var hz0 := minf(a.z, b.z)
		var hz1 := maxf(a.z, b.z)
		rects = [[x0, z0, x1, hz0], [x0, hz1, x1, z1], [x0, hz0, hx0, hz1], [hx1, hz0, x1, hz1]]
	else:
		rects = [[x0, z0, x1, z1]]
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = load("res://textures/metal.png")
	mat.albedo_color = Color(0.30, 0.28, 0.25)
	mat.roughness = 0.95
	mat.metallic = 0.0
	mat.uv1_scale = Vector3(30, 55, 1)
	var holder := Node3D.new()
	holder.name = "CeilingSlab"
	add_child(holder)
	var body := StaticBody3D.new()
	holder.add_child(body)
	for r in rects:
		var w := float(r[2]) - float(r[0])
		var d := float(r[3]) - float(r[1])
		if w <= 0.01 or d <= 0.01:
			continue
		var mi := MeshInstance3D.new()
		var pm := PlaneMesh.new()
		pm.size = Vector2(w, d)
		pm.material = mat
		mi.mesh = pm
		mi.rotation_degrees.x = 180.0     # faces down
		mi.position = Vector3(float(r[0]) + w * 0.5, h, float(r[1]) + d * 0.5)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		holder.add_child(mi)
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = Vector3(w, 0.2, d)
		cs.shape = bs
		cs.position = Vector3(float(r[0]) + w * 0.5, h + 0.1, float(r[1]) + d * 0.5)
		body.add_child(cs)


func _grime(n: Node) -> void:
	## Kenney's clean pastel materials -> dusty, dark, worn.
	if n is MeshInstance3D:
		var mi: MeshInstance3D = n
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if mi.mesh != null:
			for i in range(mi.mesh.get_surface_count()):
				var m := mi.mesh.surface_get_material(i)
				if m is StandardMaterial3D:
					var sm: StandardMaterial3D = (m as StandardMaterial3D).duplicate()
					var a := sm.albedo_color
					var lum := a.r * 0.3 + a.g * 0.59 + a.b * 0.11
					sm.albedo_color = a.lerp(Color(lum, lum, lum), 0.55) * Color(0.42, 0.38, 0.33)
					sm.roughness = 0.92
					sm.metallic = 0.0
					mi.set_surface_override_material(i, sm)
	for c in n.get_children():
		_grime(c)


func _make_paper_mats() -> void:
	if not _paper_mats.is_empty():
		return
	var tex: Texture2D = load("res://textures/paper.png")
	for k in range(4):
		var m := StandardMaterial3D.new()
		m.albedo_texture = tex
		m.albedo_color = Color(0.9, 0.86, 0.78)
		m.uv1_scale = Vector3(0.5, 0.5, 1.0)
		m.uv1_offset = Vector3(0.5 * (k % 2), 0.5 * (k / 2), 0.0)
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		m.alpha_scissor_threshold = 0.5
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		m.roughness = 1.0
		m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
		_paper_mats.append(m)


func _seeded_shuffle(arr: Array, r: RandomNumberGenerator) -> void:
	## Fisher-Yates on the level RNG (Array.shuffle() uses the global one).
	for i in range(arr.size() - 1, 0, -1):
		var j := r.randi_range(0, i)
		var tmp = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp
