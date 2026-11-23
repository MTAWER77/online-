class_name SnapshotBuffer
extends RefCounted
## مخزن لقطات عام مرتب زمنيًا (لاعب/عربية/أجسام لاحقًا). لا يعرف شيئًا عن الشبكة.
## كل لقطة = (time: float, state: Dictionary). الأنواع المدعومة للـ Interpolation:
## float, Vector2/3/4, Quaternion (slerp), Color. باقي الأنواع (int, bool, String...) تُؤخذ كما هي.
## مفاتيح الزوايا (راديان) تُسجَّل عبر set_angle_keys لتستخدم lerp_angle.

const DEFAULT_MAX_SNAPSHOTS: int = 64
const TIME_EPSILON: float = 0.000001

var _times: PackedFloat64Array = PackedFloat64Array()
var _states: Array[Dictionary] = []
var _max_snapshots: int = DEFAULT_MAX_SNAPSHOTS
var _angle_keys: Array[StringName] = []

func _init(max_snapshots: int = DEFAULT_MAX_SNAPSHOTS) -> void:
	_max_snapshots = maxi(2, max_snapshots)

func set_max_snapshots(value: int) -> void:
	_max_snapshots = maxi(2, value)
	_trim()

func set_angle_keys(keys: Array[StringName]) -> void:
	_angle_keys = keys.duplicate()

func size() -> int:
	return _times.size()

func is_empty() -> bool:
	return _times.is_empty()

func clear() -> void:
	_times.clear()
	_states.clear()

## NAN لو فاضي.
func get_oldest_time() -> float:
	return _times[0] if not _times.is_empty() else NAN

## NAN لو فاضي.
func get_latest_time() -> float:
	return _times[_times.size() - 1] if not _times.is_empty() else NAN

## يضيف لقطة بترتيب زمني صحيح حتى لو وصلت متأخرة.
## OK / ERR_INVALID_PARAMETER (وقت غير صالح) / ERR_ALREADY_EXISTS (مكررة) / ERR_INVALID_DATA (أقدم من كل المخزّن والمخزن ممتلئ)
func add(time: float, state: Dictionary) -> Error:
	if not is_finite(time):
		return ERR_INVALID_PARAMETER
	var idx: int = _times.bsearch(time, false)
	if idx > 0 and absf(_times[idx - 1] - time) < TIME_EPSILON:
		return ERR_ALREADY_EXISTS
	if idx < _times.size() and absf(_times[idx] - time) < TIME_EPSILON:
		return ERR_ALREADY_EXISTS
	if idx == 0 and _times.size() >= _max_snapshots:
		return ERR_INVALID_DATA
	_times.insert(idx, time)
	_states.insert(idx, state.duplicate(true))
	_trim()
	return OK

## آخر لقطة وقتها <= time: {"time", "state"} أو {} لو لا يوجد.
func get_snapshot_at_or_before(time: float) -> Dictionary:
	if _times.is_empty() or not is_finite(time):
		return {}
	var idx: int = _times.bsearch(time, false) - 1
	if idx < 0:
		return {}
	return {"time": _times[idx], "state": _states[idx].duplicate()}

## حذف اللقطات الأقدم من time مع إبقاء لقطتين على الأقل (للحفاظ على إمكانية الـ Interpolation).
func prune_older_than(time: float) -> int:
	var removed: int = 0
	while _times.size() > 2 and _times[1] <= time:
		_times.remove_at(0)
		_states.remove_at(0)
		removed += 1
	return removed

## يرجع {"valid", "state", "alpha", "from_time", "to_time", "clamped"}.
## valid=false لو لا توجد بيانات. خارج النطاق: يثبّت على أقرب لقطة (clamped=true) بدون Extrapolation.
func sample(time: float) -> Dictionary:
	var n: int = _times.size()
	if n == 0 or not is_finite(time):
		return {"valid": false}
	if time <= _times[0]:
		return _make_result(_states[0], 0.0, _times[0], _times[0], time < _times[0])
	if time >= _times[n - 1]:
		return _make_result(_states[n - 1], 1.0, _times[n - 1], _times[n - 1], time > _times[n - 1])
	var upper: int = _times.bsearch(time, false)
	var t0: float = _times[upper - 1]
	var t1: float = _times[upper]
	var alpha: float = clampf((time - t0) / (t1 - t0), 0.0, 1.0)
	return _make_result(_lerp_state(_states[upper - 1], _states[upper], alpha), alpha, t0, t1, false)

# ---------------- داخلي ----------------

func _trim() -> void:
	while _times.size() > _max_snapshots:
		_times.remove_at(0)
		_states.remove_at(0)

func _make_result(state: Dictionary, alpha: float, from_t: float, to_t: float, clamped: bool) -> Dictionary:
	return {"valid": true, "state": state.duplicate(), "alpha": alpha,
		"from_time": from_t, "to_time": to_t, "clamped": clamped}

func _lerp_state(a: Dictionary, b: Dictionary, alpha: float) -> Dictionary:
	var out: Dictionary = {}
	for key: Variant in a.keys():
		var va: Variant = a[key]
		if b.has(key):
			out[key] = _lerp_value(key, va, b[key], alpha)
		else:
			out[key] = va
	return out

func _lerp_value(key: Variant, a: Variant, b: Variant, t: float) -> Variant:
	var type_a: int = typeof(a)
	if type_a != typeof(b):
		return a if t < 0.5 else b
	match type_a:
		TYPE_FLOAT:
			if _angle_keys.has(StringName(str(key))):
				return lerp_angle(float(a), float(b), t)
			return lerpf(float(a), float(b), t)
		TYPE_VECTOR2:
			return (a as Vector2).lerp(b as Vector2, t)
		TYPE_VECTOR3:
			return (a as Vector3).lerp(b as Vector3, t)
		TYPE_VECTOR4:
			return (a as Vector4).lerp(b as Vector4, t)
		TYPE_QUATERNION:
			return (a as Quaternion).slerp(b as Quaternion, t)
		TYPE_COLOR:
			return (a as Color).lerp(b as Color, t)
	return a if t < 0.5 else b
