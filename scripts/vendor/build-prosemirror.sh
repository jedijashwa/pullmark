#!/bin/bash
# Rebuilds Sources/PullMark/Resources/vendor/prosemirror.min.js — the rich
# editor's engine (spec: rich-editor §2) — as ONE minified IIFE exposing a
# `PM` global: prosemirror-{model,state,view,transform,history,keymap,
# commands,inputrules,schema-list,tables,markdown} plus markdown-it.
# Needs node + npm; works in a scratch directory and copies the result in.
#
#   ./scripts/vendor/build-prosemirror.sh            # pinned versions below
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="$PWD/Sources/PullMark/Resources/vendor/prosemirror.min.js"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cp scripts/vendor/prosemirror-entry.js "$WORK/index.js"
cd "$WORK"
npm init -y >/dev/null
npm install --silent --no-audit --no-fund \
  prosemirror-model@1.25.11 prosemirror-state@1.4.4 prosemirror-view@1.42.3 \
  prosemirror-transform@1.12.1 prosemirror-history@1.5.0 prosemirror-keymap@1.2.3 \
  prosemirror-commands@1.7.2 prosemirror-inputrules@1.5.1 prosemirror-schema-list@1.5.1 \
  prosemirror-tables@1.8.5 prosemirror-markdown@1.13.7 markdown-it@15.0.1 esbuild
npx esbuild index.js --bundle --format=iife --global-name=PM --minify --outfile=prosemirror.min.js
# The page's CSP forbids eval; the bundle must never need it.
if grep -q -E 'new Function\(|[^a-zA-Z_.]eval\(' prosemirror.min.js; then
  echo "error: bundle contains eval-like code" >&2; exit 1
fi
cp prosemirror.min.js "$OUT"
echo "Vendored $(wc -c < "$OUT") bytes to $OUT"
