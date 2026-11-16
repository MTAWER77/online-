extends "res://scripts/vehicles/shopping_cart.gd"
## Visual chaos + موديلات مخصصة. بيضيف إحساس Drift في اللفات.

const CART_FILES: Array = ["res://assets/models/shopping_cart.glb", "res://assets/models/model.glb"]
const CARTON_FILES: Array = ["res://assets/models/egg_carton.glb"]
const MELON_FILES: Array = ["res://assets/models/watermelon.glb", "res://assets/models/watermelon_lowpoly_free.glb"]

@export var cart_yaw_degrees: float = 180.0
@export var basket_floor_y: float = 0.52

@export_group("Chaos (Visual Only)")
@export var pull_strength: float = 0.15
@export var shimmy_strength: float = 0.2
@export var skid_strength: float = 0.3
@export var chaos_gain: float = 0.25
@export var drift_yaw_vis: float = 0.35


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


func _process(delta: float) -> void:
	super(delta)

	if _crash_left > 0.0 or _crash_vis > 0.02:
		return

	var speed_frac: float = clampf(absf(_speed) / max_speed, 0.0, 1.0)
	var gate: float = smoothstep(0.0, 0.15, speed_frac)
	
	var lean_target = _steer_smooth * max_lean * speed_frac
	var air_tilt = clampf(velocity.y * 0.02, -0.2, 0.2)
	
	_vis_lean = lerpf(_vis_lean, lean_target, 1.0 - exp(-12.0 * delta))
	
	if gate > 0.0 and _grounded:
		var t: float = Time.get_ticks_msec() / 1000.0
		var pull: float = (0.7 * sin(t * 0.45) + 0.5 * sin(t * 1.13)) * pull_strength
		var shimmy: float = sin(t * 14.0) * speed_frac * shimmy_strength
		var skid: float = sin(t * 6.0) * _brake_smooth * skid_strength

		var chaos_z: float = (pull * speed_frac + shimmy + skid) * gate * chaos_gain
		var chaos_x: float = cos(t * 12.0) * speed_frac * shimmy_strength * 0.5 * gate * chaos_gain

		_visual.rotation.z += chaos_z
		_visual.rotation.x += chaos_x
		
		# Drift visual: yaw offset when sliding sideways
		var drift_yaw = _drift_amount * drift_yaw_vis * signf(_steer_smooth)
		_visual.rotation.y = lerpf(_visual.rotation.y, drift_yaw, 8.0 * delta)
	else:
		_visual.rotation.z = lerpf(_visual.rotation.z, 0.0, 5.0 * delta)
		_visual.rotation.x = lerpf(_visual.rotation.x, -air_tilt, 5.0 * delta)
		_visual.rotation.y = lerpf(_visual.rotation.y, 0.0, 8.0 * delta)


func _build_visual() -> void:
	_model = Node3D.new()
	_model.name = "Model"
	_visual.add_child(_model)

	var cart_scene: PackedScene = _try_load(cart_model_path)
	if cart_scene != null:
		var holder: Node3D = Node3D.new()
		_model.add_child(holder)
		var fitted: Node3D = cart_scene.instantiate() as Node3D
		holder.add_child(fitted)
		var size: Vector3 = _fit_into(fitted, 1.05, true, true)
		var auto_yaw: float = 90.0 if size.x > size.z * 1.15 else 0.0
		holder.rotation_degrees.y = model_yaw_degrees + auto_yaw
	else:
		super()
		return

	_build_items()


func _build_items() -> void:
	var carton: PackedScene = _try_load(_first_existing(CARTON_FILES, ""))
	if carton == null:
		super()
		return

	var root: Node3D = Node3D.new()
	root.name = "Items"
	_model.add_child(root)
	_make_item(root, Vector3(0.0, basket_floor_y + 0.11, 0.12), carton, 0.28, null, Vector3.ONE, null, 200.0, 10.0, 0.0035, 0.03)

	var melon: PackedScene = _try_load(watermelon_model_path)
	var melon_mesh: SphereMesh = null
	var melon_mat: ShaderMaterial = null
	if melon == null:
		melon_mesh = SphereMesh.new()
		melon_mesh.radius = 0.18
		melon_mesh.height = 0.36
		melon_mat = _melon_material()

	for sx in [-0.135, 0.135]:
		_make_item(root, Vector3(float(sx), basket_floor_y + 0.13, -0.28), melon, 0.34, melon_mesh, Vector3(0.75, 0.7, 1.0), melon_mat, 140.0, 12.0, 0.002, 0.02)


func _melon_material() -> ShaderMaterial:
	var sh: Shader = Shader.new()
	sh.code = "shader_type spatial;\nvoid fragment() {\n\tfloat s = step(0.5, fract(UV.x * 10.0));\n\tALBEDO = mix(vec3(0.06, 0.32, 0.10), vec3(0.18, 0.60, 0.22), s);\n\tROUGHNESS = 0.45;\n}\n"
	var m: ShaderMaterial = ShaderMaterial.new()
	m.shader = sh
	return m
