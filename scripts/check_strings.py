#!/usr/bin/env python3
"""Every L("…")/LF("…") key used in the app needs a German translation.

  check_strings.py          check (exit 1 on missing/unused/format mismatch)
  check_strings.py --keys   print the keys that still need a translation
"""
import re
import sys
import pathlib

root = pathlib.Path(__file__).resolve().parent.parent
pattern = re.compile(r'\bLF?\(\s*"((?:[^"\\]|\\.)*)"')
keys = set()
for f in (root / "app" / "Sources").glob("*.swift"):
    keys.update(pattern.findall(f.read_text(encoding="utf-8")))

strings_file = root / "app/Resources/de.lproj/Localizable.strings"
text = strings_file.read_text(encoding="utf-8") if strings_file.exists() else ""
entry = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";\s*$', re.M)
translated = dict(entry.findall(text))

missing = sorted(k for k in keys if k not in translated)
if "--keys" in sys.argv:
    print("\n".join(missing))
    sys.exit(0)

problems = 0
for k in missing:
    print(f"missing German translation: {k}")
    problems += 1
for k in sorted(k for k in translated if k not in keys):
    print(f"unused German string: {k}")
    problems += 1
spec = re.compile(r'%(?:\d+\$)?(?:ll|l)?[@dfsxX]')
for k in sorted(keys & set(translated)):
    if sorted(spec.findall(k)) != sorted(spec.findall(translated[k])):
        print(f"format mismatch: {k!r} -> {translated[k]!r}")
        problems += 1
print(f"{len(keys)} keys, {problems} problems")
sys.exit(1 if problems else 0)
