extends Area3D
## The earth pile in Level 3's stair nook. Hold E to dig (the director
## measures the hold time); this node only supplies the prompt.

var director: Node = null


func prompt_text() -> String:
	if director != null and is_instance_valid(director):
		return director.rubble_prompt()
	return "ЗАВАЛ"


func interact(_p: Node) -> void:
	# a tap does nothing by itself -- digging is a hold, handled by the director
	if director != null and is_instance_valid(director) and director.phase == director.Phase.DIG:
		AudioBank.play_variant_3d("dig", global_position + Vector3(0, 0.8, 0), 0.6, 1.0, "SFX")
