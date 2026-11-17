extends RefCounted
## scripts/updater/game_version.gd

const VERSION: String = "0.1.0"
const BUILD: int = 1 # دي النسخة الأساسية

const PATCH_DIR: String = "user://patches"
const PATCH_FILE: String = "user://patches/patch.pck"
const SIGNATURE_FILE: String = "user://patches/patch.sig"
const BUILD_FILE: String = "user://patches/installed_build.txt"
const BACKUP_FILE: String = "user://patches/patch.bak"
const BACKUP_SIG_FILE: String = "user://patches/patch.bak.sig"

# المفتاح العام الجديد (RSA) الخاص بمشروعك
const PUBLIC_KEY: String = """-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA3OSBegBC7zsdYePeAzkn
wIoh493BdArB9ZmdVawSLPU8hrMb71YteLUVcIy/eZeJth2VXVG2apqzDYaRN4DX
vnDRP6io7R3NaEFapfkiicrWWhLmKaG+qJmZxs3XMByjGaj7KSLeWWQUTiXeiBR8
LPiK9CoEYYcVvRAHbmptnKYhBRtU3IqGMiKjSyOT3H5v6j57xmV/vt19T/eHQ7bl
m42jSZGS0GMlyRbWU+CrQuv20hDY6Pb/p4Mh+tQ8zaGc22MsITzX97gYKbLwilqF
zIyqCPAIUClFiLea+SakzdcLxJJf/G3ERmoEHiqvmT/S+LHa/eogpkoTLxJkk0bE
FwIDAQAB
-----END PUBLIC KEY-----"""

static func installed_build() -> int:
	print("UPDATE DEBUG: Checking installed build...")
	if not FileAccess.file_exists(PATCH_FILE):
		print("UPDATE DEBUG: PATCH_FILE missing (user://patches/patch.pck)")
		return 0
	if not FileAccess.file_exists(BUILD_FILE):
		print("UPDATE DEBUG: BUILD_FILE missing (user://patches/installed_build.txt)")
		return 0
		
	var file := FileAccess.open(BUILD_FILE, FileAccess.READ)
	if file == null: 
		print("UPDATE DEBUG: Could not open BUILD_FILE")
		return 0
		
	var text := file.get_as_text().strip_edges()
	file.close()
	print("UPDATE DEBUG: Found installed build = ", text)
	return text.to_int()

static func current_build() -> int:
	return maxi(BUILD, installed_build())
