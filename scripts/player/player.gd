class_name Player
extends CharacterBody3D
## First-person controller with bodycam-friendly motion: head bob, handheld
## sway, lean, crouch stealth, stamina, sanity, flashlight + NVG batteries.

signal stamina_changed(v: float)
signal sanity_changed(v: float)
signal battery_changed(flash: float, cam: float)
signal nvg_toggled(on: bool)
signal noise_made(at: Vector3, radius: float)
signal interact_prompt(text: String)
var _prompt_text := ""          # last prompt sent to the HUD (dedup)
signal died

const EYE_STAND := 1.62
const EYE_CROUCH := 0.92

@export var walk_speed := 2.9
@export var sprint_speed := 5.4
@export var crouch_speed := 1.45
@export var accel := 11.0
@export var friction := 13.0

var neck: Node3D
var camera: Camera3D
var flashlight: SpotLight3D

# state
var yaw := 0.0
var pitch := 0.0
var roll := 0.0
var lean := 0.0
var stamina := 100.0
var sanity := 100.0
var flash_battery := 100.0
var cam_battery := 100.0
var flashlight_on := false
var nvg_on := false
var crouching := false
var sprinting := false
var alive := true
var fear := 0.0                     # 0..1, driven externally by proximity/sanity
var noise_radius := 0.0

# head bob
var bob_t := 0.0
var bob_amp := 0.0
var _step_phase := 0.0
var _breath_timer := 0.0
var _breath_in := true
var _heart_timer := 0.0
var _interact_target: Node = null
var _sway := Vector2.ZERO
var _sway_target := Vector2.ZERO
var debug_move := Vector2.ZERO   # headless bot input override
var mobile_mode := false           # touch controls drive this body
var hidden := false                # inside a hide spot (crate): locked in place
var hide_yaw := 0.0
var touch_move := Vector2.ZERO
var touch_sprint := false
var touch_crouch := false
var touch_lean := 0.0
var touch_interact_held := false
var on_metal_stairs := false        # set by scripted levels: footsteps ring on steel   # mobile "interact" button kept pressed (dig / hold actions)
var debug_sprint := false
var shake := 0.0                    # external camera shake amplitude (v9: earthquake), 0 = off
var stamina_drain_mul := 1.0        # v9: adrenaline on the run level
var _shake_t := 0.0
var look_enabled := true         # main switches this off in menus / on death
# ---- multiplayer (v10) -------------------------------------------------------
var remote := false                 # avatar of another operator: driven by the network, no input
var peer_id := 1                    # owner peer (1 = host)
var nick := ""
var body: Node3D = null             # visible body (remote avatars only)
var name_tag: Label3D = null
var _rig_root: Node3D = null         # imported operator.glb (remote avatars)
var _anim: AnimationPlayer = null
var _anim_name := ""
var _anim_v := 0.0                   # smoothed ground speed for the gait
const BODY_SCALE := 0.79
var _net_pos := Vector3.ZERO
var _net_vel := Vector3.ZERO
var _net_yaw := 0.0
var _net_pitch := 0.0
var _net_age := 0.0
var _net_flags := 0
var _has_net := false
var _led_t := 0.0


