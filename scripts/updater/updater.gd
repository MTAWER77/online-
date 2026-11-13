extends Control
## scripts/updater/updater.gd
## شاشة أول ما اللعبة تفتح: تفحص version.json، ولو فيه نسخة أحدث تنزّل patch.pck وتحمّله،
## وبعدين تكمل للقائمة. لو مفيش نت أو حصل أي خطأ بنكمل بالنسخة الحالية (مش بنوقف اللعبة أبدًا).
##
## ملاحظات:
##  - بيتجاهل نفسه في المحرر (عشان الـ pck ما يغطيش على ملفات المشروع) وعلى الويب.
##  - الـ patch لازم يكون Export PCK كامل للمشروع (مش فروقات).
##  - لازم رابط https، والـ sha256 في version.json بيتأكد إن الملف وصل سليم.

const GameVersion = preload("res://scripts/updater/game_version.gd")
const DebugLog = preload("res://scripts/systems/debug_log.gd")

const MENU_SCENE: String = "res://scenes/ui/main_menu.tscn"

## رابط version.json. الافتراضي: آخر Release على GitHub (لازم الـ repo public). سيبه فاضي لإيقاف التحديث.
@export var version_url: String = "https://github.com/MTAWER77/online-/releases/latest/download/version.json"
@export var check_in_editor: bool = false # للتجربة بس
@export var request_timeout: float = 8.0
@export var download_timeout: float = 120.0

@onready var _status: Label = %StatusLabel
@onready var _bar: ProgressBar = %ProgressBar
@onready var _version_label: Label = %VersionLabel

var _download_request: HTTPRequest
var _downloading: bool = false


func _ready() -> void:
	_bar.visible = false
	_version_label.text = "v%s (build %d)" % [GameVersion.VERSION, GameVersion.current_build()]
	_run.call_deferred()


func _process(_delta: float) -> void:
	if not _downloading or _download_request == null:
		return
	var total: int = _download_request.get_body_size()
	if total > 0:
		_bar.value = 100.0 * float(_download_request.get_downloaded_bytes()) / float(total)


func _run() -> void:
	if _updates_allowed():
		_apply_installed_patch()
		if version_url.begins_with("https://"):
			await _check_and_download()
	else:
		DebugLog.say("UPDATE", "التحديث متوقف (محرر أو ويب)")
	get_tree().change_scene_to_file(MENU_SCENE)


func _updates_allowed() -> bool:
	if OS.has_feature("web"):
		return false
	if OS.has_feature("editor") and not check_in_editor:
		return false
	return true


# patch اتنزّل قبل كده: نحمّله على طول، إلا لو النسخة المتصدّرة أحدث منه
func _apply_installed_patch() -> void:
	if not FileAccess.file_exists(GameVersion.PATCH_FILE):
		return
	if GameVersion.installed_build() > GameVersion.BUILD:
		var ok: bool = ProjectSettings.load_resource_pack(GameVersion.PATCH_FILE, true)
		DebugLog.say("UPDATE", "تحميل patch محفوظ (build %d): %s" % [GameVersion.installed_build(), ok])
	else:
		# patch قديم والنسخة المتصدّرة أحدث منه: نمسحه
		_remove_file(GameVersion.PATCH_FILE)
		_remove_file(GameVersion.BUILD_FILE)
		DebugLog.say("UPDATE", "patch قديم اتمسح")


func _check_and_download() -> void:
	_status.text = "بنفحص التحديثات..."
	var http := HTTPRequest.new()
	http.timeout = request_timeout
	add_child(http)
	if http.request(version_url) != OK:
		http.queue_free()
		_status.text = "تعذّر فحص التحديثات"
		return
	var response: Array = await http.request_completed
	http.queue_free()
	if int(response[0]) != HTTPRequest.RESULT_SUCCESS or int(response[1]) != 200:
		DebugLog.say("UPDATE", "فحص النسخة فشل (result=%d code=%d)" % [int(response[0]), int(response[1])])
		_status.text = "مفيش اتصال، بنكمل بالنسخة الحالية"
		return

	var data: Variant = JSON.parse_string((response[3] as PackedByteArray).get_string_from_utf8())
	if not (data is Dictionary):
		_status.text = "ملف النسخة مش مفهوم"
		return
	var remote: Dictionary = data
	var remote_build: int = int(remote.get("build", 0))
	var url: String = str(remote.get("url", ""))
	var sha: String = str(remote.get("sha256", "")).to_lower()
	DebugLog.say("UPDATE", "الحالي=%d، على السيرفر=%d" % [GameVersion.current_build(), remote_build])

	if remote_build <= GameVersion.current_build():
		_status.text = "اللعبة محدّثة"
		return
	if not url.begins_with("https://"):
		_status.text = "رابط التحديث مش آمن"
		return
	await _download_patch(url, sha, remote_build)


func _download_patch(url: String, sha256: String, build: int) -> void:
	_status.text = "بننزّل التحديث..."
	_bar.value = 0.0
	_bar.visible = true
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(GameVersion.PATCH_DIR))
	var temp_path: String = GameVersion.PATCH_DIR + "/patch.tmp"

	_download_request = HTTPRequest.new()
	_download_request.download_file = temp_path
	_download_request.timeout = download_timeout
	add_child(_download_request)
	if _download_request.request(url) != OK:
		_finish_download("تعذّر بدء التحميل")
		return
	_downloading = true
	var response: Array = await _download_request.request_completed
	_downloading = false
	if int(response[0]) != HTTPRequest.RESULT_SUCCESS or int(response[1]) != 200:
		_remove_file(temp_path)
		_finish_download("التحميل فشل، بنكمل بالنسخة الحالية")
		return

	if sha256 != "" and FileAccess.get_sha256(temp_path) != sha256:
		_remove_file(temp_path)
		DebugLog.say("UPDATE", "sha256 مش متطابق: الملف اتلغى")
		_finish_download("الملف تالف، بنكمل بالنسخة الحالية")
		return

	# نثبّت الملف ونسجّل رقمه، وبعدين نحمّله
	_remove_file(GameVersion.PATCH_FILE)
	DirAccess.rename_absolute(
		ProjectSettings.globalize_path(temp_path),
		ProjectSettings.globalize_path(GameVersion.PATCH_FILE))
	var file := FileAccess.open(GameVersion.BUILD_FILE, FileAccess.WRITE)
	if file != null:
		file.store_string(str(build))
		file.close()
	var loaded: bool = ProjectSettings.load_resource_pack(GameVersion.PATCH_FILE, true)
	DebugLog.say("UPDATE", "اتنزّل ونُصّب build %d (load=%s)" % [build, loaded])
	_finish_download("اتحدّثت للنسخة %d" % build if loaded else "التحديث اتنزّل بس فشل تحميله")


func _finish_download(message: String) -> void:
	_status.text = message
	_bar.visible = false
	if _download_request != null:
		_download_request.queue_free()
		_download_request = null


func _remove_file(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
