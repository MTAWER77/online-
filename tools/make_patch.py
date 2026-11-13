#!/usr/bin/env python3
"""يعمل version.json لـ patch.pck (بيحسب sha256 لوحده).

مثال:
  python3 tools/make_patch.py build/patch.pck --build 2 --version 0.2.0 \
      --url https://github.com/MTAWER77/online-/releases/download/v0.2.0/patch.pck
الناتج: build/version.json (ارفعه مع patch.pck على نفس الـ Release)
"""
import argparse, hashlib, json, pathlib

ap = argparse.ArgumentParser()
ap.add_argument("pck")
ap.add_argument("--build", type=int, required=True, help="لازم يكون أكبر من BUILD الحالي وبيطابق game_version.gd")
ap.add_argument("--version", required=True)
ap.add_argument("--url", required=True, help="رابط https مباشر لـ patch.pck")
ap.add_argument("--notes", default="")
a = ap.parse_args()
if not a.url.startswith("https://"):
    raise SystemExit("الرابط لازم يبدأ بـ https://")
pck = pathlib.Path(a.pck)
sha = hashlib.sha256(pck.read_bytes()).hexdigest()
out = pck.with_name("version.json")
out.write_text(json.dumps({"build": a.build, "version": a.version, "url": a.url,
                           "sha256": sha, "notes": a.notes}, indent=2), encoding="utf-8")
print(f"{out} (sha256 {sha[:12]}…, {pck.stat().st_size} bytes)")
