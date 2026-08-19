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
cp -R "$RES/vendor" "$RES/app.js" "$RES/app.css" "$RES/pm-extensions.js" "$WORK/"

# Mirrors HTMLBuilder.page: CSP meta + non-executing JSON payload (#5).
CSP="default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src file: data: https: pullmark-local: pullmark-remote:; font-src 'self'; connect-src 'none'; frame-src 'none'; object-src 'none'"
emit_page() {
  # "<" is <-escaped inside the JSON like HTMLBuilder.jsonLiteral, so
  # content can never close the payload tag or confuse the HTML parser.
  local markdown_json="${1//</\\u003c}" out="$2" extra="${3:-}"
  cat > "$out" <<EOF
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="${CSP}">
<title>render-check</title>
<link rel="stylesheet" href="vendor/github-markdown.css">
<link rel="stylesheet" href="vendor/katex/katex.min.css">
<link rel="stylesheet" href="app.css">
</head>
<body>
<article id="content" class="markdown-body"></article>
<script type="application/json" id="pm-payload">{"mode":"document","markdown":${markdown_json}${extra}}</script>
<script src="vendor/marked.min.js"></script>
<script src="vendor/marked-alert.min.js"></script>
<script src="vendor/marked-footnote.min.js"></script>
<script src="vendor/highlight.min.js"></script>
<script src="vendor/mermaid.min.js"></script>
<script src="vendor/katex/katex.min.js"></script>
<script src="pm-extensions.js"></script>
<script src="app.js"></script>
</body>
</html>
EOF
}

emit_page "$(jq -Rs . < docs/kitchen-sink.md)" "$WORK/page.html"

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
check "ordered list"         "<ol[ >]"
check "ordered list start"   '<ol start="5"'
check "nested list"          "<li[^>]*>Nested ordered"
check "unordered list"       "<ul[ >]"
check "item sub-unit stamp"  '<li data-pm-sublines="[0-9]+-[0-9]+"'
check "row sub-unit stamp"   '<tr data-pm-sublines="[0-9]+-[0-9]+"'
check "task checkbox"        'type="checkbox"'
check "blockquote"           "<blockquote[ >]"
check "table"                "<table[ >]"
check "table alignment"      'align="right"|text-align: ?right'
check "code block highlight" 'hljs-(keyword|title|function)'
check "horizontal rule"      "<hr[ >]"
check "mermaid svg"          '<svg[^>]*(id="mermaid|aria-roledescription="pie)'
check "alert"                "markdown-alert-tip"
check "footnote"             'footnote|data-footnote'
check "heading anchor id"    'id="gfm-kitchen-sink"'
check "front matter details" '<details class="pm-frontmatter"[^>]*><summary>Front matter</summary>'
check "front matter row"     '<th>title</th><td>GFM kitchen sink</td>'
check "front matter nested"  '<pre>  - markdown</pre>'
check "inline math (katex)"  'class="katex"'
check "display math"         'class="katex-display"'
check "currency untouched"   '\$5 today and \$10 tomorrow'
check "math skips code span" '<code>\$x\$</code>'
check "math skips fences"    '\$\$ not math inside a fence \$\$'
check "highlight"            '<mark>Highlighted</mark>'
check "subscript"            'H<sub>2</sub>O'
check "superscript"          'mc<sup>2</sup>'
check "tilde strikethrough"  '<del>strikethrough still works</del>'
check "toc list"             '<nav class="pm-toc"[^>]*><ul class="pm-toc-list">'
check "toc links headings"   '<a href="#math">Math</a>'
check "block line annotations" 'data-pm-lines="[0-9]+-[0-9]+"'

# ---- Sub-unit stamps: exact line math on the documents that broke the
# nested-list scan in review — two sibling nested lists whose first item
# text repeats, and a fenced fake list ahead of the real nested one.
# Line numbers here are fixed by this fixture; if you edit it, re-derive.
NESTED_FIXTURE='- wrapper
  - alpha
  - beta

  interlude

  - beta
  - gamma
- fency
  ```
  - fake
  ```
  - real'
