extends Node
## scripts/inventory/inventory.gd
## مخزن اللاعب (بيانات بس). كل لاعب عنده مخزنه الخاص على جهازه.
## الشكل: items[i] = نوع العنصر (أو null)، counts[i] = العدد، في كل خانة.

signal changed

@export var slot_count: int = 20

var items: Array = []
var counts: Array[int] = []


func _ready() -> void:
	items.resize(slot_count)
	counts.resize(slot_count)
	counts.fill(0)


# مخزن اللاعب المحلي على الجهاز ده (أو null)
static func get_local(tree: SceneTree) -> Node:
	for raw in tree.get_nodes_in_group("players"):
		var player: Variant = raw
		if player.is_local:
			return player.get_node_or_null("Inventory")
	return null


# بيحط العنصر ويرجّع الكمية اللي ما لقتش لها مكان (0 يعني اتحط كله)
func add_item(item: Resource, amount: int) -> int:
	var left: int = amount
	# 1) كمّل الأكوام الموجودة من نفس النوع
	for i in slot_count:
		if left <= 0:
			break
		if _same(items[i], item) and counts[i] < item.max_stack:
			var add: int = mini(left, item.max_stack - counts[i])
			counts[i] += add
			left -= add
	# 2) الخانات الفاضية
	for i in slot_count:
		if left <= 0:
			break
		if items[i] == null:
			var add: int = mini(left, item.max_stack)
			items[i] = item
			counts[i] = add
			left -= add
	if left != amount:
		changed.emit()
	return left


func can_add(item: Resource, amount: int) -> bool:
	var space: int = 0
	for i in slot_count:
		if items[i] == null:
			space += item.max_stack
		elif _same(items[i], item):
			space += item.max_stack - counts[i]
	return space >= amount


# سحب وإفلات: لو نفس النوع يدمج، وإلا يبدّل الخانتين
func move_slot(from_index: int, to_index: int) -> void:
	if from_index == to_index or items[from_index] == null:
		return
	if _same(items[to_index], items[from_index]):
		var space: int = items[to_index].max_stack - counts[to_index]
		var moved: int = mini(space, counts[from_index])
		counts[to_index] += moved
		counts[from_index] -= moved
		if counts[from_index] <= 0:
			items[from_index] = null
			counts[from_index] = 0
	else:
		var item_tmp: Variant = items[to_index]
		var count_tmp: int = counts[to_index]
		items[to_index] = items[from_index]
		counts[to_index] = counts[from_index]
		items[from_index] = item_tmp
		counts[from_index] = count_tmp
	changed.emit()


func _same(a: Variant, b: Variant) -> bool:
	return a != null and b != null and a.id == b.id
