#!/bin/bash
# Regression test for the JS rendering pipeline: renders docs/kitchen-sink.md
# through the real page template + vendored assets in headless Chrome, then
# asserts that every GFM construct produced the expected DOM. Skips (success)
# when Chrome is not installed.
set -euo pipefail
cd "$(dirname "$0")/.."

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if [ ! -x "$CHROME" ]; then
  for candidate in "$HOME/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
                   "/Applications/Chromium.app/Contents/MacOS/Chromium"; do
    if [ -x "$candidate" ]; then CHROME="$candidate"; break; fi
  done
fi
if [ ! -x "$CHROME" ]; then
  echo "render-check: Chrome not found, skipping"
  exit 0
fi

RES="Sources/PullMark/Resources"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cp -R "$RES/vendor" "$RES/app.js" "$RES/app.css" "$WORK/"

MARKDOWN_JSON=$(jq -Rs . < docs/kitchen-sink.md)
cat > "$WORK/page.html" <<EOF
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>render-check</title>
<link rel="stylesheet" href="vendor/github-markdown.css">
<link rel="stylesheet" href="app.css">
</head>
<body>
<article id="content" class="markdown-body"></article>
<script>window.__PAYLOAD__ = {"mode":"document","markdown":${MARKDOWN_JSON}};</script>
<script src="vendor/marked.min.js"></script>
<script src="vendor/marked-alert.min.js"></script>
<script src="vendor/marked-footnote.min.js"></script>
<script src="vendor/highlight.min.js"></script>
<script src="vendor/mermaid.min.js"></script>
<script src="app.js"></script>
</body>
</html>
EOF

DOM="$WORK/dom.html"
"$CHROME" --headless --disable-gpu --virtual-time-budget=8000 \
  --dump-dom "file://$WORK/page.html" > "$DOM" 2>/dev/null

failures=0
check() {
  local label="$1" pattern="$2"
  if grep -qE "$pattern" "$DOM"; then
    echo "  ok: $label"
  else
    echo "FAIL: $label (pattern: $pattern)"
    failures=$((failures + 1))
  fi
}

check "bold"                 "<strong>Bold</strong>"
check "italic"               "<em>italic</em>"
check "strikethrough"        "<del>strikethrough</del>"
check "inline code"          "<code>inline code</code>"
check "link"                 '<a href="https://example.com">link</a>'
check "autolink"             '<a href="https://example.com/auto">'
check "ordered list"         "<ol>"
check "ordered list start"   '<ol start="5">'
check "nested list"          "<li>Nested ordered"
check "unordered list"       "<ul>"
check "task checkbox"        'type="checkbox"'
check "blockquote"           "<blockquote>"
check "table"                "<table>"
check "table alignment"      'align="right"|text-align: ?right'
check "code block highlight" 'hljs-(keyword|title|function)'
check "horizontal rule"      "<hr>"
check "mermaid svg"          '<svg[^>]*(id="mermaid|aria-roledescription="pie)'
check "alert"                "markdown-alert-tip"
check "footnote"             'footnote|data-footnote'
check "heading anchor id"    'id="gfm-kitchen-sink"'

if [ "$failures" -gt 0 ]; then
  echo "render-check: $failures failure(s)"
  exit 1
fi
echo "render-check: all constructs rendered"
