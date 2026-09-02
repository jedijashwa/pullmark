#!/bin/bash
# Rich-editor round-trip check (spec: rich-editor §13): every fixture in
# scripts/editor-check/fixtures must come back byte-identical through the
# editor untouched, and a scripted one-word edit must change exactly one
# line. Headless Chrome, no network, nothing committed but the fixtures.
#
#   ./scripts/editor-check.sh
set -euo pipefail
cd "$(dirname "$0")/.."
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[ -x "$CHROME" ] || { echo "editor-check: Chrome not found, skipping"; exit 0; }
RES="Sources/PullMark/Resources"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cp -R "$RES/vendor" "$RES/app.js" "$RES/app.css" "$RES/pm-extensions.js" "$RES/pm-editor.js" "$WORK/"
cp scripts/editor-check/probe.js "$WORK/probe.js"
fail=0
for fixture in scripts/editor-check/fixtures/*.md; do
  name=$(basename "$fixture" .md)
  # The Swift splitter's rules, ported: blank-line blocks, fences and HTML
  # comments atomic, leading front matter atomic, exact gaps kept.
  python3 - "$fixture" "$WORK/$name.html" <<'PY'
import sys, json, re, html
src = open(sys.argv[1], encoding="utf-8", newline="").read()
lines = src.split("\n")
blocks = []; cur = []; start = 0; fence = None; in_comment = False; first = 0
def fm_close():
    if len(lines) >= 2 and lines[0].rstrip("\r") == "---":
        for i in range(1, len(lines)):
            if lines[i].strip() == "---":
                has_key = any(re.match(r"^[A-Za-z0-9_-]+\s*:", l.rstrip("\r")) for l in lines[1:i])
                return i if has_key else None
    return None
close = fm_close()
if close is not None:
    blocks.append({"text": "\n".join(lines[0:close+1]), "start": 1, "end": close+1}); first = close + 1
def flush(last):
    global cur
    if cur:
        blocks.append({"text": "\n".join(cur), "start": start+1, "end": last+1}); cur = []
for i in range(first, len(lines)):
    line = lines[i]; t = line.strip()
    if fence:
        cur.append(line)
        if t.startswith(fence): fence = None
        continue
    if t.startswith("```") or t.startswith("~~~"):
        if not cur: start = i
        cur.append(line); fence = t[:3]; continue
    if in_comment:
        cur.append(line)
        if "-->" in line: in_comment = False
        continue
    if t.startswith("<!--") and "-->" not in line:
        if not cur: start = i
        cur.append(line); in_comment = True; continue
    if t == "": flush(i-1)
    else:
        if not cur: start = i
        cur.append(line)
flush(len(lines)-1)
if blocks:
    before = lines[0:blocks[0]["start"]-1]
    leading = ("\n".join(before) + "\n") if before else ""
    between = []
    for a, b in zip(blocks, blocks[1:]):
        blank = lines[a["end"]:b["start"]-1]
        between.append("\n" + "\n".join(blank) + ("\n" if blank else ""))
    after = lines[blocks[-1]["end"]:]
    trailing = ("\n" + "\n".join(after)) if after else ""
else:
    leading, between, trailing = src, [], ""
fm_lines = blocks[0]["end"] if close is not None else 0
payload = {"mode": "document", "markdown": src, "strings": {},
           "richEditor": {"blocks": blocks, "gaps": {"leading": leading, "between": between, "trailing": trailing},
                          "autosave": False, "frontMatterLines": fm_lines,
                          "noteAuthor": "tester", "notesVisible": True, "noteAuthoring": True}}
import os
expect_path = os.path.join(os.path.dirname(sys.argv[1]), "..", "expect.json")
expect = {}
if os.path.exists(expect_path):
    name = os.path.splitext(os.path.basename(sys.argv[1]))[0]
    expect = json.load(open(expect_path)).get(name, {})
lit = json.dumps(payload).replace("</", "<\\/")
fixture_lit = json.dumps(src).replace("</", "<\\/")
page = f"""<!doctype html><meta charset="utf-8"><title>editor-check</title>
<link rel="stylesheet" href="vendor/github-markdown.css"><link rel="stylesheet" href="app.css">
<article id="content" class="markdown-body"></article>
<script type="application/json" id="pm-payload">{lit}</script>
<script type="application/json" id="pm-fixture">{fixture_lit}</script>
<script src="vendor/marked.min.js"></script><script src="vendor/marked-alert.min.js"></script>
<script src="vendor/marked-footnote.min.js"></script><script src="vendor/highlight.min.js"></script>
<script src="vendor/mermaid.min.js"></script><script src="vendor/katex/katex.min.js"></script>
<script src="pm-extensions.js"></script><script src="app.js"></script>
<script src="vendor/prosemirror.min.js"></script><script src="pm-editor.js"></script>
<script>window.__pmFixture = JSON.parse(document.getElementById("pm-fixture").textContent); window.__pmEditWord = "emphasis"; window.__pmExpect = {json.dumps(expect)};</script>
<script src="probe.js"></script>"""
open(sys.argv[2], "w", encoding="utf-8").write(page)
PY
  # A hung page (a render that never settles) is a failure, not a stall.
  perl -e 'alarm shift; exec @ARGV' 60 "$CHROME" --headless --disable-gpu \
    --virtual-time-budget=4000 --dump-dom "file://$WORK/$name.html" 2>/dev/null > "$WORK/$name.dom" || true
  result=$(python3 -c "
import sys,re,html
dom=open(sys.argv[1],encoding='utf-8').read()
m=re.search(r'<pre id=\"out\">(.*?)</pre>', dom, re.S)
print(html.unescape(m.group(1)) if m else '{\"error\": \"no result\"}')" "$WORK/$name.dom")
  if echo "$result" | python3 -c "import sys,json; sys.exit(0 if json.load(sys.stdin).get('ok') else 1)"; then
    echo "PASS $name"
    [ -n "${VERBOSE:-}" ] && echo "     $result" | cut -c1-400
  else
    echo "FAIL $name: $result" | cut -c1-600
    fail=1
  fi
done
exit $fail
