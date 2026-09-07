class_name HideCrate
extends Area3D
## A large wooden crate (Kenney Survival Kit, CC0) you can climb into.
## Hiding: camera drops to slit height, movement is locked, the creature
## outside loses you. Press E (or the touch button) again to climb out.

signal entered
signal exited

var mesh_root: Node3D = null
var occupied := false
var _player: Player = null
var _saved_pos := Vector3.ZERO
var _slit_light: OmniLight3D = null


func _ready() -> void:
	collision_layer = 4
	collision_mask = 0
	monitoring = false
	monitorable = true
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(2.2, 2.0, 2.4)
	cs.shape = bs
	cs.position = Vector3(0, 1.0, 0)
	add_child(cs)

	var ps: PackedScene = load("res://models/crate.glb")
	if ps != null:
		mesh_root = ps.instantiate() as Node3D
		# the Kenney box is 0.24 x 0.31 x 0.5 m -> scale to a man-sized crate
		mesh_root.scale = Vector3(6.2, 4.6, 3.4)
		mesh_root.rotation.y = PI / 2.0     # long side across the corridor
		add_child(mesh_root)
		_darken(mesh_root)
	else:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(1.7, 1.4, 1.5)
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(0.35, 0.26, 0.16)
		bm.material = m
		mi.mesh = bm
		mi.position.y = 0.7
		add_child(mi)

	# solid walls so you cannot walk through it while it's closed; the player
	# is teleported inside on use, so a plain box is enough
	var body := StaticBody3D.new()
	body.collision_layer = 8
	body.collision_mask = 0
	var bcs := CollisionShape3D.new()
	var bb := BoxShape3D.new()
	bb.size = Vector3(1.75, 1.45, 1.55)
	bcs.shape = bb
	bcs.position = Vector3(0, 0.72, 0)
	body.add_child(bcs)
	add_child(body)

	# stencil + a thin strip of light through the slats
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.9, 0.85, 0.7)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.9, 0.7)
	mat.emission_energy_multiplier = 0.25
	var tag := MeshInstance3D.new()
	var tm := BoxMesh.new()
	tm.size = Vector3(0.55, 0.16, 0.02)
	tm.material = mat
	tag.mesh = tm
	tag.position = Vector3(0, 0.95, 0.79)
	add_child(tag)


func _darken(n: Node) -> void:
	if n is MeshInstance3D:
		var mi: MeshInstance3D = n
		for i in range(mi.mesh.get_surface_count()):
			var m := mi.mesh.surface_get_material(i)
			if m is StandardMaterial3D:
				var sm: StandardMaterial3D = (m as StandardMaterial3D).duplicate()
				sm.albedo_color = sm.albedo_color * Color(0.55, 0.5, 0.45)
				sm.roughness = 0.95
				mi.set_surface_override_material(i, sm)
	for c in n.get_children():
		_darken(c)


func prompt_text() -> String:
	if occupied:
		return "ВЫЛЕЗТИ ИЗ ЯЩИКА"
	if _taken_by_partner():
		return "ЯЩИК — ТАМ НАПАРНИК"
	return "ЯЩИК — СПРЯТАТЬСЯ"


func _taken_by_partner() -> bool:
	## v10 co-op: another operator is already crouched inside.
	for r in get_tree().get_nodes_in_group("remote_player"):
		if r.hidden and r.alive and r.global_position.distance_to(global_position) < 1.6:
			return true
	return false


func interact(p: Node) -> void:
	if occupied:
		leave()
	elif _taken_by_partner():
		AudioBank.play("deny", 0.7)
	else:
		enter(p as Player)


func enter(p: Player) -> void:
	if p == null or occupied:
		return
	occupied = true
	_player = p
	_saved_pos = p.global_position
	AudioBank.play("crate", 0.9, randf_range(0.95, 1.05), "SFX")
	p.hidden = true
	p.velocity = Vector3.ZERO
	p.collision_mask = 1             # ignore props so we can sit inside the box body
	p.global_position = global_position + Vector3(0, 0.05, 0)
	p.yaw = rotation.y + PI           # look out over the front rim
	p.hide_yaw = p.yaw
	p.pitch = 0.1
	p.set_flashlight(false)
	entered.emit()


func leave() -> void:
	if not occupied or _player == null:
		return
	occupied = false
	AudioBank.play("crate", 0.7, randf_range(1.05, 1.15), "SFX")
	var out := global_position + transform.basis.z * 1.6
	_player.global_position = Vector3(out.x, global_position.y + 0.1, out.z)
	_player.collision_mask = 1 | 8 | 16
	_player.hidden = false
	_player = null
	exited.emit()
