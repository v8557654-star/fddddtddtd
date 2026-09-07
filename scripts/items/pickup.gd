class_name Pickup
extends Area3D
## Collectible item: almond water / flashlight battery.

enum Type { WATER, BATTERY, KEY }

@export var type: int = Type.WATER

var mat_glow: StandardMaterial3D
var mat_body: StandardMaterial3D
var mat_label: StandardMaterial3D
var spin := 0.0
var bob := 0.0
var glow_light: OmniLight3D


func _ready() -> void:
	collision_layer = 4
	collision_mask = 0
	monitoring = false
	var cs := CollisionShape3D.new()
	var ss := SphereShape3D.new()
	ss.radius = 0.65
	cs.shape = ss
	add_child(cs)

	mat_glow = StandardMaterial3D.new()
	mat_glow.emission_enabled = true
	mat_glow.emission_energy_multiplier = 3.0
	mat_body = StandardMaterial3D.new()
	mat_body.albedo_texture = load("res://textures/metal.png")
	mat_body.roughness = 0.45
	mat_body.metallic = 0.6
	mat_label = StandardMaterial3D.new()
	mat_label.albedo_color = Color(0.85, 0.82, 0.7)
	mat_label.roughness = 0.8

	match type:
		Type.WATER:
			_build_water()
		Type.BATTERY:
			_build_battery()
		Type.KEY:
			_build_key()


func _build_water() -> void:
	mat_glow.emission = Color(0.7, 0.85, 1.0)
	mat_glow.emission_energy_multiplier = 0.7
	var body := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.06
	cm.bottom_radius = 0.07
	cm.height = 0.28
	cm.material = mat_label
	body.mesh = cm
	body.position.y = 0.22
	add_child(body)
	var cap := MeshInstance3D.new()
	var c2 := CylinderMesh.new()
	c2.top_radius = 0.028
	c2.bottom_radius = 0.028
	c2.height = 0.06
	c2.material = mat_glow
	cap.mesh = c2
	cap.position.y = 0.39
	add_child(cap)


func _build_battery() -> void:
	mat_glow.emission = Color(0.35, 1.0, 0.45)
	mat_glow.emission_energy_multiplier = 1.6
	var body := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.10, 0.22, 0.10)
	bm.material = mat_body
	body.mesh = bm
	body.position.y = 0.18
	add_child(body)
	var tip := MeshInstance3D.new()
	var tm := BoxMesh.new()
	tm.size = Vector3(0.05, 0.04, 0.05)
	tm.material = mat_glow
	tip.mesh = tm
	tip.position.y = 0.31
	add_child(tip)


func _build_key() -> void:
	mat_glow.emission = Color(1.0, 0.75, 0.3)
	mat_glow.emission_energy_multiplier = 1.2
	var mat_rust := StandardMaterial3D.new()
	mat_rust.albedo_texture = load("res://textures/metal.png")
	mat_rust.albedo_color = Color(0.55, 0.36, 0.2)
	mat_rust.roughness = 0.7
	mat_rust.metallic = 0.5
	# lies flat on the floor: bow (torus), shaft, two teeth (over-sized so it
	# reads from a few metres away in the dark)
	scale = Vector3(2.2, 2.2, 2.2)
	var bow := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.035
	tm.outer_radius = 0.06
	tm.material = mat_rust
	bow.mesh = tm
	bow.position = Vector3(-0.09, 0.02, 0)
	add_child(bow)
	var shaft := MeshInstance3D.new()
	var sm := CylinderMesh.new()
	sm.top_radius = 0.012
	sm.bottom_radius = 0.012
	sm.height = 0.2
	sm.material = mat_rust
	shaft.mesh = sm
	shaft.rotation.z = PI / 2.0
	shaft.position = Vector3(0.05, 0.02, 0)
	add_child(shaft)
	for i in range(2):
		var tooth := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.022, 0.012, 0.045)
		bm.material = mat_rust
		tooth.mesh = bm
		tooth.position = Vector3(0.10 + i * 0.035, 0.02, 0.028)
		add_child(tooth)
	# a faint warm glow so it can be found in the dark
	glow_light = OmniLight3D.new()
	glow_light.light_color = Color(1.0, 0.7, 0.3)
	glow_light.light_energy = 1.1
	glow_light.omni_range = 1.6
	glow_light.shadow_enabled = false
	glow_light.position = Vector3(0, 0.15, 0)
	add_child(glow_light)


func _process(delta: float) -> void:
	spin += delta * 0.8
	bob += delta
	rotation.y = spin
	position.y = 0.02 + sin(bob * 1.7) * 0.03
	if glow_light != null:
		glow_light.light_energy = (0.9 if type == Type.KEY else 1.4) + sin(bob * 6.0) * 0.4


func prompt_text() -> String:
	match type:
		Type.WATER:
			return "МИНДАЛЬНАЯ ВОДА — ВЗЯТЬ"
		Type.KEY:
			return "РЖАВЫЙ КЛЮЧ — ВЗЯТЬ"
		_:
			return "БАТАРЕЯ — ВЗЯТЬ"


func interact(_p: Node) -> void:
	# goes into the backpack; used later from the Tab inventory
	AudioBank.play("pickup", 0.8)
	var g := _game()
	var kind := "battery"
	if type == Type.WATER:
		kind = "water"
	elif type == Type.KEY:
		kind = "key"
	if g != null and g.has_method("pickup_taken"):
		# v10: goes through the game so every operator sees it vanish
		g.pickup_taken(self, kind)
		return
	if g != null and g.has_method("add_to_inventory"):
		g.add_to_inventory(kind)
	queue_free()


func _game() -> Node:
	return get_tree().get_first_node_in_group("game")