func _ready() -> void:
	if not remote:
		add_to_group("player")
		collision_layer = 1
		collision_mask = 1 | 8 | 16      # world + props + clutter
	else:
		# other operators are ghosts to physics: nobody gets wedged in a doorway
		add_to_group("remote_player")
		collision_layer = 0
		collision_mask = 0
	var col := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.34
	cap.height = 1.75
	col.shape = cap
	col.position = Vector3(0, 0.88, 0)
	add_child(col)

	neck = Node3D.new()
	neck.name = "Neck"
	neck.position = Vector3(0, EYE_STAND, 0)
	add_child(neck)

	camera = Camera3D.new()
	camera.name = "Camera3D"
	camera.fov = GameSettings.fov
	camera.near = 0.05
	camera.far = 120.0
	camera.current = not remote
	camera.h_offset = 0.0
	neck.add_child(camera)

	# faint fill light so dark zones read as geometry, not void
	var fill := OmniLight3D.new()
	fill.name = "FillLight"
	fill.light_color = Color(1.0, 0.86, 0.66)
	fill.light_energy = 0.35
	fill.omni_range = 7.5
	fill.omni_attenuation = 1.4
	fill.shadow_enabled = false
	fill.position = Vector3(0, 0.1, 0)
	neck.add_child(fill)

	flashlight = SpotLight3D.new()
	flashlight.name = "Flashlight"
	flashlight.light_color = Color(1.0, 0.96, 0.86)
	flashlight.light_energy = 0.0
	flashlight.spot_range = 18.0
	flashlight.spot_angle = 42.0
	flashlight.spot_attenuation = 1.1
	flashlight.shadow_enabled = true
	flashlight.shadow_bias = 0.03
	flashlight.shadow_normal_bias = 0.12
	var attr := CameraAttributesPractical.new()
	attr.auto_exposure_enabled = true
	attr.auto_exposure_min_sensitivity = 40.0
	attr.auto_exposure_max_sensitivity = 210.0
	attr.auto_exposure_speed = 2.5
	camera.attributes = attr
	flashlight.position = Vector3(0.12, -0.1, 0.05)
	camera.add_child(flashlight)

	stamina_changed.emit(stamina)
	sanity_changed.emit(sanity)
	if remote:
		flashlight.shadow_enabled = false
		fill.light_energy = 0.18
		look_enabled = false
		_build_body()


# ---------------------------------------------------------------- remote avatar
func _build_body() -> void:
	## A second operator: KayKit "Rogue Hooded" (CC0) in a dark hooded jacket,
	## bodycam on the chest with a red REC LED, a name tag that only reads up
	## close. Falls back to a box silhouette if the GLB is missing.
	body = Node3D.new()
	body.name = "Body"
	add_child(body)
	var ps: PackedScene = load("res://models/operator.glb")
	if ps != null:
		_rig_root = ps.instantiate() as Node3D
		_rig_root.name = "Rig"
		# glTF faces +Z, our operators face -Z; ~2.25 units tall -> 1.78 m
		_rig_root.rotation.y = PI
		_rig_root.scale = Vector3.ONE * BODY_SCALE
		body.add_child(_rig_root)
		_darken_rig(_rig_root)
		_anim = _rig_root.find_child("AnimationPlayer", true, false) as AnimationPlayer
		if _anim != null:
			for an in ["Idle", "Walking_A", "Running_A"]:
				var a: Animation = _anim.get_animation(an)
				if a != null:
					a.loop_mode = Animation.LOOP_LINEAR
			var d: Animation = _anim.get_animation("Death_A")
			if d != null:
				d.loop_mode = Animation.LOOP_NONE
			_anim.playback_default_blend_time = 0.18
			_anim.play("Idle")
	else:
		_build_box_body()
	var mat_cam := StandardMaterial3D.new()
	mat_cam.albedo_texture = load("res://textures/metal.png")
	mat_cam.albedo_color = Color(0.35, 0.36, 0.38)
	mat_cam.metallic = 0.6
	mat_cam.roughness = 0.4
	var camb := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.07, 0.09, 0.05)
	bm.material = mat_cam
	camb.mesh = bm
	camb.name = "Cam"
	camb.position = Vector3(0.09, 1.3, -0.15)
	body.add_child(camb)
	var led := MeshInstance3D.new()
	var lm2 := SphereMesh.new()
	lm2.radius = 0.012
	lm2.height = 0.024
	var mat_led := StandardMaterial3D.new()
	mat_led.emission_enabled = true
	mat_led.emission = Color(1.0, 0.15, 0.1)
	mat_led.emission_energy_multiplier = 4.0
	mat_led.albedo_color = Color(0.3, 0.02, 0.02)
	lm2.material = mat_led
	led.mesh = lm2
	led.name = "Led"
	led.position = Vector3(0.09, 1.33, -0.18)
	body.add_child(led)
	if _rig_root != null:
		# the rogue's chest sits further forward than the old box torso
		# chibi proportions: the chest is at ~0.85 m
		camb.position = Vector3(0.1, 0.86, -0.3)
		led.position = Vector3(0.1, 0.89, -0.33)
	name_tag = Label3D.new()
	name_tag.text = nick
	name_tag.font = load("res://assets/fonts/osd_mono_bold.ttf")
	name_tag.font_size = 40
	name_tag.pixel_size = 0.0022
	name_tag.modulate = Color(0.93, 0.78, 0.36, 0.85)
	name_tag.outline_modulate = Color(0, 0, 0, 0.8)
	name_tag.outline_size = 8
	name_tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	name_tag.no_depth_test = false
	name_tag.visibility_range_end = 16.0
	name_tag.position = Vector3(0, EYE_STAND + 0.42, 0)
	body.add_child(name_tag)


