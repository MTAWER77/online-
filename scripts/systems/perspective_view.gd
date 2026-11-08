extends Node
## scripts/systems/perspective_view.gd
## Perspective System: بيحدد مين من اللاعبين يشوف الـ node الأب.
## حطه كـ child جوه أي Node3D. الرؤية محلية عند كل لاعب (مش بتتزامن بالشبكة).
## P1 = الـ host، و P2 = اللاعب التاني.

enum Who { EVERYONE, HOST_ONLY, CLIENT_ONLY }

@export var visible_to: Who = Who.EVERYONE


func _ready() -> void:
	var target := get_parent() as Node3D
	if target == null:
		return
	target.visible = client_sees(visible_to, GDSync.get_client_id())


# هل اللاعب ده (برقم الـ client) يشوف حاجة مخصصة للفئة دي؟
static func client_sees(who: int, client_id: int) -> bool:
	if who == Who.EVERYONE or not GDSync.is_active():
		return true # من غير شبكة (تجربة أوفلاين) الكل يشوف كل حاجة
	var is_host_player: bool = client_id == GDSync.get_host()
	if who == Who.HOST_ONLY:
		return is_host_player
	return not is_host_player
