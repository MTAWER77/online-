extends Control

const GameVersion = preload("res://scripts/updater/game_version.gd")
const DebugLog = preload("res://scripts/systems/debug_log.gd")
const MENU_SCENE := "res://scenes/ui/main_menu.tscn"

# رابط السوبا باس الخاص بك
@export var version_url: String = "https://gnyxytqqzxidaqsaixog.supabase.co/storage/v1/object/public/Build-update/version.json"
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
	_version_label.text = "v%s (build %d)" % [GameVersion.VERSION, GameVersion.current_build()]
	_run.call_deferred()

func _process(_delta: float) -> void:
	if not _downloading or _download_request == null: return
	var total := _download_request.get_body_size()
	if total > 0:
		_bar.value = 100.0 * float(_download_request.get_downloaded_bytes()) / float(total)

func _run() -> void:
	if _updates_allowed():
		_apply_installed_patch()
		if version_url.begins_with("https://"):
			await _check_and_download()
	else:
		DebugLog.say("UPDATE", "التحديث متوقف")
	get_tree().change_scene_to_file(MENU_SCENE)

func _updates_allowed() -> bool:
	if OS.has_feature("web"): return false
	if OS.has_feature("editor") and not check_in_editor: return false
	return true

func _apply_installed_patch() -> void:
	print("UPDATE DEBUG: --- _apply_installed_patch ---")
	if not FileAccess.file_exists(GameVersion.PATCH_FILE): 
		print("UPDATE DEBUG: No patch file to apply.")
		return
		
	var installed := GameVersion.installed_build()
	print("UPDATE DEBUG: installed = %d | GameVersion.BUILD = %d" % [installed, GameVersion.BUILD])
	
	if installed > 0 and installed <= GameVersion.BUILD:
		print("UPDATE DEBUG: Patch is old/equal to base build. Removing.")
		_remove_file(GameVersion.PATCH_FILE)
		_remove_file(GameVersion.SIGNATURE_FILE)
		_remove_file(GameVersion.BUILD_FILE)
		return

	print("UPDATE DEBUG: Verifying saved patch signature...")
	if not _verify_patch_signature(GameVersion.PATCH_FILE, GameVersion.SIGNATURE_FILE):
		print("UPDATE DEBUG: ERROR! Saved patch signature failed. Removing patch.")
		_remove_file(GameVersion.PATCH_FILE)
		_remove_file(GameVersion.SIGNATURE_FILE)
		_remove_file(GameVersion.BUILD_FILE)
		return

	print("UPDATE DEBUG: Loading resource pack...")
	var loaded := ProjectSettings.load_resource_pack(GameVersion.PATCH_FILE, true)
	if loaded: 
		print("UPDATE DEBUG: Successfully loaded saved patch!")
		DebugLog.say("UPDATE", "تم تحميل التحديث المحفوظ Build %d" % installed)
	else:
		print("UPDATE DEBUG: ERROR! Failed to load resource pack.")

func _check_and_download() -> void:
	print("UPDATE DEBUG: --- _check_and_download ---")
	_status.text = "بنفحص التحديثات..."
	var http := HTTPRequest.new()
	http.timeout = request_timeout
	add_child(http)

	if http.request(version_url) != OK:
		http.queue_free()
		_status.text = "تعذر الاتصال"
		return

	var response: Array = await http.request_completed
	http.queue_free()

	if response[0] != HTTPRequest.RESULT_SUCCESS or response[1] != 200:
		_status.text = "مفيش اتصال، بنكمل بالنسخة الحالية"
		return

	var data: Variant = JSON.parse_string(response[3].get_string_from_utf8())
	if not data is Dictionary: return

	var remote_build := int(data.get("build", 0))
	var current_b := GameVersion.current_build()
	
	print("UPDATE DEBUG: remote_build = %d | current_build = %d" % [remote_build, current_b])
	
	if remote_build <= current_b:
		print("UPDATE DEBUG: Already up to date. Skipping download.")
		_status.text = "اللعبة محدّثة"
		return

	var pck_url := str(data.get("pck_url", ""))
	var sig_url := str(data.get("sig_url", ""))

	if pck_url.is_empty() or sig_url.is_empty(): return
	await _download_and_install(pck_url, sig_url, remote_build)

func _download_and_install(pck_url: String, sig_url: String, build: int) -> void:
	_status.text = "بننزّل التحديث..."
	_bar.value = 0
	_bar.visible = true
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(GameVersion.PATCH_DIR))
	
	var temp_pck := GameVersion.PATCH_DIR + "/patch.tmp"
	var temp_sig := GameVersion.PATCH_DIR + "/patch.tmp.sig"
	_remove_file(temp_pck); _remove_file(temp_sig)

	if not await _download_file(pck_url, temp_pck, 0.0, 0.85): return _finish("فشل تحميل الملف")
	if not await _download_file(sig_url, temp_sig, 0.85, 1.0): return _finish("فشل تحميل التوقيع")

	_status.text = "بنفحص التوقيع..."
	if not _verify_patch_signature(temp_pck, temp_sig):
		print("UPDATE DEBUG: ERROR! Downloaded patch signature failed.")
		_remove_file(temp_pck); _remove_file(temp_sig)
		_finish("التحديث غير موثوق — تم الرفض!")
		return

	var installed := _install_patch(temp_pck, temp_sig, build)
	_finish("تم تثبيت التحديث %d بنجاح" % build if installed else "فشل التثبيت")

