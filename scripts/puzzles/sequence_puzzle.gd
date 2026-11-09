extends Node
## scripts/puzzles/sequence_puzzle.gd
## لغز الغرفة 1: اللاعب التاني يدوس أزرار اللوحة بنفس ترتيب الرموز اللي على لوحة اللاعب الأول.
## القرار كله عند الـ host (هو اللي عنده الترتيب وهو اللي بيستقبل الضغطات).
## صح كله = الباب يفتح عند الاتنين. غلط = الباب يومض أحمر والعدّ يبدأ من الأول.

signal solved
signal mistake

@export var board_path: NodePath # لوحة الترتيب (SymbolSequence)
@export var door_path: NodePath
@export var button_paths: Array[NodePath] = []

var _board: Node
var _door: Node
var _progress: int = 0
var _is_solved: bool = false


func _ready() -> void:
	_board = get_node_or_null(board_path)
	_door = get_node_or_null(door_path)
	if _board == null or _door == null:
		push_error("SequencePuzzle: board_path أو door_path مش متحددين")
		return
	for path in button_paths:
		var button: Node = get_node_or_null(path)
		if button != null:
			# host_interacted بتطلع عند الـ host بس، فالمنطق كله بيشتغل عنده
			button.host_interacted.connect(_on_button_pressed.bind(button))


# client_id: اللي داس، button: الزرار اللي اتداس
func _on_button_pressed(_client_id: int, button: Node) -> void:
	if _is_solved or _board.sequence.is_empty():
		return
	if button.symbol_id == _board.sequence[_progress]:
		_progress += 1
		print("SequencePuzzle: صح %d/%d" % [_progress, _board.sequence.size()])
		if _progress >= _board.sequence.size():
			_is_solved = true
			_door.host_open()
			solved.emit()
	else:
		print("SequencePuzzle: غلط، نبدأ من الأول")
		_progress = 0
		_door.host_wrong()
		mistake.emit()
