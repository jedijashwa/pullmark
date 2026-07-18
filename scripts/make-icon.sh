#!/bin/bash
# Regenerates assets/AppIcon.icns from assets/icon.svg.
# Dev-time only (needs Chrome for SVG rasterization); the generated .icns is
# committed so normal builds don't require this.
set -euo pipefail
cd "$(dirname "$0")/.."

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/icon.html" <<EOF
<!DOCTYPE html>
<html><head><style>html,body{margin:0;padding:0;background:transparent}</style></head>
<body>$(cat assets/icon.svg)</body></html>
EOF

"$CHROME" --headless --disable-gpu --default-background-color=00000000 \
  --window-size=1024,1024 --screenshot="$WORK/icon_1024.png" \
  "file://$WORK/icon.html" 2>/dev/null

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
cp "$WORK/icon_1024.png" "$ICONSET/icon_512x512@2x.png"
for size in 16 32 128 256 512; do
  sips -z $size $size "$WORK/icon_1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$WORK/icon_1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o assets/AppIcon.icns
echo "Wrote assets/AppIcon.icns"
