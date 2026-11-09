extends "res://scripts/systems/interactable.gd"
## scripts/inventory/world_item.gd
## عنصر على الأرض يتلقط بـ E. اللاعب بيطلب، والـ host يقرر (عشان اتنين ما يلقطوش نفس العنصر)،
## والعنصر بيختفي عند الاتنين، واللي لقطه بس بيدخل عنده في المخزن.

const ItemData = preload("res://scripts/inventory/item_data.gd")
const InventoryScript = preload("res://scripts/inventory/inventory.gd")

@export var item: ItemData
@export var amount: int = 1
@export var spin_speed: float = 1.2

@onready var _mesh: MeshInstance3D = $MeshInstance3D

var taken: bool = false


func _ready() -> void:
	super()
	if item == null:
		push_error("WorldItem %s: مفيش item متحدد" % name)
		return
	var material := StandardMaterial3D.new()
	material.albedo_color = item.color
	_mesh.material_override = material
	# الـ host بس هو اللي يأمر بالاختفاء وبإعطاء العنصر
	GDSync.expose_func(_apply_taken, ENUMS.EXPOSE_PERMISSION.HOST)
	GDSync.expose_func(_receive_grant, ENUMS.EXPOSE_PERMISSION.HOST)


func _process(delta: float) -> void:
	if not taken:
		_mesh.rotate_y(spin_speed * delta)


func get_prompt(_client_id: int) -> String:
	var suffix: String = " x%d" % amount if amount > 1 else ""
	return "E: Pick up %s%s" % [item.display_name, suffix]


func can_interact(client_id: int) -> bool:
	if taken or item == null:
		return false
	# لو أنا اللي بسأل، أتأكد إن عندي مكان في المخزن
	if client_id == local_client_id():
		var inventory: Node = InventoryScript.get_local(get_tree())
		return inventory != null and inventory.can_add(item, amount)
	return true


# التنفيذ عند الـ host
func _on_host_interact(client_id: int) -> void:
	if GDSync.is_active():
		GDSync.call_func_all(_apply_taken)
	else:
		_apply_taken()
	if client_id == local_client_id():
		_receive_grant()
	else:
		GDSync.call_func_on(client_id, _receive_grant)


# بتتنفذ عند الكل
func _apply_taken() -> void:
	taken = true
	visible = false
	set_deferred("monitorable", false)


# بتتنفذ عند اللي لقط العنصر بس
func _receive_grant() -> void:
	var inventory: Node = InventoryScript.get_local(get_tree())
	if inventory == null:
		return
	var leftover: int = inventory.add_item(item, amount)
	if leftover > 0:
		push_warning("WorldItem: المخزن امتلأ واتفقد %d من %s" % [leftover, item.display_name])
