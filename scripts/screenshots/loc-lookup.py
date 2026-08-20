#!/usr/bin/env python3
"""Resolve a UI string to its localized form for scene driving.

    loc-lookup.py app <lang> <key>      PullMark's own strings (loc/*.lproj)
    loc-lookup.py system <lang> <key>   SwiftUI framework strings (loctable)

The generator's --lang matrix drives the app by ACCESSIBILITY TITLE,
and titles follow AppleLanguages. App-owned controls resolve from the
shipped translations in loc/ — the same files the app renders, so
scenes can never drift from the UI. System-owned controls (the
sidebar toggle is the only one scenes touch) resolve from SwiftUI's
own Localizable.loctable, so Apple's translations are read, never
guessed. An empty or "en" lang echoes the key: English is the key.

Exit 1 with a message on stderr when the key is missing — a scene
driving a control that lost its translation should fail loudly, not
click nothing.
"""

import plistlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
SWIFTUI_LOCTABLE = Path(
    "/System/Library/Frameworks/SwiftUI.framework/Resources/Localizable.loctable")

# loc/ uses BCP-47 (matching .lproj names); Apple's loctables key some
# locales with underscores.
LOCTABLE_LANG = {"zh-Hans": "zh_CN", "pt-BR": "pt_BR"}


def unescape(s):
    return s.replace('\\"', '"').replace("\\n", "\n").replace("\\\\", "\\")


def app_lookup(lang, key):
    path = ROOT / "loc" / f"{lang}.lproj" / "Localizable.strings"
    if not path.exists():
        sys.exit(f"loc-lookup: no translations at {path}")
    text = path.read_text(encoding="utf-8")
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"^\s*//.*$", "", text, flags=re.M)
    for m in re.finditer(r'"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', text):
        if unescape(m.group(1)) == key:
            return unescape(m.group(2))
    sys.exit(f"loc-lookup: key {key!r} missing from {path.name} ({lang})")


def system_lookup(lang, key):
    with SWIFTUI_LOCTABLE.open("rb") as f:
        table = plistlib.load(f)
    entry = table.get(LOCTABLE_LANG.get(lang, lang), {})
    value = entry.get(key)
    if value is None:
        sys.exit(f"loc-lookup: system key {key!r} missing for {lang!r} "
                 f"in {SWIFTUI_LOCTABLE.name}")
    return value


def main():
    if len(sys.argv) != 4 or sys.argv[1] not in ("app", "system"):
        sys.exit("usage: loc-lookup.py app|system <lang> <key>")
    mode, lang, key = sys.argv[1:4]
    if lang in ("", "en"):
        print(key)
        return
    print(app_lookup(lang, key) if mode == "app" else system_lookup(lang, key))


if __name__ == "__main__":
    main()
