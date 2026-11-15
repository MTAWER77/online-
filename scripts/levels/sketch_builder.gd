extends Node3D
## scripts/levels/sketch_builder.gd
## ماب "الرسمة" (Prototype): بتتبني بالكود من بلوكات بيضا بس.
## العربية بتبدأ ماشية ناحية -Z. كل الأرقام موجودة في دوال _build_* تحت، غيّر فيها براحتك.
## الحركة (بلاتفورمات/عوارض) بتتحسب من NetClock، فبتبان بنفس المكان عند الـ host والـ client.
## البلاتفورمات المتحركة بتشيل العربية معاها (meta "vel" بتقراها العربية).

const CHECKPOINT_SCRIPT := preload("res://scripts/levels/checkpoint.gd")
const FINISH_SCRIPT := preload("res://scripts/levels/finish_line.gd")
const NetClock = preload("res://scripts/multiplayer/net_clock.gd")

const ROAD_Y: float = 9.8 # ارتفاع البلازا والطريق
const ROAD_W: float = 8.0 # عرض الطريق
const FADE_DELAY: float = 0.6 # البلاطة بتختفي بعد ما تتلمس بكام ثانية
const FADE_TIME: float = 3.0 # وبتفضل مختفية كام ثانية
const BOUNCE_POWER: float = 20.0 # قوة القفازة (سرعة طلوع)

var _mat: StandardMaterial3D
var _cp_count: int = 0
var _movers: Array = []
var _spinners: Array = []


func _ready() -> void:
	_mat = StandardMaterial3D.new()
	_mat.albedo_color = Color(0.96, 0.96, 0.96)
	_mat.roughness = 0.9
	_setup_environment()
	_build_start_island()
	_build_floating_platforms()
	_build_ramp_and_bounce()
	_build_moving_platforms()
	_build_fading_platforms()
	_build_bus_plaza()
	_build_road()
	_build_tube_and_finish()


# كل الحركة دالة في الوقت المشترك: نفس الشكل عند الاتنين
func _physics_process(delta: float) -> void:
	var t: float = NetClock.world_time()
	for m in _movers:
		var d: Dictionary = m
		var body := d["body"] as Node3D
		var prev: Vector3 = body.global_position
		body.position = (d["base"] as Vector3) + (d["axis"] as Vector3) * float(d["dist"]) \
			* sin(TAU * t / float(d["period"]))
		body.set_meta("vel", (body.global_position - prev) / delta)
	for s in _spinners:
		var d: Dictionary = s
		var body := d["body"] as Node3D
		body.rotation.y = fposmod(float(d["dir"]) * TAU * t / float(d["period"]), TAU)


# ---------------------------------------------------------------- الأقسام

# 1) جزيرة البداية (المخروط) + مطبّين صغيرين
func _build_start_island() -> void:
	_box(self, Vector3(0, -1, -15), Vector3(22, 2, 40))
	_deco(self, Vector3(0, -3, -15), Vector3(16, 2, 32))
	_deco(self, Vector3(0, -5, -15), Vector3(10, 2, 22))
	_deco(self, Vector3(0, -7, -15), Vector3(5, 2, 12))
	_box(self, Vector3(0, 0.3, -14), Vector3(6, 0.5, 8), Vector3(8, 0, 0))
	_box(self, Vector3(0, 0.3, -26), Vector3(6, 0.5, 8), Vector3(8, 0, 0))


# 2) ثلاث بلاطات صغيرة (— — —) بينهم فجوات 7 متر: لازم قفز
func _build_floating_platforms() -> void:
	_box(self, Vector3(0, -0.5, -45), Vector3(8, 1, 6))
	_box(self, Vector3(2, -0.5, -58), Vector3(8, 1, 6))
	_box(self, Vector3(-2, -0.5, -71), Vector3(8, 1, 6))


# 3) المنحدر المائل + جزيرة فيها قفازة بترمي العربية لجزيرة بعيدة
func _build_ramp_and_bounce() -> void:
	_box(self, Vector3(0, 1.41, -91.94), Vector3(10, 1, 22), Vector3(10, 0, 0))
	_box(self, Vector3(0, 3.3, -115.8), Vector3(20, 1, 26))
	_bounce_pad(self, Vector3(0, 3.8, -126), 3.0)
	_box(self, Vector3(0, 3.3, -168.8), Vector3(24, 1, 36))
	_checkpoint(self, Vector3(0, 3.8, -156), 20.0)