func _darken_rig(n: Node) -> void:
	## Keep the author's palette but pull it into the gloom: darker, rougher.
	if n is MeshInstance3D:
		var mi: MeshInstance3D = n
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		for i in range(mi.get_surface_override_material_count()):
			var m: Material = mi.mesh.surface_get_material(i)
			if m is StandardMaterial3D:
				var sm: StandardMaterial3D = (m as StandardMaterial3D).duplicate()
				sm.albedo_color = sm.albedo_color * Color(0.4, 0.36, 0.36)   # pull the green into grime
				sm.roughness = 0.9
				sm.metallic = 0.0
				mi.set_surface_override_material(i, sm)
	for c in n.get_children():
		_darken_rig(c)


func _build_box_body() -> void:
	## Fallback silhouette (the pre-v11 avatar) when operator.glb is missing.
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.09, 0.10, 0.12)
	mat.roughness = 0.92
	var mat_skin := StandardMaterial3D.new()
	mat_skin.albedo_color = Color(0.55, 0.42, 0.34)
	mat_skin.roughness = 0.8
	var torso := MeshInstance3D.new()
	var cm := BoxMesh.new()
	cm.size = Vector3(0.42, 0.62, 0.24)
	cm.material = mat
	torso.mesh = cm
	torso.position = Vector3(0, 1.12, 0)
	torso.name = "Torso"
	body.add_child(torso)
	var hips := MeshInstance3D.new()
	var hm0 := BoxMesh.new()
	hm0.size = Vector3(0.36, 0.22, 0.22)
	hm0.material = mat
	hips.mesh = hm0
	hips.position = Vector3(0, 0.74, 0)
	body.add_child(hips)
	for sx in [-0.1, 0.1]:
		var leg := MeshInstance3D.new()
		var lm := CapsuleMesh.new()
		lm.radius = 0.085
		lm.height = 0.78
		lm.material = mat
		leg.mesh = lm
		leg.position = Vector3(sx, 0.38, 0)
		body.add_child(leg)
	for sx in [-0.27, 0.27]:
		var arm := MeshInstance3D.new()
		var am := CapsuleMesh.new()
		am.radius = 0.06
		am.height = 0.6
		am.material = mat
		arm.mesh = am
		arm.position = Vector3(sx, 1.1, 0)
		arm.rotation.z = 0.12 * signf(-sx)
		body.add_child(arm)
	var head := MeshInstance3D.new()
	var hm := SphereMesh.new()
	hm.radius = 0.12
	hm.height = 0.24
	hm.material = mat_skin
	head.mesh = hm
	head.name = "Head"
	head.position = Vector3(0, EYE_STAND + 0.02, 0)
	body.add_child(head)
	var cap := MeshInstance3D.new()
	var capm := CylinderMesh.new()
	capm.top_radius = 0.125
	capm.bottom_radius = 0.135
	capm.height = 0.1
	capm.material = mat
	cap.mesh = capm
	cap.position = Vector3(0, EYE_STAND + 0.1, 0)
	body.add_child(cap)


func set_body_visible(on: bool) -> void:
	if body != null:
		body.visible = on


