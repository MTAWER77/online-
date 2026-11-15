@tool
extends Node3D
## scripts/vehicles/cart_editor_preview.gd
## بيعرض موديل العربية (والبيض والبطيخ) جوه محرر Godot بس، عشان تشوف الشكل وانت بتبرمج.
## الأنودز اللي بيعملها هنا مش بتتحفظ في المشهد، وفي اللعبة السكربت ده مبيعملش حاجة
## (العربية بتبني الموديل بنفسها وقت التشغيل).

const CART_FILES: Array = ["res://assets/models/shopping_cart.glb", "res://assets/models/model.glb"]
const CARTON_FILES: Array = ["res://assets/models/egg_carton.glb"]
const MELON_FILES: Array = ["res://assets/models/watermelon.glb", "res://assets/models/watermelon_lowpoly_free.glb"]
const PREVIEW_NAME: String = "EditorPreview"


func _ready() -> void:
	if not Engine.is_editor_hint() or has_node(PREVIEW_NAME):
		return
	var yaw: float = 180.0
	var floor_y: float = 0.52
	var parent: Node = get_parent()
	if parent != null:
		var y = parent.get("cart_yaw_degrees")
		if y != null:
			yaw = float(y)
		var f = parent.get("basket_floor_y")
		if f != null:
			floor_y = float(f)

	var root := Node3D.new()
	root.name = PREVIEW_NAME
	add_child(root) # من غير owner: بيظهر في الـ viewport ومش بيتحفظ

	var cart: PackedScene = _load_first(CART_FILES)
	if cart != null:
		var holder := Node3D.new()
		root.add_child(holder)
		var n := cart.instantiate() as Node3D
		holder.add_child(n)
		var size: Vector3 = _fit(n, 1.05, true, true)
		holder.rotation_degrees.y = yaw + (90.0 if size.x > size.z * 1.15 else 0.0)
	var carton: PackedScene = _load_first(CARTON_FILES)
	if carton != null:
		_place(root, carton, Vector3(0.0, floor_y + 0.11, 0.12), 0.28)
	var melon: PackedScene = _load_first(MELON_FILES)
	if melon != null:
		for sx in [-0.135, 0.135]:
			_place(root, melon, Vector3(float(sx), floor_y + 0.13, -0.28), 0.34)


func _load_first(paths: Array) -> PackedScene:
	for p in paths:
		if ResourceLoader.exists(p as String):
			return load(p as String) as PackedScene
	return null


func _place(parent: Node3D, scene: PackedScene, pos: Vector3, size: float) -> void:
	var holder := Node3D.new()
	holder.position = pos
	parent.add_child(holder)
	var n := scene.instantiate() as Node3D
	holder.add_child(n)
	_fit(n, size, false, false)


func _aabb_of(node: Node3D) -> AABB:
	var inv: Transform3D = node.global_transform.affine_inverse()
	var out := AABB()
	var first: bool = true
	for m in node.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		var a: AABB = (inv * mi.global_transform) * mi.get_aabb()
		if first:
			out = a
			first = false
		else:
			out = out.merge(a)
	return out


## نفس منطق الـ fit بتاع العربية وقت التشغيل (حجم + توسيط)
func _fit(node: Node3D, target: float, horizontal: bool, ground_align: bool) -> Vector3:
	var a: AABB = _aabb_of(node)
	if a.size.length() < 0.0001:
		return Vector3.ZERO
	var dim: float = maxf(a.size.x, a.size.z) if horizontal else maxf(a.size.x, maxf(a.size.y, a.size.z))
	var s: float = target / maxf(dim, 0.0001)
	var c: Vector3 = a.get_center()
	node.scale = Vector3.ONE * s
	var y: float = -a.position.y * s if ground_align else -c.y * s
	node.position = Vector3(-c.x * s, y, -c.z * s)
	return a.size
