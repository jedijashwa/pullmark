#!/usr/bin/env python3
"""Localization gate (spec: app-i18n). Run by `make test`.

A missing key fails SILENTLY to English at runtime, and no Apple
tooling can inventory SwiftUI string literals outside Xcode — so this
script is the whole safety net:

  * inventories every localizable key: SwiftUI literal call sites,
    String(localized:)/NSLocalizedString sites, and PageStrings.keys
    (the rendered page's table)
  * verifies PageStrings.keys covers every pmString/pmFormat key in
    app.js (page strings that miss the table silently stay English)
  * diffs the inventory against each locale's Localizable.strings:
    missing keys and orphans are both failures
  * verifies format specifiers (%@, %lld, …) in every translation
    match its key — a mismatch garbles or crashes at runtime

With no loc/*.lproj present (pre-translation), only the app.js/
PageStrings consistency check runs, plus the inventory is written to
loc/_inventory.json for the translation step.

Exit 0 = clean; 1 = problems, each on its own line.

Usage: check-strings.py [--write-inventory]
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources" / "PullMark"
LOC = ROOT / "loc"

problems = []


def problem(msg):
    problems.append(msg)


# ---------- Swift-side key extraction ----------

# SwiftUI initializers whose FIRST string-literal argument is a
# LocalizedStringKey. Interpolated literals become format keys the way
# String.LocalizationValue renders them (\(x) → %@ by default — matches
# String(localized:) runtime behavior for the common String/Int cases
# only approximately; interpolated SwiftUI literals are flagged).
SWIFTUI_CALLS = r"(?:Text|Button|Label|Toggle|Picker|TextField|Menu|Section|CommandMenu)"

STRING_LIT = r'"(?:[^"\\\n]|\\.)*"'


def swift_literal_to_key(lit, flag_interpolated=None, where=""):
    body = lit[1:-1]
    # interpolations → %@ (the LocalizationValue default for CustomStringConvertible)
    def interp(m):
        return "%@"
    key, n = re.subn(r"\\\((?:[^()]|\([^()]*\))*\)", interp, body)
    if n and flag_interpolated is not None:
        flag_interpolated.add((where, key))
    key = key.replace('\\"', '"').replace("\\n", "\n").replace("\\\\", "\\")
    return key


def collect_swift_keys():
    keys = {}
    interpolated = set()
    for path in sorted(SOURCES.rglob("*.swift")):
        s = path.read_text(encoding="utf-8")
        rel = str(path.relative_to(ROOT))
        for m in re.finditer(r"\b" + SWIFTUI_CALLS + r"\(\s*(" + STRING_LIT + ")", s):
            key = swift_literal_to_key(m.group(1), interpolated, rel)
            if re.search(r"[A-Za-z]", key):
                keys.setdefault(key, rel)
        for m in re.finditer(r"\.help\(\s*(" + STRING_LIT + ")\s*\)", s):
            key = swift_literal_to_key(m.group(1), interpolated, rel)
            if re.search(r"[A-Za-z]", key):
                keys.setdefault(key, rel)
        for m in re.finditer(r"String\(localized:\s*(" + STRING_LIT + ")", s):
            keys.setdefault(swift_literal_to_key(m.group(1), interpolated, rel), rel)
        for m in re.finditer(r"NSLocalizedString\(\s*(" + STRING_LIT + ")", s):
            key = swift_literal_to_key(m.group(1), interpolated, rel)
            if key != "%@":  # PageStrings' dynamic lookup call
                keys.setdefault(key, rel)
    return keys, interpolated


# ---------- Page strings (app.js ↔ PageStrings.swift) ----------

def collect_pagestrings_keys():
    s = (SOURCES / "Rendering" / "PageStrings.swift").read_text(encoding="utf-8")
    body = s.split("static let keys", 1)[1]
    return set(lit[1:-1].replace('\\"', '"').replace("\\\\", "\\")
               for lit in re.findall(STRING_LIT, body))


def collect_js_keys():
    s = (SOURCES / "Resources" / "app.js").read_text(encoding="utf-8")

    def balanced(text, start):
        depth = 0
        for i in range(start, len(text)):
            c = text[i]
            if c == "(":
                depth += 1
            elif c == ")":
                if depth == 0:
                    return text[start:i]
                depth -= 1
        return text[start:]

    keys = set()
    for m in re.finditer(r"pm(?:String|Format)\(", s):
        if s[max(0, m.start() - 9):m.start()].endswith("function "):
            continue
        arg = balanced(s, m.end())
        depth, first = 0, arg
        for i, c in enumerate(arg):
            if c in "([{":
                depth += 1
            elif c in ")]}":
                depth -= 1
            elif c == "," and depth == 0:
                first = arg[:i]
                break
        for lit in re.findall(r'"((?:[^"\\]|\\.)+)"', first):
            keys.add(lit.replace('\\"', '"').replace("\\'", "'"))
    return keys


# ---------- .strings parsing ----------

def parse_strings(path):
    """Minimal Localizable.strings parser: "key" = "value"; with
    escaped quotes, // and /* */ comments."""
    s = path.read_text(encoding="utf-8")
    s = re.sub(r"/\*.*?\*/", "", s, flags=re.S)
    s = re.sub(r"^\s*//.*$", "", s, flags=re.M)
    entries = {}
    for m in re.finditer(
            r'"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', s):
        key = m.group(1).replace('\\"', '"').replace("\\n", "\n").replace("\\\\", "\\")
        value = m.group(2).replace('\\"', '"').replace("\\n", "\n").replace("\\\\", "\\")
        if key in entries:
            problem(f"{path.name}: duplicate key {key!r}")
        entries[key] = value
    return entries


