#!/usr/bin/env python3
"""Site localization verifier (spec: site-localization).

Run before any site deploy. Translated variants fail silently — a
missing page 404s, a wrong lang attribute renders wrong CJK glyphs —
so every invariant the localized site depends on is asserted here:

  * every locale directory carries all scoped pages
  * every variant declares the right <html lang>, its own canonical,
    the full hreflang matrix, the switcher (aria-current on itself),
    and the i18n.css/i18n.js includes
  * locale pages reference shared assets absolutely (no ../ or bare
    relative src/href that would resolve inside the locale dir)
  * sitemap.xml covers exactly the shipped URL set

Exit code 0 = clean; 1 = problems (each printed on its own line).
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent / "site"
ORIGIN = "https://pullmark.app"

# locale code -> path prefix; English is the root.
LOCALES = {"zh-Hans": "zh", "ja": "ja", "fr": "fr", "de": "de",
           "nl": "nl", "es": "es", "pt-BR": "pt"}

# Base (English) paths of every localized page.
BASES = [
    "/",
    "/uses/agents/",
    "/docs/",
    "/docs/features/",
    "/docs/sidebar/",
    "/docs/toolbar/",
    "/docs/settings/",
    "/docs/shortcuts/",
    "/docs/cli/",
    "/docs/troubleshooting/",
    "/docs/experimental/",
    "/docs/experimental/margin-notes/",
]

# English-only pages that still appear in the sitemap.
UNSCOPED = ["/privacy/", "/licenses/"]

problems = []


def problem(msg):
    problems.append(msg)


def page_file(url_path):
    return ROOT / url_path.strip("/") / "index.html" if url_path != "/" \
        else ROOT / "index.html"


def variant_url(code, base):
    return ORIGIN + base if code == "en" else f"{ORIGIN}/{LOCALES[code]}{base}"


def check_page(code, base):
    url = variant_url(code, base)
    rel = url.replace(ORIGIN, "") or "/"
    path = page_file(rel)
    if not path.exists():
        problem(f"MISSING PAGE: {rel} ({path})")
        return
    s = path.read_text(encoding="utf-8")

    want_lang = "en" if code == "en" else code
    m = re.search(r'<html\s+lang="([^"]+)"', s)
    if not m or m.group(1) != want_lang:
        problem(f"{rel}: lang is {m.group(1) if m else 'missing'}, want {want_lang}")

    if f'<link rel="canonical" href="{url}">' not in s:
        problem(f"{rel}: canonical missing or not {url}")

    for other in ["en", *LOCALES]:
        href = variant_url(other, base)
        tag = f'hreflang="{other}" href="{href}"'
        if tag not in s:
            problem(f"{rel}: hreflang {other} missing or wrong (want {href})")
    if f'hreflang="x-default" href="{ORIGIN}{base}"' not in s:
        problem(f"{rel}: x-default missing or wrong")

    if '<link rel="stylesheet" href="/i18n.css">' not in s:
        problem(f"{rel}: i18n.css include missing")
    if '<script src="/i18n.js" defer></script>' not in s:
        problem(f"{rel}: i18n.js include missing")

    if 'class="lang-switch"' not in s:
        problem(f"{rel}: language switcher missing")
    else:
        cur = re.search(r'<a href="[^"]*" hreflang="([^"]+)"[^>]*aria-current="true"', s)
        if not cur or cur.group(1) != want_lang:
            problem(f"{rel}: switcher aria-current is "
                    f"{cur.group(1) if cur else 'missing'}, want {want_lang}")

    if code != "en":
        # Locale pages must not fetch assets relative to the locale dir.
        for attr, value in re.findall(r'(src|href)="([^"]+)"', s):
            # Any URL with a scheme is absolute (https:, mailto:, data:,
            # pullmark:// deep links in the docs, …), as is any
            # root-relative path or fragment.
            if value.startswith(("/", "#")) or re.match(r"[a-z][a-z0-9+.\-]*:", value):
                continue
            problem(f"{rel}: relative {attr}=\"{value}\" (must be absolute)")


def check_sitemap():
    path = ROOT / "sitemap.xml"
    if not path.exists():
        problem("sitemap.xml missing")
        return
    s = path.read_text(encoding="utf-8")
    listed = set(re.findall(r"<loc>([^<]+)</loc>", s))
    expected = {variant_url(code, base) for base in BASES for code in ["en", *LOCALES]}
    expected |= {ORIGIN + p for p in UNSCOPED}
    for url in sorted(expected - listed):
        problem(f"sitemap: missing {url}")
    for url in sorted(listed - expected):
        problem(f"sitemap: unexpected {url}")


def main():
    for base in BASES:
        for code in ["en", *LOCALES]:
            check_page(code, base)
    check_sitemap()
    if problems:
        print("\n".join(problems))
        print(f"\n{len(problems)} problem(s).")
        return 1
    total = len(BASES) * (len(LOCALES) + 1)
    print(f"site i18n OK: {total} pages verified, sitemap consistent.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
