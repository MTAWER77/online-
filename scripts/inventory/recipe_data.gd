extends Resource
## scripts/inventory/recipe_data.gd
## وصفة تصنيع: مواد مطلوبة (ingredient_items + ingredient_amounts بنفس الترتيب) وناتج.
## الوصفة بتظهر للاعب لوحدها لما يبقى معاه جزء من موادها.

enum Category { TOOLS, WEAPONS, SURVIVAL }

@export var display_name: String = "Recipe"
@export_multiline var description: String = ""
@export var category: Category = Category.TOOLS
@export var result: Resource
@export var result_amount: int = 1
@export var ingredient_items: Array[Resource] = []
@export var ingredient_amounts: PackedInt32Array = PackedInt32Array()
