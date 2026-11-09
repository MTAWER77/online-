extends Resource
## scripts/inventory/item_data.gd
## تعريف نوع عنصر (خشب، حجر...). كل نوع ملف .tres في resources/items.
## لو مفيش icon بنرسم مربع ملوّن بأول حرف من الاسم (لحد ما نعمل أيقونات).

@export var id: StringName = &""
@export var display_name: String = "Item"
@export_multiline var description: String = ""
@export var icon: Texture2D
@export var color: Color = Color(0.7, 0.7, 0.7)
@export var max_stack: int = 20
