extends Area3D
## scripts/levels/finish_line.gd
## خط النهاية: لمّا الدراجة تلمسه بنبلّغ المرحلة (level_01.gd).


func _ready() -> void:
	body_entered.connect(_on_body_entered)


func _on_body_entered(body: Node3D) -> void:
	if body.is_in_group("unicycle"):
		get_tree().call_group("level", "on_finish_touched")
