extends "res://scripts/vehicles/shopping_cart.gd"
## scripts/vehicles/shopping_cart_custom.gd
## بيركّب الموديلات الحقيقية على العربية من غير ما تغيّر أسماء ملفاتك (كلهم في assets/models/):
##   العربية    = shopping_cart.glb أو model.glb
##   علبة البيض = egg_carton.glb
##   البطيخ     = watermelon.glb أو watermelon_lowpoly_free.glb
## لو علبة البيض مش موجودة بيرجع للشكل المؤقت (صينية + بيض + بطيخ).

const CART_FILES: Array = ["res://assets/models/shopping_cart.glb", "res://assets/models/model.glb"]
const CARTON_FILES: Array = ["res://assets/models/egg_carton.glb"]
const MELON_FILES: Array = ["res://assets/models/watermelon.glb", "res://assets/models/watermelon_lowpoly_free.glb"]

@export var cart_yaw_degrees: float = 180.0 # الهاندل في موديلك ناحية -Z، فبنلفه 180 (لو طلعت بضهرها غيّرها لـ 0)
@export var basket_floor_y: float = 0.52 # ارتفاع أرضية السلة في الموديل


func _ready() -> void:
	cart_model_path = _first_existing(CART_FILES, cart_model_path)
	watermelon_model_path = _first_existing(MELON_FILES, watermelon_model_path)
	model_yaw_degrees = cart_yaw_degrees
	super()


func _first_existing(paths: Array, fallback: String) -> String:
	for p in paths:
		if ResourceLoader.exists(p as String):
			return p as String
	return fallback


func _build_items() -> void:
	var carton: PackedScene = _try_load(_first_existing(CARTON_FILES, ""))
	if carton == null:
		super()
		return
	var root := Node3D.new()
	root.name = "Items"
	_model.add_child(root)
	# علبة البيض: ورا جنب الهاندل
	_make_item(root, Vector3(0.0, basket_floor_y + 0.11, 0.12), carton, 0.28, null, Vector3.ONE, null,
		200.0, 10.0, 0.0035, 0.03)
	# بطيختين جنب بعض قدام (الموديل لو موجود، غير كده كورة مخططة)
	var melon: PackedScene = _try_load(watermelon_model_path)
	var melon_mesh: SphereMesh = null
	var melon_mat: ShaderMaterial = null
	if melon == null:
		melon_mesh = SphereMesh.new()
		melon_mesh.radius = 0.18
		melon_mesh.height = 0.36
		melon_mat = _melon_material()
	for sx in [-0.135, 0.135]:
		_make_item(root, Vector3(float(sx), basket_floor_y + 0.13, -0.28), melon, 0.34, melon_mesh,
			Vector3(0.75, 0.7, 1.0), melon_mat, 140.0, 12.0, 0.002, 0.02)
