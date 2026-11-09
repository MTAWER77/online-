extends Node
## scripts/inventory/inventory.gd
## مخزن اللاعب (بيانات بس). كل لاعب عنده مخزنه الخاص على جهازه.
## الشكل: items[i] = نوع العنصر (أو null)، counts[i] = العدد، في كل خانة.
## الخانات: 0..grid_slots-1 هي الشبكة، وبعدها خانات الـ hotbar (hotbar_index(i)).

signal changed

enum CraftResult { OK, MISSING, FULL }
signal hotbar_selection_changed(index: int) # 0..hotbar_slots-1

@export var grid_slots: int = 20
@export var hotbar_slots: int = 5

var slot_count: int = 0
var items: Array = []
var counts: Array[int] = []
var selected_hotbar: int = 0
var _fill_order: Array[int] = []


func _ready() -> void:
	slot_count = grid_slots + hotbar_slots
	items.resize(slot_count)
	counts.resize(slot_count)
	counts.fill(0)
	# العناصر الجديدة بتروح للـ hotbar الأول وبعدها الشبكة
	for i in hotbar_slots:
		_fill_order.append(hotbar_index(i))
	for i in grid_slots:
		_fill_order.append(i)


# رقم خانة الـ hotbar رقم i (0..4) جوه المخزن
func hotbar_index(i: int) -> int:
	return grid_slots + i


func select_hotbar(i: int) -> void:
	var wrapped: int = posmod(i, hotbar_slots)
	if wrapped == selected_hotbar:
		return
	selected_hotbar = wrapped
	hotbar_selection_changed.emit(selected_hotbar)


# العنصر في خانة الـ hotbar المختارة (أو null)
func get_selected_item() -> Resource:
	return items[hotbar_index(selected_hotbar)]


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
	for i in _fill_order:
		if left <= 0:
			break
		if _same(items[i], item) and counts[i] < item.max_stack:
			var add: int = mini(left, item.max_stack - counts[i])
			counts[i] += add
			left -= add
	# 2) الخانات الفاضية
	for i in _fill_order:
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


# ---- التصنيع (محلي: المخزن خاص باللاعب، فمفيش داعي للـ host) ----
# إجمالي عدد النوع ده في كل الخانات
func count_of(item: Resource) -> int:
	var total: int = 0
	for i in slot_count:
		if _same(items[i], item):
			total += counts[i]
	return total


# هل التصنيع ممكن؟ (OK، أو ناقص مواد، أو مفيش مكان للناتج بعد خصم المواد)
func check_craft(recipe: Resource) -> int:
	for k in recipe.ingredient_items.size():
		if count_of(recipe.ingredient_items[k]) < recipe.ingredient_amounts[k]:
			return CraftResult.MISSING
	var saved_items: Array = items.duplicate()
	var saved_counts: Array[int] = counts.duplicate()
	_consume(recipe)
	var fits: bool = can_add(recipe.result, recipe.result_amount)
	for i in slot_count:
		items[i] = saved_items[i]
		counts[i] = saved_counts[i]
	return CraftResult.OK if fits else CraftResult.FULL


# بيخصم المواد ويحط الناتج في المخزن (أو يرجّع سبب الفشل)
func craft(recipe: Resource) -> int:
	var status: int = check_craft(recipe)
	if status != CraftResult.OK:
		return status
	_consume(recipe)
	add_item(recipe.result, recipe.result_amount) # بتعمل changed
	return CraftResult.OK


func _consume(recipe: Resource) -> void:
	for k in recipe.ingredient_items.size():
		var item: Resource = recipe.ingredient_items[k]
		var left: int = recipe.ingredient_amounts[k]
		for i in slot_count:
			if left <= 0:
				break
			if _same(items[i], item):
				var taken: int = mini(counts[i], left)
				counts[i] -= taken
				left -= taken
				if counts[i] <= 0:
					items[i] = null
					counts[i] = 0