func net_apply(pos: Vector3, yaw_v: float, pitch_v: float, flags: int, vel: Vector3) -> void:
	## Called by main for every state packet of this remote operator.
	if not _has_net:
		_has_net = true
		global_position = pos
		yaw = yaw_v
	_net_pos = pos
	_net_vel = vel
	_net_yaw = yaw_v
	_net_pitch = pitch_v
	_net_age = 0.0
	var was_flash := flashlight_on
	_net_flags = flags
	var fl := (flags & 8) != 0
	if fl != was_flash and flash_battery > 0.0:
		flashlight_on = fl
		flashlight.light_energy = 1.7 if fl else 0.0
		AudioBank.play_3d("click", global_position + Vector3(0, 1.4, 0), 0.4, 1.0, "SFX")
	var hid := (flags & 32) != 0
	if hid != hidden:
		hidden = hid
		if body != null:
			body.visible = not hid


func net_flags() -> int:
	var f := 0
	if alive:
		f |= 1
	if crouching:
		f |= 2
	if sprinting:
		f |= 4
	if flashlight_on:
		f |= 8
	if nvg_on:
		f |= 16
	if hidden:
		f |= 32
	return f


func remote_die() -> void:
	## Their tape stopped: the body drops, the torch goes dark.
	if not alive:
		return
	alive = false
	flashlight_on = false
	flashlight.light_energy = 0.0
	velocity = Vector3.ZERO
	if body != null:
		body.visible = true
		if _anim != null and _anim.has_animation("Death_A"):
			body.scale = Vector3.ONE
			_anim.play("Death_A", 0.1)
			_anim_name = "Death_A"
		else:
			body.rotation.x = -PI / 2.0
			body.position = Vector3(0, 0.18, 0.3)
	if name_tag != null:
		name_tag.modulate = Color(0.8, 0.12, 0.1, 0.8)
		name_tag.text = nick + "  ■ STOP"
	set_process(false)


func _tick_remote(delta: float) -> void:
	if not _has_net:
		return
	_net_age += delta
	var want := _net_pos + _net_vel * minf(_net_age, 0.25)
	var k := clampf(delta * 14.0, 0.0, 1.0)
	if global_position.distance_to(want) > 4.0:
		global_position = want
	else:
		global_position = global_position.lerp(want, k)
	yaw = lerp_angle(yaw, _net_yaw, k)
	pitch = lerpf(pitch, _net_pitch, k)
	hide_yaw = yaw
	velocity = _net_vel
	crouching = (_net_flags & 2) != 0
	sprinting = (_net_flags & 4) != 0
	nvg_on = (_net_flags & 16) != 0
	var moving := Vector2(_net_vel.x, _net_vel.z).length() if _net_age < 0.4 else 0.0
	_update_head(delta, moving)
	# the body follows the crouch and turns with the operator
	if body != null:
		var h := neck.position.y / EYE_STAND
		if _rig_root != null:
			# a rigged body squashes badly: crouch is a softer duck
			h = lerpf(1.0, h, 0.6)
			body.scale = Vector3(1.0 + (1.0 - h) * 0.25, h, 1.0 + (1.0 - h) * 0.25)
			_tick_anim(moving)
		else:
			body.scale = Vector3(1.0, h, 1.0)
		_led_t += delta
		var led: Node3D = body.get_node_or_null("Led")
		if led != null:
			led.visible = fmod(_led_t, 1.0) < 0.75


func _tick_anim(moving: float) -> void:
	if _anim == null or not alive:
		return
	# quick to pick up, slow to drop: a late packet must not flash "Idle"
	var dt := get_process_delta_time()
	if moving > _anim_v:
		_anim_v = move_toward(_anim_v, moving, dt * 20.0)
	else:
		_anim_v = move_toward(_anim_v, moving, dt * 4.0)
	moving = _anim_v
	var want := "Idle"
	if hidden:
		want = "Idle"
	elif moving > sprint_speed * 0.75:
		want = "Running_A"
	elif moving > 0.25:
		want = "Walking_A"
	if want != _anim_name:
		_anim_name = want
		_anim.play(want, 0.18)
		if OS.get_environment("BR_DEBUG") == "1":
			print("DBG avatar ", nick, " anim ", want, " v=%.1f" % moving)
	# stride keeps pace with the actual ground speed
	if want == "Walking_A":
		_anim.speed_scale = clampf(moving / 1.9, 0.5, 1.8)
	elif want == "Running_A":
		_anim.speed_scale = clampf(moving / 5.0, 0.7, 1.4)
	else:
		_anim.speed_scale = 1.0