# 4) متحركة (x) ثم متحركة (y)
func _build_moving_platforms() -> void:
	var plat_x := _mover(self, Vector3(0, 3.3, -193.8), Vector3(9, 1, 8))
	_slide(plat_x, Vector3.RIGHT, 7.0, 6.0)
	_box(self, Vector3(0, 3.3, -212.8), Vector3(24, 1, 24))
	var plat_y := _mover(self, Vector3(0, 5.3, -231.8), Vector3(9, 1, 8))
	_slide(plat_y, Vector3.UP, 2.0, 7.0)
	_box(self, Vector3(0, 7.3, -250.8), Vector3(24, 1, 24))
	_checkpoint(self, Vector3(0, 7.8, -243), 20.0)


# 5) بلاطات بتختفي بعد ما تلمسها
func _build_fading_platforms() -> void:
	var xs: Array[float] = [0.0, 2.0, -2.0, 0.0]
	for i in 4:
		_fading_platform(Vector3(xs[i], 7.3, -270.3 - i * 11.0), Vector3(8, 1, 7))


# 6) البلازا (الباصات) - مرتفعة عن اللي قبلها بـ 2 متر
func _build_bus_plaza() -> void:
	_box(self, Vector3(0, 9.3, -330.8), Vector3(36, 1, 40))
	_checkpoint(self, Vector3(0, ROAD_Y, -316), 30.0)
	_box(self, Vector3(-7, 11.3, -326), Vector3(3.2, 3, 11), Vector3(0, 20, 0))
	_box(self, Vector3(7, 11.3, -340), Vector3(3.2, 3, 11), Vector3(0, -25, 0))


# 7) الطريق المتعرّج: مطبّات (اهتزاز العجلة) + أشواك + مكعبات متحركة
func _build_road() -> void:
	var s1 := _section(Vector3(0, ROAD_Y, -350.8), 0.0)
	_road_straight(s1, 50.0)
	_rumble(s1, -8.0, 8)
	_spikes(s1, Vector3(-2.2, 0, -32), Vector2(3.4, 6))
	_hazard_block(s1, -42.0)

	_road_arc(Vector3(25, ROAD_Y, -400.8), 25.0, 180.0, 270.0, 8)

	var s2 := _section(Vector3(25, ROAD_Y, -425.8), -PI / 2.0)
	_road_straight(s2, 50.0)
	_checkpoint(s2, Vector3(0, 0, -3))
	_spikes(s2, Vector3(2.2, 0, -14), Vector2(3.4, 6))
	_rumble(s2, -24.0, 8)
	_hazard_block(s2, -42.0)

	_road_arc(Vector3(75, ROAD_Y, -450.8), 25.0, 90.0, 0.0, 8)

	var s3 := _section(Vector3(100, ROAD_Y, -450.8), 0.0)
	_road_straight(s3, 44.0)
	_checkpoint(s3, Vector3(0, 0, -3))
	_hazard_block(s3, -12.0)
	_spikes(s3, Vector3(-2.2, 0, -25), Vector2(3.4, 6))
	_rumble(s3, -31.0, 6)


# 8) النفق الطويل (بولينج: عوارض بتلف) + خط النهاية
func _build_tube_and_finish() -> void:
	var t := _section(Vector3(100, ROAD_Y, -494.8), 0.0)
	_box(t, Vector3(0, -0.5, -36), Vector3(ROAD_W, 1, 72))
	_box(t, Vector3(-4.5, 1.2, -36), Vector3(1, 2.4, 72))
	_box(t, Vector3(4.5, 1.2, -36), Vector3(1, 2.4, 72))
	_checkpoint(t, Vector3(0, 0, -3))
	_sweeper(t, Vector3(0, 0.7, -20), 4.0, true)
	_checkpoint(t, Vector3(0, 0, -34))
	_sweeper(t, Vector3(0, 0.7, -50), 3.2, false)
	_box(self, Vector3(100, 9.3, -578.8), Vector3(24, 1, 24))
	_finish(self, Vector3(100, ROAD_Y, -580), 24.0)


# ---------------------------------------------------------------- الطريق

func _section(origin: Vector3, yaw: float) -> Node3D:
	var n := Node3D.new()
	n.position = origin
	n.rotation.y = yaw
	add_child(n)
	return n


func _road_straight(sec: Node3D, length: float) -> void:
	_box(sec, Vector3(0, -0.5, -length * 0.5), Vector3(ROAD_W, 1, length))