func _download_file(url: String, save_path: String, p_from: float, p_to: float) -> bool:
	_download_request = HTTPRequest.new()
	_download_request.timeout = download_timeout
	_download_request.download_file = ProjectSettings.globalize_path(save_path)
	add_child(_download_request)
	_downloading = true
	_bar.value = p_from * 100.0

	if _download_request.request(url) != OK: return false

	var response: Array = await _download_request.request_completed
	_downloading = false
	_bar.value = p_to * 100.0
	_download_request.queue_free()
	_download_request = null
	
	return response[0] == HTTPRequest.RESULT_SUCCESS and FileAccess.file_exists(save_path)

# التحقق من التوقيع باستخدام RSA
# التحقق من التوقيع باستخدام RSA
# التحقق من التوقيع باستخدام RSA (النسخة النهائية)
# التحقق من التوقيع باستخدام RSA (النسخة النهائية المضمونة)
func _verify_patch_signature(pck_path: String, sig_path: String) -> bool:
	if not FileAccess.file_exists(pck_path) or not FileAccess.file_exists(sig_path): 
		return false
		
	var pck_bytes := FileAccess.get_file_as_bytes(pck_path)
	var sig_bytes := FileAccess.get_file_as_bytes(sig_path)
	
	if pck_bytes.is_empty() or sig_bytes.is_empty():
		print("UPDATE DEBUG: Empty file data.")
		return false

	print("UPDATE DEBUG: PCK Size = ", pck_bytes.size(), " | SIG Size = ", sig_bytes.size())

	var key := CryptoKey.new()
	var err := key.load_from_string(GameVersion.PUBLIC_KEY, true)
	if err != OK:
		print("UPDATE DEBUG: Failed to load RSA public key! Error: ", err)
		return false
	
	# 1. حساب الـ Hash بتاع الملف (لازم يكون 32 بايت)
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	hashing.update(pck_bytes)
	var pck_hash := hashing.finish()
	
	print("UPDATE DEBUG: Hash Size = ", pck_hash.size())
	
	# 2. تمرير الـ Hash (مش الملف) لدالة التحقق
	var crypto := Crypto.new()
	var verified := crypto.verify(HashingContext.HASH_SHA256, pck_hash, sig_bytes, key)
	
	if not verified:
		print("UPDATE DEBUG: RSA signature verification FAILED.")
	else:
		print("UPDATE DEBUG: RSA signature verified OK.")
	
	return verified
func _install_patch(temp_pck: String, temp_sig: String, build: int) -> bool:
	print("UPDATE DEBUG: --- _install_patch ---")
	var pck_abs := ProjectSettings.globalize_path(GameVersion.PATCH_FILE)
	var sig_abs := ProjectSettings.globalize_path(GameVersion.SIGNATURE_FILE)
	
	_remove_file(GameVersion.BACKUP_FILE)
	_remove_file(GameVersion.BACKUP_SIG_FILE)
	
	if FileAccess.file_exists(GameVersion.PATCH_FILE):
		print("UPDATE DEBUG: Moving old patch to backup.")
		DirAccess.rename_absolute(pck_abs, ProjectSettings.globalize_path(GameVersion.BACKUP_FILE))
		if FileAccess.file_exists(GameVersion.SIGNATURE_FILE):
			DirAccess.rename_absolute(sig_abs, ProjectSettings.globalize_path(GameVersion.BACKUP_SIG_FILE))

	print("UPDATE DEBUG: Moving new patch to final path.")
	DirAccess.rename_absolute(ProjectSettings.globalize_path(temp_pck), pck_abs)
	DirAccess.rename_absolute(ProjectSettings.globalize_path(temp_sig), sig_abs)

	print("UPDATE DEBUG: Loading new resource pack...")
	if not ProjectSettings.load_resource_pack(GameVersion.PATCH_FILE, true): 
		print("UPDATE DEBUG: Failed to load new patch.")
		return false

	print("UPDATE DEBUG: Writing build number to file.")
	var marker := FileAccess.open(GameVersion.BUILD_FILE, FileAccess.WRITE)
	if marker:
		marker.store_string(str(build))
		marker.close()
		print("UPDATE DEBUG: Successfully wrote build %d to file" % build)
		return true
	else:
		print("UPDATE DEBUG: FAILED to write BUILD_FILE")
		return false

func _finish(msg: String) -> void:
	_status.text = msg
	_bar.visible = false
	await get_tree().create_timer(2.0).timeout
	get_tree().change_scene_to_file(MENU_SCENE)

func _remove_file(path: String) -> void:
	if FileAccess.file_exists(path): DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