emit_page "$(printf '%s' "$NESTED_FIXTURE" | jq -Rs .)" "$WORK/nested.html"
NESTED_DOM="$WORK/nested-dom.html"
"$CHROME" --headless --disable-gpu --virtual-time-budget=8000 \
  --dump-dom "file://$WORK/nested.html" > "$NESTED_DOM" 2>/dev/null
nested_check() {
  local label="$1" pattern="$2"
  if grep -qE "$pattern" "$NESTED_DOM"; then
    echo "  ok: $label"
  else
    echo "FAIL: $label (pattern: $pattern)"
    failures=$((failures + 1))
  fi
}
nested_check "wrapper item spans its subtree"   'data-pm-sublines="1-8"'
nested_check "first beta stamps line 3"         'data-pm-sublines="3-3"'
nested_check "second beta stamps line 7"        'data-pm-sublines="7-7"'
nested_check "gamma stamps line 8"              'data-pm-sublines="8-8"'
nested_check "real nested item skips the fence" 'data-pm-sublines="13-13"'
if grep -qE 'data-pm-sublines="(4-4|10-|11-|12-)' "$NESTED_DOM"; then
  echo "FAIL: a sub-unit stamped a blank or fenced line"
  failures=$((failures + 1))
else
  echo "  ok: no stamp on blank or fenced lines"
fi

# ---- Review discussion (spec: pr-review-discussion): the overview's
# thread list renders grouped by file with hunk excerpts and routing
# actions; resolved threads arrive collapsed.
DISCUSSION_PAYLOAD=',"discussion":[
 {"path":"docs/guide.md","isMarkdown":true,"unresolvedCount":2,"threads":[
  {"lineLabel":"Line 9 (new)","rootID":41,"resolved":false,"outdated":false,
   "language":"markdown","htmlUrl":null,
   "excerpt":[{"text":"- second point","kind":"add"}],
   "comments":[{"author":"reviewer","dateLabel":"Aug 13, 2026","body":"Tighten this?"}]},
  {"lineLabel":"Line 14 (new)","rootID":44,"resolved":false,"outdated":false,
   "language":"markdown","htmlUrl":null,
   "excerpt":[{"text":"| old row | 1 |","kind":"ctx"},{"text":"| new row | 2 |","kind":"add"}],
   "comments":[{"author":"reviewer","dateLabel":"Aug 13, 2026","body":"Row check?"}]}]},
 {"path":"src/main.cpp","isMarkdown":false,"unresolvedCount":1,"threads":[
  {"lineLabel":"Line 42 (new)","rootID":42,"resolved":false,"outdated":false,
   "language":"cpp","htmlUrl":"https://github.com/o/r/pull/1#discussion_r42",
   "excerpt":[{"text":"if (now - last < DEBOUNCE_US) {","kind":"add"},{"text":"    return;","kind":"ctx"}],
   "comments":[{"author":"reviewer","dateLabel":"Aug 13, 2026","body":"Too aggressive?"}]},
  {"lineLabel":"Line 7 (new)","rootID":43,"resolved":true,"outdated":false,
   "language":"cpp","htmlUrl":"https://github.com/o/r/pull/1#discussion_r43",
   "excerpt":[{"text":"int x = 1;","kind":"ctx"}],
   "comments":[{"author":"author","dateLabel":"Aug 12, 2026","body":"Done."}]}]}]'
emit_page "$(jq -Rs . <<< 'The PR description body.')" "$WORK/discussion.html" "$DISCUSSION_PAYLOAD"
DISCUSSION_DOM="$WORK/discussion-dom.html"
"$CHROME" --headless --disable-gpu --virtual-time-budget=8000 \
  --dump-dom "file://$WORK/discussion.html" > "$DISCUSSION_DOM" 2>/dev/null
