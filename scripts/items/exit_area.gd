extends Area3D
## The level door. On Level 0 it leads down to Level 1; on the last level it
## is the emergency exit that ends the run.


func _ready() -> void:
	setup()


func setup() -> void:
	collision_layer = 4
	collision_mask = 0
	monitoring = false
	monitorable = true


func _game() -> Node:
	return get_tree().get_first_node_in_group("game")


func prompt_text() -> String:
	var g := _game()
	if g == null:
		return ""
	var dp: String = g.director_door_prompt()
	if dp != "":
		return dp
	if g.door_locked():
		return "ЖЕЛЕЗНАЯ ДВЕРЬ — ЗАКЛИНИЛО"
	if g.is_last_level():
		return "АВАРИЙНЫЙ ВЫХОД — ОТКРЫТЬ"
	if g.level_id == 1:
		return "ЖЕЛЕЗНАЯ ДВЕРЬ — СПУСТИТЬСЯ НА УРОВЕНЬ 2"
	if g.level_id == 2:
		return "КРАСНАЯ ДВЕРЬ — ОТКРЫТЬ"
	return "ДВЕРЬ — СПУСТИТЬСЯ НА УРОВЕНЬ %d" % (g.level_id + 1)


func interact(_p: Node) -> void:
	var g := _game()
	if g == null:
		return
	if g.director_door_interact():
		return
	if g.door_locked():
		AudioBank.play("deny", 0.8, 0.8)
		AudioBank.play("pipe_knock_2", 0.7, 0.6, "SFX")
		g.hud.show_subtitle("Штурвал не проворачивается. Что-то держит дверь с той стороны.", 3.5)
		return
	AudioBank.play("door", 1.0)
	g.on_door_used()