SPEC = re.compile(r"%(?:\d+\$)?[@dDuUxXoOfeEgGcCsSpaAF]|%lld|%llu|%ld|%lu")


def specifiers(text):
    return sorted(SPEC.findall(text.replace("%%", "")))


def main():
    write_inventory = "--write-inventory" in sys.argv

    swift_keys, interpolated = collect_swift_keys()
    page_keys = collect_pagestrings_keys()
    js_keys = collect_js_keys()

    # app.js ↔ PageStrings consistency
    for key in sorted(js_keys - page_keys):
        problem(f"PageStrings.keys missing app.js key: {key!r}")
    for key in sorted(page_keys - js_keys):
        problem(f"PageStrings.keys has orphan (no app.js use): {key!r}")

    inventory = dict(sorted(swift_keys.items()))
    for key in sorted(page_keys):
        inventory.setdefault(key, "Sources/PullMark/Rendering/PageStrings.swift")

    if write_inventory:
        LOC.mkdir(exist_ok=True)
        (LOC / "_inventory.json").write_text(
            json.dumps(inventory, ensure_ascii=False, indent=1) + "\n",
            encoding="utf-8")
        print(f"inventory: {len(inventory)} keys → loc/_inventory.json"
              f" ({len(interpolated)} interpolated, flagged in-file)")

    lprojs = sorted(LOC.glob("*.lproj")) if LOC.exists() else []
    for lproj in lprojs:
        strings_path = lproj / "Localizable.strings"
        if not strings_path.exists():
            problem(f"{lproj.name}: Localizable.strings missing")
            continue
        entries = parse_strings(strings_path)
        missing = set(inventory) - set(entries)
        orphans = set(entries) - set(inventory)
        for key in sorted(missing):
            problem(f"{lproj.name}: missing {key!r}")
        for key in sorted(orphans):
            problem(f"{lproj.name}: orphan {key!r}")
        for key, value in sorted(entries.items()):
            if key in inventory and specifiers(key) != specifiers(value):
                problem(f"{lproj.name}: format specifiers differ for {key!r}: "
                        f"{specifiers(key)} vs {specifiers(value)}")

    if problems:
        print("\n".join(problems))
        print(f"\n{len(problems)} problem(s).")
        return 1
    locales = ", ".join(p.name.removesuffix(".lproj") for p in lprojs) or "none yet"
    print(f"strings OK: {len(inventory)} keys; locales checked: {locales}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
