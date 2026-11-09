extends PanelContainer
## scripts/inventory/crafting_panel.gd
## تصنيع ذكي: مفيش شبكة تصنيع. الوصفات بتظهر لوحدها لما يبقى معاك جزء من موادها
## (الجاهزة فوق، والناقصة باهتة تحتها). اختار وصفة، شوف المواد المطلوبة، وصنّع بضغطة.
## كل ده محلي على جهاز اللاعب لأن المخزن خاص بيه.

const RecipeRowScene: PackedScene = preload("res://scenes/inventory/recipe_row.tscn")
const IngredientRowScene: PackedScene = preload("res://scenes/inventory/ingredient_row.tscn")
const InventoryScript = preload("res://scripts/inventory/inventory.gd")

const ALL_CATEGORIES: int = -1
const TAB_CATEGORIES: Array[int] = [-1, 0, 1, 2] # الكل، أدوات، أسلحة، بقاء (ترتيب RecipeData.Category)
const READY_COLOR: Color = Color(0.5, 0.88, 0.62)
const MISSING_COLOR: Color = Color(0.95, 0.5, 0.45)

@export var recipes: Array[Resource] = []

@onready var _tabs: Array[Button] = [%TabAll, %TabTools, %TabWeapons, %TabSurvival]
@onready var _list: VBoxContainer = %List
@onready var _empty_hint: Label = %EmptyHint
@onready var _preview: Control = %Preview
@onready var _preview_tile: Panel = %PreviewTile
@onready var _preview_letter: Label = %PreviewLetter
@onready var _preview_name: Label = %PreviewName
@onready var _preview_desc: Label = %PreviewDesc
@onready var _ingredients: VBoxContainer = %Ingredients
@onready var _craft_button: Button = %CraftButton
@onready var _toast: Label = %Toast

var _inventory: Node = null
var _category: int = ALL_CATEGORIES
var _selected: Resource = null
var _toast_tween: Tween


func _ready() -> void:
	for i in _tabs.size():
		_tabs[i].pressed.connect(_on_tab_pressed.bind(i))
	_craft_button.pressed.connect(_on_craft_pressed)
	_toast.modulate.a = 0.0
	_preview.visible = false


func bind(inventory: Node) -> void:
	_inventory = inventory


# بتتنادى كل ما المخزن يتغير أو الواجهة تتفتح
func refresh() -> void:
	if _inventory == null:
		return
	var entries: Array = _discover()
	_ensure_selection(entries)
	_rebuild_list(entries)
	_update_preview()


# الوصفات اللي تتعرض: معاك على الأقل مادة من موادها (أو جاهزة). الجاهزة الأول.
func _discover() -> Array:
	var entries: Array = []
	for recipe in recipes:
		var met: int = 0
		var has_any: bool = false
		for k in recipe.ingredient_items.size():
			var have: int = _inventory.count_of(recipe.ingredient_items[k])
			if have > 0:
				has_any = true
			if have >= recipe.ingredient_amounts[k]:
				met += 1
		var is_ready: bool = met == recipe.ingredient_items.size()
		if not (has_any or is_ready):
			continue
		if _category != ALL_CATEGORIES and recipe.category != _category:
			continue
		entries.append({"recipe": recipe, "ready": is_ready, "met": met})
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["ready"] != b["ready"]:
			return a["ready"]
		return a["recipe"].display_name < b["recipe"].display_name)
	return entries


func _ensure_selection(entries: Array) -> void:
	for entry in entries:
		if entry["recipe"] == _selected:
			return
	_selected = entries[0]["recipe"] if not entries.is_empty() else null


func _rebuild_list(entries: Array) -> void:
	for child in _list.get_children():
		_list.remove_child(child)
		child.queue_free()
	_empty_hint.visible = entries.is_empty()
	for entry in entries:
		var row: Variant = RecipeRowScene.instantiate()
		_list.add_child(row)
		row.setup(entry["recipe"], entry["ready"], entry["met"])
		row.set_selected(entry["recipe"] == _selected)
		row.chosen.connect(_on_recipe_chosen)


func _update_preview() -> void:
	_preview.visible = _selected != null
	if _selected == null:
		return
	var result: Resource = _selected.result
	var style := StyleBoxFlat.new()
	style.bg_color = result.color
	style.set_corner_radius_all(4)
	_preview_tile.add_theme_stylebox_override("panel", style)
	_preview_letter.text = result.display_name.substr(0, 1).to_upper()
	var suffix: String = "  x%d" % _selected.result_amount if _selected.result_amount > 1 else ""
	_preview_name.text = _selected.display_name + suffix
	_preview_desc.text = _selected.description

	for child in _ingredients.get_children():
		_ingredients.remove_child(child)
		child.queue_free()
	for k in _selected.ingredient_items.size():
		var row: Variant = IngredientRowScene.instantiate()
		_ingredients.add_child(row)
		var item: Resource = _selected.ingredient_items[k]
		row.setup(item, _inventory.count_of(item), _selected.ingredient_amounts[k])

	var status: int = _inventory.check_craft(_selected)
	_craft_button.disabled = status != InventoryScript.CraftResult.OK
	match status:
		InventoryScript.CraftResult.OK:
			_craft_button.text = "Craft"
		InventoryScript.CraftResult.MISSING:
			_craft_button.text = "Missing materials"
		_:
			_craft_button.text = "Backpack full"


# ---- التفاعل ----
func _on_tab_pressed(tab_index: int) -> void:
	_category = TAB_CATEGORIES[tab_index]
	for i in _tabs.size():
		_tabs[i].set_pressed_no_signal(i == tab_index)
	refresh()
	_fade(_list)


func _on_recipe_chosen(recipe: Resource) -> void:
	if recipe == _selected:
		return
	_selected = recipe
	refresh()
	_fade(_preview)


func _on_craft_pressed() -> void:
	if _selected == null or _inventory == null:
		return
	var recipe: Resource = _selected
	var status: int = _inventory.craft(recipe) # بتعمل changed، فالواجهة بتتحدث لوحدها
	if status == InventoryScript.CraftResult.OK:
		_show_toast("Crafted %s" % recipe.display_name, READY_COLOR)
		_flash_button()
		_pop(_preview_tile)
	elif status == InventoryScript.CraftResult.FULL:
		_show_toast("Backpack full", MISSING_COLOR)
	else:
		_show_toast("Missing materials", MISSING_COLOR)


# ---- حركات خفيفة ----
func _fade(node: Control) -> void:
	node.modulate.a = 0.25
	create_tween().tween_property(node, "modulate:a", 1.0, 0.14)


func _flash_button() -> void:
	_craft_button.modulate = Color(0.6, 1.0, 0.75)
	create_tween().tween_property(_craft_button, "modulate", Color.WHITE, 0.35)


func _pop(node: Control) -> void:
	node.pivot_offset = node.size * 0.5
	node.scale = Vector2(1.18, 1.18)
	create_tween().tween_property(node, "scale", Vector2.ONE, 0.2) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _show_toast(text: String, color: Color) -> void:
	if _toast_tween != null:
		_toast_tween.kill()
	_toast.text = text
	_toast.add_theme_color_override("font_color", color)
	_toast.modulate.a = 1.0
	_toast_tween = create_tween()
	_toast_tween.tween_interval(1.0)
	_toast_tween.tween_property(_toast, "modulate:a", 0.0, 0.4)
