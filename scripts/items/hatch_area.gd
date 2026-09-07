extends Area3D
## The hatch on the stair landing (Level 3's exit).

var director: Node = null


func setup() -> void:
	collision_layer = 4
	collision_mask = 0
	monitoring = false
	monitorable = true


func prompt_text() -> String:
	if director != null and is_instance_valid(director):
		return director.hatch_prompt()
	return "ЛЮК"


func interact(_p: Node) -> void:
	if director != null and is_instance_valid(director):
		director.on_hatch_interact()