discussion_check() {
  local label="$1" pattern="$2"
  if grep -qE "$pattern" "$DISCUSSION_DOM"; then
    echo "  ok: $label"
  else
    echo "FAIL: $label (pattern: $pattern)"
    failures=$((failures + 1))
  fi
}
discussion_check "discussion section"      '<section class="pm-discussion'
discussion_check "unresolved headline"     '3 unresolved conversations'
discussion_check "file group path"         '<span class="pm-discussion-path">src/main.cpp</span>'
discussion_check "markdown rich preview"   '<div class="pm-discussion-preview"><div class="pm-preview-add"><ul>'
discussion_check "table preview joins rows" '<tr class="pm-preview-row-add">'
discussion_check "table preview renders cells" '<td>new row</td>'
discussion_check "table preview hides synthesized header" 'pm-discussion-preview pm-preview-headless'
discussion_check "markdown jump action"    '>View in File</button>'
discussion_check "github routing action"   '>Show on GitHub</button>'
discussion_check "hunk add line"           'pm-hunk-line pm-hunk-add'
discussion_check "hunk highlighted code"   'pm-hunk-line[^>]*><span class="pm-hunk-marker">[^<]*</span><code class="language-cpp hljs'
discussion_check "resolved arrives collapsed" 'pm-thread-resolved pm-thread-collapsed'
discussion_check "thread card root id"     'data-pm-root="42"'
if grep -qE 'pm-discussion' "$DOM"; then
  echo "FAIL: discussion section leaked into the plain document page"
  failures=$((failures + 1))
else
  echo "  ok: discussion absent by default"
fi

# ---- Conversation timeline (spec: pr-cockpit): comments interleaved
# with review verdicts, verdict line owning author+date, bot tags, and
# the always-present section-foot composer.
CONVERSATION_PAYLOAD=',"conversationComposer":true,"conversation":[
 {"kind":"comment","card":{"author":"sam-ortega","dateLabel":"Aug 18, 2026",
   "body":"Ready for a look.","id":314,"edited":false,"viewerOwned":true,
   "canReact":true,"bot":false,"reactions":[{"content":"+1","count":2,"mine":true}]}},
 {"kind":"changes_requested","card":{"author":"riley-chen","dateLabel":"Aug 19, 2026",
   "body":"The install section needs a pass.","id":9,"edited":false,
   "viewerOwned":false,"canReact":true,"bot":false,"reactions":[]}},
 {"kind":"approved","card":{"author":"riley-chen","dateLabel":"Aug 19, 2026",
   "body":"","id":10,"edited":false,"viewerOwned":false,"canReact":false,
   "bot":false,"reactions":[]}},
 {"kind":"comment","card":{"author":"docs-ci","dateLabel":"Aug 19, 2026",
   "body":"Link check passed.","id":315,"edited":false,"viewerOwned":false,
   "canReact":false,"bot":true,"reactions":[]}}]'
emit_page "$(jq -Rs . <<< 'The PR description body.')" "$WORK/conversation.html" "$CONVERSATION_PAYLOAD"
CONVERSATION_DOM="$WORK/conversation-dom.html"
"$CHROME" --headless --disable-gpu --virtual-time-budget=8000 \
  --dump-dom "file://$WORK/conversation.html" > "$CONVERSATION_DOM" 2>/dev/null
conversation_check() {
  local label="$1" pattern="$2"
  if grep -qE "$pattern" "$CONVERSATION_DOM"; then
    echo "  ok: $label"
  else
    echo "FAIL: $label (pattern: $pattern)"
    failures=$((failures + 1))
  fi
}
conversation_check "conversation section"    '<section class="pm-conversation pm-annotation">'
conversation_check "entry count headline"    '4 entries'
conversation_check "comment card body"       'Ready for a look\.'
conversation_check "verdict line with date"  'riley-chen requested changes · Aug 19, 2026'
conversation_check "verdict summary body"    'The install section needs a pass\.'
conversation_check "approved headline"       'riley-chen approved these changes'
conversation_check "bot tag"                 '<span class="pm-bot-tag">bot</span>'
conversation_check "reaction chip"           'data-pm-comment="314"'
conversation_check "foot composer"           'pm-conversation-composer'
conversation_check "composer placeholder"    'Comment on the pull request conversation'
# Bounded to the card: the DOM is one long line, so the window is cut
# at the next card's opening class before asserting — an unanchored .*
# (or a fixed-width window) spans into the following card's body and
# false-positives.
if grep -oE 'pm-verdict-approved.{0,400}' "$CONVERSATION_DOM" \
    | sed 's/pm-conversation-card.*//' | grep -q 'pm-thread-comment'; then
  echo "FAIL: empty approved verdict rendered a comment card"
  failures=$((failures + 1))
