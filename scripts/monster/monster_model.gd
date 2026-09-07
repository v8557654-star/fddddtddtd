class_name MonsterModel
extends Node3D
## Visual rig for the creature: loads models/monster.glb (community
## "Minecraft Monster" from github.com/v8557654-star/models), re-parents its
## limbs under proper pivots (hips / shoulders / neck) and drives a simple
## procedural walk / reach / head-track animation on top.

const MODEL_PATH := "res://models/monster.glb"
const MODEL_SCALE := 0.78          # raw model is 3.66 m tall -> ~2.85 m

var inst: Node3D = null
var root: Node3D = null             # rotated 180°: the GLB's face is -Z, the game treats +Z as "forward"
var hip_l: Node3D = null
var hip_r: Node3D = null
var sh_l: Node3D = null
var sh_r: Node3D = null
var upper: Node3D = null           # torso + head
var jaw: Node3D = null             # lower half of the head (bone6): opens / snaps
var neck: Node3D = null            # whole head (bone6+bone7) under the torso
var bite_t := -1.0                 # <0 idle; >=0 running the bite loop
var bite_open := 0.0
var _jaw_rest_y := 0.0
var _teeth: Array[MeshInstance3D] = []
var eye_light: OmniLight3D = null
var height := 2.85

var walk_phase := 0.0
var twitch := Vector3.ZERO
var _twitch_t := 0.0
var _rng := RandomNumberGenerator.new()
var _base_y := 0.0
var _mats: Array[StandardMaterial3D] = []


func _ready() -> void:
	_rng.randomize()
	var ps: PackedScene = load(MODEL_PATH)
	if ps == null:
		push_warning("MonsterModel: missing " + MODEL_PATH + ", using placeholder")
		_placeholder()
		return
	root = Node3D.new()
	root.name = "Root"
	root.rotation.y = PI
	add_child(root)
	inst = ps.instantiate() as Node3D
	inst.scale = Vector3(MODEL_SCALE, MODEL_SCALE, MODEL_SCALE)
	root.add_child(inst)
	_setup_pivots()
	_setup_materials()
	eye_light = OmniLight3D.new()
	eye_light.light_color = Color(1.0, 0.25, 0.15)
	eye_light.light_energy = 0.0
	eye_light.omni_range = 3.0
	eye_light.shadow_enabled = false
	eye_light.position = Vector3(0, height * 0.9, -0.3)
	root.add_child(eye_light)


func _placeholder() -> void:
	var mi := MeshInstance3D.new()
	var c := CapsuleMesh.new()
	c.radius = 0.4
	c.height = 2.8
	mi.mesh = c
	mi.position.y = 1.4
	add_child(mi)


func _find(prefix: String) -> Node3D:
	var stack: Array[Node] = [inst]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is Node3D and n.name.begins_with(prefix):
			return n
		for c in n.get_children():
			stack.append(c)
	return null


func _pivot_for(parts: Array, local_pos: Vector3, parent: Node3D = null) -> Node3D:
	## Creates a pivot at `local_pos` (in root space) and moves the given
	## nodes under it preserving their world transforms. With `parent` the
	## pivot is nested (shoulders under the torso) so it follows its motion.
	var pv := Node3D.new()
	var par := parent if parent != null else root
	par.add_child(pv)
	pv.global_position = root.to_global(local_pos)
	for p in parts:
		if p != null:
			p.reparent(pv, true)
	return pv


func _setup_pivots() -> void:
	var s := MODEL_SCALE
	var leg_r := _find("RiteLeg")
	var leg_l := _find("LeftLeg")
	var arm_l := _find("bone2_")
	var arm_r := _find("bone3_")
	var hand_l := _find("bone4_")
	var hand_r := _find("bone5_")
	var torso := _find("bone_1")
	var head_a := _find("bone6_")
	var head_b := _find("bone7_")
	if OS.get_environment("BR_DEBUG") == "1":
		print("DBG monster model parts: ", [leg_r, leg_l, arm_l, arm_r, hand_l, hand_r, torso, head_a, head_b].map(func(n): return n.name if n != null else "MISSING"))
	# joint positions measured from the mesh boxes (root space, metres/s)
	hip_r = _pivot_for([leg_r], Vector3(0.36 * s, 1.93 * s, 0))
	hip_l = _pivot_for([leg_l], Vector3(-0.24 * s, 1.93 * s, 0))
	upper = _pivot_for([torso], Vector3(0.05 * s, 1.95 * s, 0))
	# head: a neck pivot under the torso, and the lower face (bone6) on its
	# own hinge at the back of the skull so it can swing open like a jaw
	neck = _pivot_for([head_b], Vector3(0.08 * s, 2.92 * s, 0.0), upper)
	jaw = _pivot_for([head_a], Vector3(0.08 * s, 3.05 * s, 0.06 * s), neck)
	_jaw_rest_y = jaw.position.y
	# shoulders live on the torso so the arms turn / hunch with it
	sh_l = _pivot_for([arm_l, hand_l], Vector3(-0.35 * s, 2.87 * s, 0.10 * s), upper)
	sh_r = _pivot_for([arm_r, hand_r], Vector3(0.46 * s, 2.87 * s, 0.10 * s), upper)
	height = 3.66 * s
	_base_y = 0.0


