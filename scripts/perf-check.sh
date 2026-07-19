#!/bin/bash
# Stress test for the rendering pipeline: renders extreme Markdown through
# the real page template (marked + hljs + mermaid + KaTeX + app.js) in
# headless Chrome and reports timing. Corpus is script-generated pathological
# files plus real-world giants downloaded once into a cache — nothing is
# committed to the repo.
#
#   ./scripts/perf-check.sh            # run everything available
#   SKIP_DOWNLOADS=1 ./scripts/perf-check.sh   # offline: generated files only
#
# Reported per file: bytes, in-page render time (performance.now() at the
# second animation frame after window load — parse, DOM build, hljs/KaTeX,
# and first layout), and total headless-Chrome wall time. This is a smoke
# check, not a benchmark: look for order-of-magnitude problems, not noise.
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
  echo "perf-check: Chrome not found, skipping"
  exit 0
fi

CACHE="${TMPDIR:-/tmp}/pullmark-perf"
mkdir -p "$CACHE"
RES="Sources/PullMark/Resources"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cp -R "$RES/vendor" "$RES/app.js" "$RES/app.css" "$RES/pm-extensions.js" "$WORK/"

# Local probe script — allowed by script-src 'self', same as the app's own.
# Executes synchronously right after app.js, so PM_SYNC is the main-thread
# time for parse + DOM build (the freeze a user would feel). PM_LOAD adds
# async completion (fonts, images, first frames); under virtual-time
# emulation it can be inflated or absent — treat it as a rough signal only.
cat > "$WORK/perf-probe.js" <<'EOF'
(function () {
  var sync = Math.round(performance.now());
  var stamp = document.createElement('div');
  stamp.id = 'pm-perf';
  stamp.textContent = 'PM_SYNC_MS:' + sync;
  document.body.appendChild(stamp);
  window.addEventListener('load', function () {
    requestAnimationFrame(function () { requestAnimationFrame(function () {
      stamp.textContent += ' PM_LOAD_MS:' + Math.round(performance.now());
    }); });
  });
})();
EOF

CSP="default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src file: data: https: pullmark-local: pullmark-remote:; font-src 'self'; connect-src 'none'; frame-src 'none'; object-src 'none'"
emit_page() {
  # "<" is <-escaped via sed — bash's ${var//} replacement is
  # catastrophically slow on large strings with many matches.
  local markdown_json="$1" out="$2"
  cat > "$out" <<EOF
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="${CSP}">
<title>perf-check</title>
<link rel="stylesheet" href="vendor/github-markdown.css">
<link rel="stylesheet" href="vendor/katex/katex.min.css">
<link rel="stylesheet" href="app.css">
</head>
<body>
<article id="content" class="markdown-body"></article>
<script type="application/json" id="pm-payload">{"mode":"document","markdown":${markdown_json}}</script>
<script src="vendor/marked.min.js"></script>
<script src="vendor/marked-alert.min.js"></script>
<script src="vendor/marked-footnote.min.js"></script>
<script src="vendor/highlight.min.js"></script>
<script src="vendor/mermaid.min.js"></script>
<script src="vendor/katex/katex.min.js"></script>
<script src="pm-extensions.js"></script>
<script src="app.js"></script>
<script src="perf-probe.js"></script>
</body>
</html>
EOF
}

# ---- Generated pathological files (cheap, deterministic).
python3 - "$CACHE" <<'EOF'
import os, sys
cache = sys.argv[1]

def write(name, content):
    path = os.path.join(cache, name)
    if not os.path.exists(path):
        with open(path, "w") as f:
            f.write(content)

write("gen-paragraphs.md", "# Ten thousand paragraphs\n\n" + "\n\n".join(
    f"Paragraph {i} with some **bold**, *italic*, `code`, and a [link](https://example.com/{i})."
    for i in range(10_000)))

rows = "\n".join("| " + " | ".join(f"r{r}c{c}" for c in range(8)) + " |" for r in range(5_000))
write("gen-table.md", "# One giant table\n\n"
      + "| " + " | ".join(f"col{c}" for c in range(8)) + " |\n"
      + "|" + "---|" * 8 + "\n" + rows + "\n")

fence = "\n".join(f"function f{i}(x) {{ return x * {i} + 'str'; }}" for i in range(25))
write("gen-fences.md", "# Four hundred code fences\n\n" + "\n\n".join(
    f"```js\n{fence}\n```" for _ in range(400)))

write("gen-headings.md", "[toc]\n\n" + "\n\n".join(
    f"{'#' * (2 + i % 4)} Section {i}\n\nBody text for section {i}."
    for i in range(2_000)))

write("gen-one-line.md", "# One megabyte, one paragraph\n\n"
      + " ".join(f"word{i}" for i in range(150_000)) + "\n")
EOF

# ---- Real-world giants (cached; skipped offline).
if [ -z "${SKIP_DOWNLOADS:-}" ]; then
  fetch() {
    [ -s "$CACHE/$1" ] || curl -fsSL --max-time 60 -o "$CACHE/$1" "$2" \
      || { echo "  (download failed: $1 — skipping)"; rm -f "$CACHE/$1"; }
  }
  fetch "real-commonmark-spec.md" \
    "https://raw.githubusercontent.com/commonmark/commonmark-spec/master/spec.txt"
  fetch "real-free-programming-books.md" \
    "https://raw.githubusercontent.com/EbookFoundation/free-programming-books/main/books/free-programming-books-langs.md"
fi

echo "file                              bytes      sync(ms)  load(ms)  wall(s)"
for md in "$CACHE"/*.md; do
  name=$(basename "$md")
  bytes=$(wc -c < "$md" | tr -d ' ')
  emit_page "$(jq -Rs . < "$md" | sed 's/</\\u003c/g')" "$WORK/page.html"
  start=$(python3 -c 'import time; print(time.time())')
  "$CHROME" --headless --disable-gpu --virtual-time-budget=30000 \
    --dump-dom "file://$WORK/page.html" > "$WORK/dom.html" 2>/dev/null || true
  end=$(python3 -c 'import time; print(time.time())')
  wall=$(python3 -c "print(f'{$end - $start:.1f}')")
  sync=$(grep -oE 'PM_SYNC_MS:[0-9]+' "$WORK/dom.html" | head -1 | cut -d: -f2 || true)
  load=$(grep -oE 'PM_LOAD_MS:[0-9]+' "$WORK/dom.html" | head -1 | cut -d: -f2 || true)
  printf "%-33s %-10s %-9s %-9s %s\n" "$name" "$bytes" "${sync:-?}" "${load:-—}" "$wall"
done