func apply_touch_look(d: Vector2) -> void:
	if not alive or not look_enabled:
		return
	var sens := GameSettings.touch_sensitivity
	yaw -= d.x * sens
	pitch -= d.y * sens * (-1.0 if GameSettings.invert_y else 1.0)
	pitch = clampf(pitch, -1.45, 1.45)


func _set_prompt(t: String) -> void:
	if t == _prompt_text:
		return
	_prompt_text = t
	interact_prompt.emit(t)


func interact_held() -> bool:
	## True while the interact key / touch button is being held down.
	return Input.is_action_pressed("interact") or touch_interact_held


func interact_target() -> Node:
	return _interact_target if (_interact_target != null and is_instance_valid(_interact_target)) else null


func try_interact() -> void:
	## Touch button / external callers. Mirrors the keyboard path below,
	## including dropping the "[E] ..." prompt once the target is gone.
	if _interact_target == null or not is_instance_valid(_interact_target):
		_interact_target = null
		_set_prompt("")
		return
	if _interact_target.has_method("interact"):
		_interact_target.interact(self)
		if not is_instance_valid(_interact_target) or _interact_target.is_queued_for_deletion():
			_interact_target = null
			_set_prompt("")


func _input(event: InputEvent) -> void:
	# _input() runs BEFORE the GUI layer, so no Control can swallow the mouse
	if mobile_mode:
		return
	if not alive or not look_enabled:
		return
	if event is InputEventMouseMotion:
		var sens := GameSettings.mouse_sensitivity
		yaw -= event.relative.x * sens
		pitch -= event.relative.y * sens * (-1.0 if GameSettings.invert_y else 1.0)
		pitch = clampf(pitch, -1.45, 1.45)
		_sway_target += event.relative * 0.00045
		_sway_target.x = clampf(_sway_target.x, -0.02, 0.02)
		_sway_target.y = clampf(_sway_target.y, -0.02, 0.02)
	elif event is InputEventMouseButton and event.pressed and not _mouse_captured():
		# fallback: any click re-grabs the cursor if the OS refused capture
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _mouse_captured() -> bool:
	return Input.mouse_mode == Input.MOUSE_MODE_CAPTURED