func _road_arc(center: Vector3, radius: float, a0_deg: float, a1_deg: float, steps: int) -> void:
	var prev: Vector3 = center + Vector3(cos(deg_to_rad(a0_deg)), 0.0, sin(deg_to_rad(a0_deg))) * radius
	for i in range(1, steps + 1):
		var a: float = lerpf(a0_deg, a1_deg, float(i) / float(steps))
		var p: Vector3 = center + Vector3(cos(deg_to_rad(a)), 0.0, sin(deg_to_rad(a))) * radius
		var d: Vector3 = p - prev
		var mid: Vector3 = (prev + p) * 0.5
		var yaw: float = atan2(-d.x, -d.z)
		_box(self, mid + Vector3(0, -0.5, 0), Vector3(ROAD_W, 1, d.length() + 0.8), Vector3(0, rad_to_deg(yaw), 0))
		prev = p


# مطبّات واطية (7 سم) عشان عجل العربية يعدّيها وتهتز، مش تقف قدامها
func _rumble(sec: Node3D, z_from: float, count: int) -> void:
	for k in count:
		_box(sec, Vector3(0, 0.035, z_from - k * 1.6), Vector3(ROAD_W - 0.4, 0.07, 0.7))


func _hazard_block(sec: Node3D, z: float) -> void:
	var b := _mover(sec, Vector3(0, 1.3, z), Vector3(2.6, 2.6, 2.6))
	_slide(b, Vector3.RIGHT, 2.4, 3.0)


func _sweeper(parent: Node3D, pos: Vector3, period: float, clockwise: bool) -> void:
	var s := _mover(parent, pos, Vector3(0.9, 1.4, 0.9))
	_add_box_parts(s, Vector3(7.2, 0.9, 0.6))
	_spin(s, period, clockwise)


# ---------------------------------------------------------------- عناصر لعب

func _spikes(parent: Node3D, pos: Vector3, size: Vector2) -> void:
	var nx: int = maxi(1, int(size.x))
	var nz: int = maxi(1, int(size.y))
	for ix in nx:
		for iz in nz:
			var p := pos + Vector3(
				-size.x * 0.5 + (ix + 0.5) * size.x / nx,
				0.45,
				-size.y * 0.5 + (iz + 0.5) * size.y / nz)
			_deco(parent, p, Vector3(0.35, 0.9, 0.35))
	var area := Area3D.new()
	area.position = pos + Vector3(0, 0.5, 0)
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(size.x, 1.0, size.y)
	cs.shape = shape
	area.add_child(cs)
	parent.add_child(area)
	area.body_entered.connect(_hurt)


# الـ host بس هو اللي بيقرر الرجوع لآخر checkpoint (أوفلاين = إنت الـ host)
func _hurt(body: Node3D) -> void:
	if not body.is_in_group("unicycle"):
		return
	if bool(body.get("_authoritative")):
		body.call_deferred("_respawn")


func _bounce_pad(parent: Node3D, pos: Vector3, radius: float) -> void:
	var mesh := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = radius
	cm.bottom_radius = radius
	cm.height = 0.15
	cm.material = _mat
	mesh.mesh = cm
	mesh.position = pos + Vector3(0, 0.075, 0)
	parent.add_child(mesh)
	var area := Area3D.new()
	area.position = pos + Vector3(0, 0.6, 0)
	var cs := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = radius
	shape.height = 1.2
	cs.shape = shape
	area.add_child(cs)
	parent.add_child(area)
	area.body_entered.connect(_on_bounce)


# الـ host بس هو اللي بيطلّع العربية (الـ client بيشوفها من الـ snapshots)
func _on_bounce(body: Node3D) -> void:
	var rb := body as RigidBody3D
	if rb == null or not rb.is_in_group("unicycle"):
		return
	if not bool(rb.get("_authoritative")):
		return
	rb.set("_no_ground_timer", 0.3) # عشان كنترول العربية ما يمسحش الطلوع
	var v: Vector3 = rb.linear_velocity
	v.y = BOUNCE_POWER
	rb.linear_velocity = v


