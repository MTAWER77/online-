extends BaseNetInput

var steer: float = 0.0
var gas: float = 0.0
var jump_pressed: bool = false

func _gather() -> void:
	steer = Input.get_axis("move_right", "move_left")
	gas = Input.get_action_strength("move_forward")
	jump_pressed = Input.is_action_just_pressed("jump")
