#!/bin/sh
# Draws the window's app icon and writes AppIcon.icns beside this script.
#
# The source is the repo's own nullclaw.png, so the window wears the same mark
# as the project rather than a second one drawn by hand.
#
#   sh macos/make-icon.sh
#
# Needs macOS's sips and iconutil. `pngquant` is used when it is installed
# (Homebrew's, or not at all): the source is a detailed picture, and quantizing
# each size takes the .icns from about 1.5 MB to about 150 KB.
set -eu
cd "$(dirname "$0")/.."

src=../nullclaw.png
[ -f "$src" ] || { echo "no $src to draw the icon from" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
iconset="$tmp/AppIcon.iconset"
mkdir -p "$iconset"

# Apple's icon grid: 16, 32, 128, 256 and 512 points, each at 1x and 2x.
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$src" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$src" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done

if command -v pngquant >/dev/null 2>&1; then
  for png in "$iconset"/*.png; do
    pngquant --force --quality=70-95 --output "$png" --skip-if-larger "$png" 2>/dev/null || true
  done
fi

iconutil -c icns "$iconset" -o macos/AppIcon.icns
echo "wrote macos/AppIcon.icns"