func _fading_platform(pos: Vector3, size: Vector3) -> void:
	var body := _box(self, pos, size)
	var trig := Area3D.new()
	trig.position = pos + Vector3(0, size.y * 0.5 + 0.5, 0)
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(size.x, 1.0, size.z)
	cs.shape = shape
	trig.add_child(cs)
	add_child(trig)
	var state := {"busy": false}
	trig.body_entered.connect(func(b: Node3D) -> void:
		if state["busy"] or not b.is_in_group("unicycle"):
			return
		state["busy"] = true
		await get_tree().create_timer(FADE_DELAY).timeout
		_set_solid(body, false)
		await get_tree().create_timer(FADE_TIME).timeout
		_set_solid(body, true)
		state["busy"] = false)


func _set_solid(body: StaticBody3D, solid: bool) -> void:
	body.visible = solid
	var col := body.get_node("Col") as CollisionShape3D
	col.set_deferred("disabled", not solid)


func _checkpoint(parent: Node3D, pos: Vector3, width: float = 8.0) -> void:
	_cp_count += 1
	var cp := Area3D.new()
	cp.name = "CP%d" % _cp_count
	cp.position = pos
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(width, 4.0, 1.5)
	cs.shape = shape
	cs.position = Vector3(0, 2, 0)
	cp.add_child(cs)
	var banner := _deco(cp, Vector3(0, 3.6, 0), Vector3(width, 0.5, 0.5))
	banner.name = "Banner" # checkpoint.gd بيدوّر عليه بالاسم ده
	_deco(cp, Vector3(-width * 0.5, 1.8, 0), Vector3(0.5, 3.6, 0.5))
	_deco(cp, Vector3(width * 0.5, 1.8, 0), Vector3(0.5, 3.6, 0.5))
	cp.set_script(CHECKPOINT_SCRIPT)
	parent.add_child(cp)


func _finish(parent: Node3D, pos: Vector3, width: float = 8.0) -> void:
	var f := Area3D.new()
	f.name = "FinishLine"
	f.position = pos
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(width, 4.0, 1.5)
	cs.shape = shape
	cs.position = Vector3(0, 2, 0)
	f.add_child(cs)
	_deco(f, Vector3(0, 4.2, 0), Vector3(width, 0.8, 0.8))
	_deco(f, Vector3(-width * 0.5, 2.1, 0), Vector3(0.8, 4.2, 0.8))
	_deco(f, Vector3(width * 0.5, 2.1, 0), Vector3(0.8, 4.2, 0.8))
	f.set_script(FINISH_SCRIPT)
	parent.add_child(f)


# ---------------------------------------------------------------- حركة (تتحسب في _physics_process من NetClock)

func _slide(body: Node3D, axis: Vector3, dist: float, period: float) -> void:
	_movers.append({"body": body, "base": body.position, "axis": axis, "dist": dist, "period": period})


func _spin(body: Node3D, period: float, clockwise: bool) -> void:
	_spinners.append({"body": body, "dir": -1.0 if clockwise else 1.0, "period": period})


# ---------------------------------------------------------------- بلوكات

# بلوك أبيض صلب (فيه تصادم)
func _box(parent: Node, pos: Vector3, size: Vector3, rot_deg: Vector3 = Vector3.ZERO) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = pos
	body.rotation_degrees = rot_deg
	_add_box_parts(body, size)
	parent.add_child(body)
	return body


# بلوك أبيض للشكل بس (من غير تصادم)
func _deco(parent: Node, pos: Vector3, size: Vector3) -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	bm.material = _mat
	mesh.mesh = bm
	mesh.position = pos
	parent.add_child(mesh)
	return mesh


# بلوك أبيض بيتحرك بالكود (بيزق العربية ويشيلها)
func _mover(parent: Node, pos: Vector3, size: Vector3) -> AnimatableBody3D:
	var body := AnimatableBody3D.new()
	body.position = pos
	body.sync_to_physics = true
	_add_box_parts(body, size)
	parent.add_child(body)
	return body


func _add_box_parts(body: Node3D, size: Vector3) -> void:
	var mesh := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	bm.material = _mat
	mesh.mesh = bm
	body.add_child(mesh)
	var cs := CollisionShape3D.new()
	cs.name = "Col"
	var shape := BoxShape3D.new()
	shape.size = size
	cs.shape = shape
	body.add_child(cs)


func _setup_environment() -> void:
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.32, 0.58, 0.92)
	sky_mat.sky_horizon_color = Color(0.74, 0.87, 1.0)
	sky_mat.ground_horizon_color = Color(0.74, 0.87, 1.0)
	sky_mat.ground_bottom_color = Color(0.6, 0.78, 0.95)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
