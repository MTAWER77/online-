extends RefCounted
## scripts/multiplayer/net_clock.gd
## ساعة مشتركة بين الـ host والـ client.
## الـ client بيقدّر وقت الـ host من الـ snapshots (بياخد أقل latency شافه)، وبيعرض العالم متأخر شوية (render_delay).
## العربية والبلاتفورمات المتحركة بيستخدموا نفس الوقت ده، فمفيش عربية بتغطس جوه بلاتفورم عند الـ client.

const SessionMode = preload("res://scripts/multiplayer/session_mode.gd")

static var offset_ms: float = 0.0 # وقت الـ host ≈ وقتي المحلي + offset
static var jitter_ms: float = 0.0 # متوسط تأخر الحزم فوق أقل latency (مقياس للجيتر)
static var render_delay: float = 0.0 # بالثواني، العربية بتحدّده كل frame
static var synced: bool = false
static var _samples: Array = []


static func reset() -> void:
	offset_ms = 0.0
	jitter_ms = 0.0
	render_delay = 0.0
	synced = false
	_samples.clear()


static func is_client() -> bool:
	return (not SessionMode.offline) and GDSync.is_active() and not GDSync.is_host()


## الـ client بيستدعيها مع كل snapshot بوقت الـ host (ms) اللي اتبعتت فيه
static func feed(host_ms: int) -> void:
	var sample: float = float(host_ms - Time.get_ticks_msec())
	_samples.append(sample)
	if _samples.size() > 120:
		_samples.pop_front()
	var best: float = sample
	for v in _samples:
		if (v as float) > best:
			best = v as float
	if not synced:
		offset_ms = best
		synced = true
	else:
		offset_ms = lerpf(offset_ms, best, 0.05)
	jitter_ms = lerpf(jitter_ms, best - sample, 0.05)


## وقت العالم بالثواني. الـ host: وقته الحقيقي. الـ client: وقت الـ host المقدّر ناقص render_delay.
static func world_time() -> float:
	var local: float = float(Time.get_ticks_msec())
	if not is_client() or not synced:
		return local / 1000.0
	return (local + offset_ms) / 1000.0 - render_delay


## التأخير المقترح لعرض الـ client (بيزيد لو النت فيه جيتر)
static func suggested_delay(base: float) -> float:
	return clampf(base + 2.5 * jitter_ms / 1000.0, base, 0.35)