func _setup_materials() -> void:
	var stack: Array[Node] = [inst]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			var mi: MeshInstance3D = n
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			for i in range(mi.get_surface_override_material_count()):
				var m := mi.mesh.surface_get_material(i)
				if m is StandardMaterial3D:
					var sm: StandardMaterial3D = m.duplicate()
					sm.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
					sm.roughness = 0.85
					sm.albedo_color = Color(0.72, 0.68, 0.66)   # a bit dimmer / dirtier
					mi.set_surface_override_material(i, sm)
					_mats.append(sm)
		for c in n.get_children():
			stack.append(c)


## gait 0..1.4 (speed / nominal), reach 0..1.25 (arms forward), look_dir =
## world-space point the head should turn to (or Vector3.INF), glow 0..1.
func animate(delta: float, gait: float, reach: float, look_at_point: Vector3, glow: float) -> void:
	if inst == null:
		return
	_twitch_t -= delta
	if _twitch_t <= 0.0:
		_twitch_t = _rng.randf_range(0.35, 1.4)
		twitch = Vector3(_rng.randf_range(-0.18, 0.18), _rng.randf_range(-0.25, 0.25), _rng.randf_range(-0.1, 0.1))
	twitch = twitch.lerp(Vector3.ZERO, delta * 6.0)

	var swing := sin(walk_phase) * 0.62 * gait
	if hip_l != null:
		hip_l.rotation.x = swing
		hip_r.rotation.x = -swing
	if sh_l != null:
		sh_l.rotation.x = -swing * 0.7 + reach + twitch.y * 0.3
		sh_r.rotation.x = swing * 0.7 + reach - twitch.y * 0.3
		sh_l.rotation.z = 0.08 + reach * 0.1
		sh_r.rotation.z = -0.08 - reach * 0.1
	if upper != null:
		upper.position.y = 1.95 * MODEL_SCALE + absf(sin(walk_phase)) * 0.05 * gait
		upper.rotation.z = sin(walk_phase * 0.5) * 0.05 * gait + twitch.z
		var hunch := lerpf(0.08, 0.28, clampf(gait, 0.0, 1.0)) + twitch.x * 0.3
		if look_at_point != Vector3.INF:
			var to_p := look_at_point - (global_position + Vector3(0, height * 0.85, 0))
			var yaw_to := atan2(to_p.x, to_p.z) - global_rotation.y
			yaw_to = clampf(wrapf(yaw_to, -PI, PI), -0.8, 0.8)
			upper.rotation.y = lerp_angle(upper.rotation.y, yaw_to, delta * 6.0)
			var pitch_to := clampf(-atan2(to_p.y, Vector2(to_p.x, to_p.z).length()), -0.5, 0.5)
			upper.rotation.x = lerp_angle(upper.rotation.x, -(hunch + pitch_to * 0.5), delta * 6.0)
		else:
			var t := Time.get_ticks_msec() / 1000.0
			upper.rotation.y = lerp_angle(upper.rotation.y, sin(t * 0.31) * 0.5, delta * 1.5)
			upper.rotation.x = lerp_angle(upper.rotation.x, -hunch, delta * 2.0)
	if eye_light != null:
		eye_light.light_energy = lerpf(0.0, 1.6, clampf(glow, 0.0, 1.0))
	position.y = _base_y


## Jumpscare bite loop: call every frame while the kill plays. The jaw
## snaps shut ~4x/s with a wide-open hold in between; head jerks around.
func bite(delta: float) -> void:
	if jaw == null:
		return
	if bite_t < 0.0:
		bite_t = 0.0
	bite_t += delta
	# open wide fast, hold, snap shut, repeat (period 0.42 s)
	var ph := fmod(bite_t, 0.42) / 0.42
	var open := 0.0
	if ph < 0.18:
		open = ph / 0.18
	elif ph < 0.62:
		open = 1.0 - 0.15 * sin(ph * 40.0)
	elif ph < 0.72:
		open = 1.0 - (ph - 0.62) / 0.10
	else:
		open = 0.0
	bite_open = open
	# hinge is at the back of the face: negative x-rotation drops the chin.
	# NB: the jaw pivot is a child of the neck -- its rest position is local
	# (captured in _setup_pivots), so only offset it, never set root-space y
	jaw.rotation.x = -open * 0.95
	jaw.position.y = _jaw_rest_y - open * 0.05
	# violent head jerks, faster as it goes
	var j := bite_t * 31.0
	if neck != null:
		neck.rotation.z = sin(j * 1.3) * 0.16 + sin(j * 3.7) * 0.05
		neck.rotation.y = sin(j * 0.9 + 1.0) * 0.14
		neck.rotation.x = -0.25 + sin(j * 2.1) * 0.08 + open * 0.12
	if upper != null:
		upper.rotation.x = -0.45 + sin(j * 0.7) * 0.05
		upper.rotation.z = sin(j * 1.1) * 0.04
	if sh_l != null:
		sh_l.rotation.x = 1.4 + sin(j * 0.8) * 0.15
		sh_r.rotation.x = 1.4 - sin(j * 0.8) * 0.15
		sh_l.rotation.z = 0.35
		sh_r.rotation.z = -0.35
	if eye_light != null:
		eye_light.light_energy = 5.0 + open * 3.0


func bite_reset() -> void:
	bite_t = -1.0
	bite_open = 0.0
	if jaw != null:
		jaw.rotation = Vector3.ZERO
		jaw.position.y = _jaw_rest_y
	if neck != null:
		neck.rotation = Vector3.ZERO


func set_tint(c: Color) -> void:
	for m in _mats:
		m.albedo_color = c


func set_transparency(a: float) -> void:
	for m in _mats:
		if a < 0.999:
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m.albedo_color.a = a
		else:
			m.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
			m.albedo_color.a = 1.0