func _physics_process(delta: float) -> void:
	if remote:
		if alive:
			_tick_remote(delta)
		return
	if not alive:
		velocity = Vector3.ZERO
		return

	# ---- toggles -------------------------------------------------------------
	if Input.is_action_just_pressed("flashlight") and not hidden and look_enabled:
		set_flashlight(not flashlight_on)
	if Input.is_action_just_pressed("night_vision") and look_enabled:
		set_nvg(not nvg_on)
	if hidden:
		# crouched in the crate: no walking, no steps, peek through the slats
		velocity = Vector3.ZERO
		crouching = true
		sprinting = false
		stamina = minf(stamina + 13.0 * delta, 100.0)
		cam_battery = minf(cam_battery + delta * 0.35, 100.0) if not nvg_on else maxf(cam_battery - delta * (100.0 / 240.0), 0.0)
		_update_head(delta, 0.0)
		_update_batteries_signal()
		_update_breathing(delta)
		_update_interaction()
		return

	# ---- movement input ------------------------------------------------------
	var dir := debug_move if debug_move.length() > 0.01 else (
			touch_move if mobile_mode else
			Input.get_vector("move_left", "move_right", "move_forward", "move_back"))
	if not look_enabled and debug_move.length() < 0.01:
		dir = Vector2.ZERO        # a menu is open (multiplayer keeps the world running)
	crouching = Input.is_action_pressed("crouch") or touch_crouch
	# forward in get_vector(...move_forward, move_back) is NEGATIVE y
	var moving_forward := dir.y < -0.1
	sprinting = (Input.is_action_pressed("sprint") or debug_sprint or touch_sprint) and not crouching and moving_forward and stamina > 1.0
	var slow := Input.is_action_pressed("walk_slow")

	var target_speed := walk_speed
	if sprinting:
		target_speed = sprint_speed
	elif crouching:
		target_speed = crouch_speed
	if slow:
		target_speed *= 0.55

	var wish := (transform.basis * Vector3(dir.x, 0, dir.y)).normalized()
	var target_vel := wish * target_speed
	var acc := accel if dir.length() > 0.1 else friction
	velocity.x = move_toward(velocity.x, target_vel.x, acc * delta * (1.0 if dir.length() > 0.1 else 1.4))
	velocity.z = move_toward(velocity.z, target_vel.z, acc * delta * (1.0 if dir.length() > 0.1 else 1.4))
	if not is_on_floor():
		velocity.y -= 18.0 * delta
	else:
		velocity.y = minf(velocity.y, 0.0)
	move_and_slide()
	# step-up assist: hop low ledges (raised floor sections on custom maps)
	if is_on_floor() and get_slide_collision_count() > 0 and dir.length() > 0.1:
		var low := false
		for i in range(get_slide_collision_count()):
			var c := get_slide_collision(i)
			var n := c.get_normal()
			if absf(n.y) < 0.5 and c.get_position().y < global_position.y + 0.55 and c.get_position().y > global_position.y + 0.05:
				low = true
		if low:
			velocity.y = 3.2
	if OS.get_environment("BR_DEBUG") == "1" and (Time.get_ticks_msec() < 6000 or OS.get_environment("BR_PTRACE") == "1"):
		var info := ""
		for i in range(get_slide_collision_count()):
			var c := get_slide_collision(i)
			info += " | hit " + str(c.get_collider().name) + " n=" + str(c.get_normal())
		print("PDBG pos=(%.2f,%.2f) vel=(%.2f,%.2f) slides=%d%s" % [global_position.x, global_position.z,
				velocity.x, velocity.z, get_slide_collision_count(), info])

	# ---- stamina -------------------------------------------------------------
	var moving := velocity.length()
	if sprinting:
		stamina = maxf(stamina - 15.0 * delta * stamina_drain_mul, 0.0)
	elif moving < 0.4:
		stamina = minf(stamina + 13.0 * delta, 100.0)
	else:
		stamina = minf(stamina + 6.0 * delta, 100.0)

	# ---- batteries -----------------------------------------------------------
	if flashlight_on:
		flash_battery = maxf(flash_battery - delta * (100.0 / 165.0), 0.0)
		if flash_battery <= 0.0:
			set_flashlight(false)
	if nvg_on:
		cam_battery = maxf(cam_battery - delta * (100.0 / 240.0), 0.0)
		if cam_battery <= 0.0:
			set_nvg(false)
	else:
		cam_battery = minf(cam_battery + delta * 0.35, 100.0)

	# ---- head / camera -------------------------------------------------------
	_update_head(delta, moving)
	_update_batteries_signal()
	_update_breathing(delta)
	_update_interaction()


