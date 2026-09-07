class_name MeshMerge
## Folds many small MeshInstance3Ds into a few big ones (one surface per
## material, optionally split into spatial chunks so frustum culling still
## works). The community GLB maps arrive as 1000+ separate nodes -- one draw
## call each -- and the spider GLB is 135 tiny meshes. Geometry, materials
## and UVs are copied verbatim, so nothing changes visually.


static func merge_subtree(root: Node3D, chunk: float = 0.0, prune: bool = false, shadows: bool = true) -> int:
	## Returns the number of MeshInstance3D nodes that were folded away.
	var mis: Array[MeshInstance3D] = []
	_collect(root, mis)
	if mis.size() < 2:
		return 0
	var groups := {}       # Vector3i chunk key -> { material id -> [SurfaceTool, Material] }
	var folded := 0
	for mi in mis:
		if mi.mesh == null:
			continue
		var rel := _rel_xf(mi, root)
		var centre := rel * mi.get_aabb().get_center()
		var key := Vector3i.ZERO
		if chunk > 0.0:
			key = Vector3i(floori(centre.x / chunk), floori(centre.y / chunk), floori(centre.z / chunk))
		var origin := _origin(key, chunk)
		var xf := Transform3D(Basis(), -origin) * rel
		if not groups.has(key):
			groups[key] = {}
		var g: Dictionary = groups[key]
		var used := false
		for si in range(mi.mesh.get_surface_count()):
			if mi.mesh is ArrayMesh and (mi.mesh as ArrayMesh).surface_get_primitive_type(si) != Mesh.PRIMITIVE_TRIANGLES:
				continue
			var mat: Material = mi.material_override
			if mat == null:
				mat = mi.get_surface_override_material(si)
			if mat == null:
				mat = mi.mesh.surface_get_material(si)
			var mk: int = mat.get_instance_id() if mat != null else 0
			if not g.has(mk):
				var st := SurfaceTool.new()
				st.begin(Mesh.PRIMITIVE_TRIANGLES)
				g[mk] = [st, mat]
			var e: Array = g[mk]
			(e[0] as SurfaceTool).append_from(mi.mesh, si, xf)
			used = true
		if used:
			folded += 1
			mi.mesh = null
	# build the merged instances
	for key in groups:
		var g: Dictionary = groups[key]
		if g.is_empty():
			continue
		var am := ArrayMesh.new()
		for mk in g:
			var e: Array = g[mk]
			var st: SurfaceTool = e[0]
			st.commit(am)
			if e[1] != null:
				am.surface_set_material(am.get_surface_count() - 1, e[1])
		if am.get_surface_count() == 0:
			continue
		var nmi := MeshInstance3D.new()
		nmi.name = "Merged_%d_%d_%d" % [key.x, key.y, key.z]
		nmi.mesh = am
		nmi.position = _origin(key, chunk)
		nmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(nmi)
	# drop the now-empty source nodes (children first)
	for i in range(mis.size() - 1, -1, -1):
		var mi := mis[i]
		if mi.mesh == null and mi.get_child_count() == 0 and mi.get_script() == null:
			mi.get_parent().remove_child(mi)
			mi.free()
	if prune:
		_prune(root)
	return folded


static func _origin(key: Vector3i, chunk: float) -> Vector3:
	if chunk <= 0.0:
		return Vector3.ZERO
	return (Vector3(key) + Vector3(0.5, 0.5, 0.5)) * chunk


static func _collect(n: Node, out: Array[MeshInstance3D]) -> void:
	for c in n.get_children():
		if c is MeshInstance3D:
			out.append(c)
		_collect(c, out)


static func _rel_xf(n: Node3D, root: Node3D) -> Transform3D:
	var xf := n.transform
	var p := n.get_parent()
	while p != null and p != root:
		if p is Node3D:
			xf = (p as Node3D).transform * xf
		p = p.get_parent()
	return xf


static func _prune(n: Node) -> void:
	## Removes empty plain Node3D leaves left behind by the merge (bottom-up).
	for c in n.get_children():
		_prune(c)
	for c in n.get_children():
		if c.get_class() == "Node3D" and c.get_child_count() == 0 and c.get_script() == null:
			n.remove_child(c)
			c.free()
