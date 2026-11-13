
extends RefCounted

const VERSION: String = "0.1.0"
const BUILD: int = 1

const PATCH_DIR: String = "user://patches"
const PATCH_FILE: String = "user://patches/patch.pck"
const BUILD_FILE: String = "user://patches/installed_build.txt"
const BACKUP_FILE: String = "user://patches/patch.bak"


static func installed_build() -> int:
	if not FileAccess.file_exists(PATCH_FILE):
		return 0

	if not FileAccess.file_exists(BUILD_FILE):
		return 0

	var file := FileAccess.open(BUILD_FILE, FileAccess.READ)
	if file == null:
		return 0

	return file.get_as_text().strip_edges().to_int()


static func current_build() -> int:
	return maxi(BUILD, installed_build())