func _update_head(delta: float, moving: float) -> void:
	# lean
	var lean_target := 0.0
	if remote:
		pass
	elif Input.is_action_pressed("lean_left"):
		lean_target = -1.0
	elif Input.is_action_pressed("lean_right"):
		lean_target = 1.0
	elif touch_lean != 0.0:
		lean_target = touch_lean
	lean = move_toward(lean, lean_target, delta * 6.0)

	# eye height
	var eye_target := EYE_CROUCH if crouching else EYE_STAND
	if hidden:
		eye_target = 1.50   # eyes just over the crate rim
		yaw = hide_yaw + clampf(angle_difference(hide_yaw, yaw), -0.85, 0.85)
		pitch = clampf(pitch, -0.55, 0.30)
	neck.position.y = move_toward(neck.position.y, eye_target, delta * 6.5)

	# head bob
	var speed01 := clampf(moving / sprint_speed, 0.0, 1.0)
	var amp_target := speed01 * (0.052 if not crouching else 0.03) * GameSettings.head_bob_strength
	if not GameSettings.head_bob_enabled:
		amp_target = 0.0
	bob_amp = move_toward(bob_amp, amp_target, delta * 0.35)
	bob_t += moving * delta * (2.35 if sprinting else 2.0)

	var bob_y := sin(bob_t * 2.0) * bob_amp
	var bob_x := cos(bob_t) * bob_amp * 0.6
	var roll_target := -cos(bob_t) * bob_amp * 1.6 + lean * 0.06 + _sway.x * 1.4

	# footsteps on bob cycle
	var phase := bob_t / PI
	if phase - _step_phase >= 1.0 and moving > 0.6:
		_step_phase = phase
		_footstep(moving)

	# handheld micro-sway (bodycam feel)
	_sway = _sway.lerp(_sway_target, delta * 6.0)
	_sway_target = _sway_target.lerp(Vector2.ZERO, delta * 3.0)
	var t := Time.get_ticks_msec() / 1000.0
	var drift_x := sin(t * 0.9) * 0.0035 + sin(t * 2.3) * 0.0016
	var drift_y := cos(t * 0.7) * 0.003 + sin(t * 1.7) * 0.0014

	rotation.y = yaw                      # body turns => WASD is view-relative
	neck.rotation = Vector3.ZERO
	# v9: earthquake shake -- additive only, a no-op while `shake` is 0
	var qk := Vector3.ZERO
	var qp := Vector3.ZERO
	if shake > 0.001:
		_shake_t += delta
		var st := _shake_t
		qk = Vector3(sin(st * 31.0) * 0.6 + sin(st * 47.0) * 0.4,
				cos(st * 27.0) * 0.5 + sin(st * 53.0) * 0.3,
				sin(st * 23.0) * 0.5 + cos(st * 39.0) * 0.3) * shake * 0.035
		qp = Vector3(sin(st * 41.0), cos(st * 37.0) * 0.7, 0.0) * shake * 0.03
	camera.rotation = Vector3(pitch + _sway.y + drift_y + bob_y * 0.35 + qk.x,
			_sway.x + drift_x + qk.y, roll_target + qk.z)
	camera.position = Vector3(bob_x + lean * 0.16 + qp.x, bob_y + qp.y, 0.0)

	# fov kick while sprinting
	var fov_target := GameSettings.fov + (6.0 if sprinting else 0.0) - (4.0 if crouching else 0.0)
	camera.fov = move_toward(camera.fov, fov_target, delta * 30.0)


func _footstep(moving: float) -> void:
	var vol := 1.0
	var prefix := "step_walk"
	if sprinting:
		prefix = "step_run"
		vol = 1.15
		noise_radius = GameSettings.monster_hear_radius() * 1.15
	elif crouching:
		prefix = "step_crouch"
		vol = 0.55
		noise_radius = 3.0
	else:
		noise_radius = GameSettings.monster_hear_radius() * 0.62
	if on_metal_stairs:
		prefix = "stairs"
		vol *= 1.1
	AudioBank.play_variant_3d(prefix, global_position + Vector3(0, -1.4, 0), vol * 0.9,
			randf_range(0.94, 1.06), "SFX")
	noise_made.emit(global_position, noise_radius)


func _update_batteries_signal() -> void:
	battery_changed.emit(flash_battery, cam_battery)


func set_flashlight(on: bool) -> void:
	if on and flash_battery <= 0.0:
		AudioBank.play("deny", 0.7)
		return
	flashlight_on = on
	flashlight.light_energy = 1.7 if on else 0.0
	AudioBank.play("click", 0.55, randf_range(0.9, 1.1), "UI")


func set_nvg(on: bool) -> void:
	if on and cam_battery <= 1.0:
		AudioBank.play("deny", 0.7)
		return
	nvg_on = on
	nvg_toggled.emit(on)
	AudioBank.play("click", 0.6, randf_range(0.85, 1.0), "UI")


