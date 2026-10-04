#!/usr/bin/env bash
# Renders scripted scenes with the real simulation to preview/ (PNG stills, contact sheets and
# GIFs), without a watch or a simulator. Also regenerates the app icon and benchmarks the engine.
#
# Usage: scripts/preview.sh [scene] [--palette id] [--grain px]
#   scenes: all (default), pour, tilt, shake, carve, hourglass, palettes, bench, icon
#   palettes: sahara, coral, volcanic, gypsum, art
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

SCENE="${1:-all}"
[ $# -gt 0 ] && shift
cd Packages/HourGlassCore
if [ "$SCENE" = "icon" ]; then
  swift run -c release sandpreview icon --out "$ROOT/App/Assets.xcassets/AppIcon.appiconset" "$@"
else
  swift run -c release sandpreview "$SCENE" --out "$ROOT/preview" "$@"
fi
