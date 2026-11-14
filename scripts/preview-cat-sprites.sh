#!/bin/zsh
# Draws the rainbow cat's running and braking frames into one enlarged
# image, without building the app.
#   scripts/preview-cat-sprites.sh [output.png] [zoom]
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-$root/build/cat-sprites.png}"
mkdir -p "$root/build" "$(dirname "$out")"
swiftc -O \
  "$root"/boringNotch/components/LiveActivities/RainbowCat/PixelCatSprites*.swift \
  "$root/scripts/cat-sprite-preview/main.swift" \
  -o "$root/build/cat-sprite-preview"
"$root/build/cat-sprite-preview" "$out" "${2:-8}"
[[ -z "${NO_OPEN:-}" ]] && open "$out"
