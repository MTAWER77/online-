extends RefCounted
## scripts/updater/game_version.gd
## رقم نسخة اللعبة. كل ما تصدّر نسخة جديدة (أو patch) زوّد BUILD.
## BUILD هو اللي بيتقارن (بين نسختك والسيرفر، وبين الـ host والـ client)، و VERSION للعرض بس.

const VERSION: String = "0.1.0"
const BUILD: int = 1

const PATCH_DIR: String = "user://patches"
const PATCH_FILE: String = "user://patches/patch.pck"
const BUILD_FILE: String = "user://patches/installed_build.txt"


# رقم الـ build بتاع آخر patch اتنزّل (0 لو مفيش)
static func installed_build() -> int:
	if not FileAccess.file_exists(BUILD_FILE):
		return 0
	var file := FileAccess.open(BUILD_FILE, FileAccess.READ)
	if file == null:
		return 0
	return file.get_as_text().strip_edges().to_int()


# النسخة الفعلية اللي شغالة: الأعلى بين اللي متصدّرة واللي اتنزّلت
static func current_build() -> int:
	return maxi(BUILD, installed_build())
