
extends Control

const GameVersion = preload("res://scripts/updater/game_version.gd")
const DebugLog = preload("res://scripts/systems/debug_log.gd")

const MENU_SCENE := "res://scenes/ui/main_menu.tscn"

@export var version_url: String = "https://raw.githubusercontent.com/MTAWER77/Update-game/main/version.json"
@export var check_in_editor := false
@export var request_timeout := 8.0
@export var download_timeout := 120.0

@onready var _status: Label = %StatusLabel
@onready var _bar: ProgressBar = %ProgressBar
@onready var _version_label: Label = %VersionLabel

var _download_request: HTTPRequest
var _downloading := false


func _ready() -> void:
	_bar.visible = false

	_version_label.text = "v%s (build %d)" % [
		GameVersion.VERSION,
		GameVersion.current_build()
	]

	_run.call_deferred()


func _process(_delta: float) -> void:
	if not _downloading or _download_request == null:
		return

	var total := _download_request.get_body_size()

	if total > 0:
		_bar.value = (
			100.0 *
			float(_download_request.get_downloaded_bytes()) /
			float(total)
		)


func _run() -> void:
	if _updates_allowed():
		_apply_installed_patch()

		if version_url.begins_with("https://"):
			await _check_and_download()
	else:
		DebugLog.say("UPDATE", "التحديث متوقف")

	get_tree().change_scene_to_file(MENU_SCENE)


func _updates_allowed() -> bool:
	if OS.has_feature("web"):
		return false

	if OS.has_feature("editor") and not check_in_editor:
		return false

	return true


func _apply_installed_patch() -> void:
	if not FileAccess.file_exists(GameVersion.PATCH_FILE):
		return

	var installed := GameVersion.installed_build()

	if installed <= GameVersion.BUILD:
		_remove_file(GameVersion.PATCH_FILE)
		_remove_file(GameVersion.BUILD_FILE)
		return

	var loaded := ProjectSettings.load_resource_pack(
		GameVersion.PATCH_FILE,
		true
	)

	if loaded:
		DebugLog.say(
			"UPDATE",
			"تم تحميل التحديث المحفوظ Build %d" % installed
		)
	else:
		DebugLog.say(
			"UPDATE",
			"فشل تحميل التحديث المحفوظ"
		)

		_remove_file(GameVersion.PATCH_FILE)
		_remove_file(GameVersion.BUILD_FILE)


func _check_and_download() -> void:
	_status.text = "بنفحص التحديثات..."

	var http := HTTPRequest.new()
	http.timeout = request_timeout
	add_child(http)

	var err := http.request(version_url)

	if err != OK:
		http.queue_free()
		_status.text = "تعذر الاتصال"
		return

	var response: Array = await http.request_completed
	http.queue_free()

	if response[0] != HTTPRequest.RESULT_SUCCESS:
		_status.text = "مفيش اتصال، بنكمل بالنسخة الحالية"
		return

	if response[1] != 200:
		_status.text = "تعذر قراءة التحديث"
		return

	var data: Variant = JSON.parse_string(
		response[3].get_string_from_utf8()
	)

	if not data is Dictionary:
		_status.text = "ملف التحديث غير صالح"
		return

	var remote: Dictionary = data

	var remote_build := int(remote.get("build", 0))
	var url := str(remote.get("url", ""))
	var sha := str(remote.get("sha256", "")).to_lower()

	DebugLog.say(
		"UPDATE",
		"الحالي=%d، السيرفر=%d" % [
			GameVersion.current_build(),
			remote_build
		]
	)

	if remote_build <= GameVersion.current_build():
		_status.text = "اللعبة محدّثة"
		return

	if not url.begins_with("https://"):
		_status.text = "رابط التحديث غير آمن"
		return

	if sha.length() != 64:
		_status.text = "بصمة الملف غير صالحة"
		return

	await _download_patch(url, sha, remote_build)


func _download_patch(
	url: String,
	sha256: String,
	build: int
) -> void:
	_status.text = "بننزّل التحديث..."
	_bar.value = 0
	_bar.visible = true

	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(GameVersion.PATCH_DIR)
	)

	var temp_path := GameVersion.PATCH_DIR + "/patch.tmp"

	_remove_file(temp_path)

	_download_request = HTTPRequest.new()
	_download_request.timeout = download_timeout
	_download_request.download_file = ProjectSettings.globalize_path(
		temp_path
	)

	add_child(_download_request)

	var err := _download_request.request(url)

	if err != OK:
		_remove_file(temp_path)
		_finish_download("تعذر بدء التحميل")
		return

	_downloading = true

	var response: Array = await _download_request.request_completed

	_downloading = false

	if response[0] != HTTPRequest.RESULT_SUCCESS or response[1] != 200:
		_remove_file(temp_path)
		_finish_download("فشل التحميل")
		return

	if not FileAccess.file_exists(temp_path):
		_finish_download("ملف التحديث غير موجود")
		return

	var actual_sha := FileAccess.get_sha256(temp_path).to_lower()

	if actual_sha != sha256:
		_remove_file(temp_path)
		_finish_download("الملف تالف أو البصمة غير مطابقة")
		return

	var installed := _install_patch(temp_path, build)

	if installed:
		_finish_download("تم تثبيت التحديث %d" % build)
	else:
		_finish_download("فشل تثبيت التحديث")


func _install_patch(temp_path: String, build: int) -> bool:
	var patch_absolute := ProjectSettings.globalize_path(
		GameVersion.PATCH_FILE
	)

	var backup_absolute := ProjectSettings.globalize_path(
		GameVersion.BACKUP_FILE
	)

	var temp_absolute := ProjectSettings.globalize_path(temp_path)

	_remove_file(GameVersion.BACKUP_FILE)

	var had_old_patch := FileAccess.file_exists(
		GameVersion.PATCH_FILE
	)

	if had_old_patch:
		var backup_err := DirAccess.rename_absolute(
			patch_absolute,
			backup_absolute
		)

		if backup_err != OK:
			_remove_file(temp_path)
			return false

	var move_err := DirAccess.rename_absolute(
		temp_absolute,
		patch_absolute
	)

	if move_err != OK:
		_restore_backup(had_old_patch)
		return false

	# تحميل PCK للتحقق منه.
	var loaded := ProjectSettings.load_resource_pack(
		GameVersion.PATCH_FILE,
		true
	)

	if not loaded:
		_remove_file(GameVersion.PATCH_FILE)
		_restore_backup(had_old_patch)
		return false

	# حفظ رقم النسخة بعد نجاح تحميل PCK.
	var marker := FileAccess.open(
		GameVersion.BUILD_FILE,
		FileAccess.WRITE
	)

	if marker == null:
		_remove_file(GameVersion.PATCH_FILE)
		_restore_backup(had_old_patch)
		return false

	marker.store_string(str(build))
	marker.close()

	_remove_file(GameVersion.BACKUP_FILE)

	DebugLog.say(
		"UPDATE",
		"تم تثبيت Build %d بنجاح" % build
	)

	return true


func _restore_backup(had_old_patch: bool) -> void:
	if not had_old_patch:
		return

	if not FileAccess.file_exists(GameVersion.BACKUP_FILE):
		return

	DirAccess.rename_absolute(
		ProjectSettings.globalize_path(GameVersion.BACKUP_FILE),
		ProjectSettings.globalize_path(GameVersion.PATCH_FILE)
	)


func _finish_download(message: String) -> void:
	_status.text = message
	_bar.visible = false

	if _download_request != null:
		_download_request.queue_free()
		_download_request = null


func _remove_file(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(
			ProjectSettings.globalize_path(path)
		)