else
  echo "  ok: empty verdict renders headline only"
fi
if grep -qE 'pm-conversation' "$DOM"; then
  echo "FAIL: conversation section leaked into the plain document page"
  failures=$((failures + 1))
else
  echo "  ok: conversation absent by default"
fi

# ---- Line numbers: gutter labels build only when the payload carries the
# preference; the default page above must stay label-free.
emit_page "$(jq -Rs . < docs/kitchen-sink.md)" "$WORK/linenum.html" ',"lineNumbers":true'
LINENUM_DOM="$WORK/linenum-dom.html"
"$CHROME" --headless --disable-gpu --virtual-time-budget=8000 \
  --dump-dom "file://$WORK/linenum.html" > "$LINENUM_DOM" 2>/dev/null

linenum_check() {
  local label="$1" pattern="$2"
  if grep -qE "$pattern" "$LINENUM_DOM"; then
    echo "  ok: $label"
  else
    echo "FAIL: $label (pattern: $pattern)"
    failures=$((failures + 1))
  fi
}
linenum_check "line-number root class" '<html class="[^"]*pm-line-numbers'
linenum_check "line-number layer"      'class="pm-linenum-layer"'
linenum_check "line-number label"      '<span class="pm-linenum" title="Line'
if grep -qE 'class="pm-linenum"' "$DOM"; then
  echo "FAIL: line-number labels leaked into the default page"
  failures=$((failures + 1))
else
  echo "  ok: line numbers absent by default"
fi

# ---- Hostile markdown: script injection must be inert under the CSP (#5).
cat > "$WORK/hostile.md" <<'EOF'
# Hostile

<script>document.title='pwned'</script>

<img src=x onerror="document.title='pwned'">

[malicious link](javascript:document.title='pwned')

Hostile math: $\href{javascript:document.title='pwned'}{click}$ stays inert.

Safe **bold** text survives.
EOF

emit_page "$(jq -Rs . < "$WORK/hostile.md")" "$WORK/hostile.html"
HOSTILE_DOM="$WORK/hostile-dom.html"
"$CHROME" --headless --disable-gpu --virtual-time-budget=8000 \
  --dump-dom "file://$WORK/hostile.html" > "$HOSTILE_DOM" 2>/dev/null

hostile_check() {
  local label="$1" pattern="$2" invert="${3:-}"
  if [ "$invert" = "absent" ]; then
    if grep -qE "$pattern" "$HOSTILE_DOM"; then
      echo "FAIL: $label (found: $pattern)"
      failures=$((failures + 1))
    else
      echo "  ok: $label"
    fi
  elif grep -qE "$pattern" "$HOSTILE_DOM"; then
    echo "  ok: $label"
  else
    echo "FAIL: $label (pattern: $pattern)"
    failures=$((failures + 1))
  fi
}

hostile_check "title untouched by injected script" "<title>render-check</title>"
hostile_check "no script executed"                 "<title>pwned</title>" absent
hostile_check "benign markdown still renders"      "<strong>bold</strong>"
hostile_check "csp meta present"                   'http-equiv="Content-Security-Policy"'
# The \href must not become an anchor (KaTeX's default trust=false renders
# it as red error text); the plain-markdown javascript: link above the math
# line still exists as inert markup, so match the math link's text.
hostile_check "katex refuses untrusted \\href"     '>click</a>' absent
hostile_check "hostile math still rendered inert"  'class="katex"'

if [ "$failures" -gt 0 ]; then
  echo "render-check: $failures failure(s)"
  exit 1
fi
echo "render-check: all constructs rendered, hostile markdown inert"
