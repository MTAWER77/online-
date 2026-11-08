extends Area3D
## scripts/systems/interactable.gd
## أي حاجة اللاعب يقدر يتفاعل معاها بزرار E.
## القاعدة: اللاعب بيطلب، والـ host هو اللي بيقرر وينفّذ (نفس نمط مكعب F).
## السكريبتات اللي بترث منه بتعمل override لـ: can_interact و get_prompt و _on_host_interact.
## ملحوظة: الـ node لازم يكون ليه نفس المسار عند الاتنين (حطه ثابت في المشهد).

signal host_interacted(client_id: int)

@export var prompt_text: String = "Interact"
@export var interact_priority: int = 0 # لو في أكتر من حاجة قريبة، الأعلى أولوية يتختار الأول


func _ready() -> void:
	add_to_group("interactable")
	# طبقة 2 = حاجات قابلة للتفاعل (الـ InteractionDetector بتاع اللاعب بيشوفها)
	collision_layer = 2
	collision_mask = 0
	monitoring = false
	monitorable = true
	# أي لاعب يقدر يبعت الطلب، لكن التنفيذ عند الـ host بس
	GDSync.expose_func(_receive_interact_request)


# رقم اللاعب ده على الجهاز ده (0 لو من غير شبكة)
func local_client_id() -> int:
	return GDSync.get_client_id() if GDSync.is_active() else 0


# النص اللي بيظهر للاعب (override)
func get_prompt(_client_id: int) -> String:
	return "E: " + prompt_text


# هل اللاعب ده يقدر يتفاعل دلوقتي؟ (override)
func can_interact(_client_id: int) -> bool:
	return true


# بيتنادى من اللاعب المحلي لما يدوس E
func request_interact() -> void:
	if not GDSync.is_active() or GDSync.is_host():
		_handle_on_host(local_client_id())
	else:
		GDSync.call_func_on(GDSync.get_host(), _receive_interact_request)


# بتتنفذ عند الـ host بس
func _receive_interact_request() -> void:
	if not GDSync.is_host():
		return
	_handle_on_host(GDSync.get_sender_id())


func _handle_on_host(client_id: int) -> void:
	if not can_interact(client_id):
		return
	_on_host_interact(client_id)
	host_interacted.emit(client_id)


# التنفيذ الفعلي عند الـ host (override)
func _on_host_interact(_client_id: int) -> void:
	pass