func _update_breathing(delta: float) -> void:
	var exhausted := stamina < 32.0
	var scared := fear > 0.35
	if not (exhausted or scared):
		return
	_breath_timer -= delta
	if _breath_timer <= 0.0:
		var rate := lerpf(2.6, 0.85, clampf(maxf((32.0 - stamina) / 32.0, fear), 0.0, 1.0))
		_breath_timer = rate
		var bname := "breath_in" if _breath_in else "breath_out"
		_breath_in = not _breath_in
		var vol := lerpf(0.25, 0.75, fear)
		AudioBank.play(bname, vol, randf_range(0.92, 1.08), "SFX")

	# heartbeat
	if fear > 0.45:
		_heart_timer -= delta
		if _heart_timer <= 0.0:
			_heart_timer = lerpf(1.15, 0.42, (fear - 0.45) / 0.55)
			AudioBank.play("heartbeat", lerpf(0.4, 1.0, fear), randf_range(0.95, 1.05), "SFX")


func _update_interaction() -> void:
	# NB: a freed Object compares equal to null in GDScript, so test validity
	# first -- otherwise a picked-up item leaves its prompt on screen forever
	if not is_instance_valid(_interact_target):
		_interact_target = null
		_set_prompt("")
	var from := camera.global_position
	var fwd := -camera.global_transform.basis.z
	var to := from + fwd * 2.6
	var space := get_world_3d().direct_space_state
	var target: Node = null
	# 1) precise ray (areas only: door / pickups live on layer 3)
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = 4
	q.collide_with_areas = true
	q.collide_with_bodies = false
	q.exclude = [get_rid()]
	var hit := space.intersect_ray(q)
	if hit and hit.collider is Area3D:
		target = hit.collider
	# 2) forgiving fallback: anything interactable within a short cone in front
	if target == null:
		var sq := PhysicsShapeQueryParameters3D.new()
		var sph := SphereShape3D.new()
		sph.radius = 0.9
		sq.shape = sph
		sq.transform = Transform3D(Basis(), from + fwd * 1.3)
		sq.collision_mask = 4
		sq.collide_with_areas = true
		sq.collide_with_bodies = false
		var best := 1e9
		for r in space.intersect_shape(sq, 8):
			var col: Object = r.collider
			if col is Area3D and col.has_method("interact"):
				var d: float = (col as Node3D).global_position.distance_to(from)
				if d < best:
					best = d
					target = col
	if target != _interact_target:
		_interact_target = target
		if target != null and target.has_method("prompt_text"):
			_set_prompt(target.prompt_text())
		else:
			_set_prompt("")
	if _interact_target != null and is_instance_valid(_interact_target) and look_enabled and Input.is_action_just_pressed("interact"):
		if _interact_target.has_method("interact"):
			_interact_target.interact(self)
			# the target usually frees itself: drop the prompt right away
			if not is_instance_valid(_interact_target) or _interact_target.is_queued_for_deletion():
				_interact_target = null
				_set_prompt("")


func add_sanity(v: float) -> void:
	sanity = clampf(sanity + v, 0.0, 100.0)
	sanity_changed.emit(sanity)


func drain_sanity(delta: float, mult: float) -> void:
	sanity = clampf(sanity - delta * GameSettings.sanity_drain() * mult, 0.0, 100.0)
	sanity_changed.emit(sanity)


func kill() -> void:
	if not alive:
		return
	alive = false
	velocity = Vector3.ZERO
	set_flashlight(false)
	set_nvg(false)
	died.emit()


func apply_graphics() -> void:
	var g := GameSettings
	camera.far = g.gfx_far()
	if flashlight != null:
		flashlight.shadow_enabled = g.gfx_flash_shadows()
		flashlight.shadow_blur = 1.0 if g.graphics >= 2 else 1.8


func refill_flash(amount: float) -> void:
	flash_battery = clampf(flash_battery + amount, 0.0, 100.0)


func refill_cam(amount: float) -> void:
	cam_battery = clampf(cam_battery + amount, 0.0, 100.0)
