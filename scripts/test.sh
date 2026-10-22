#!/usr/bin/env bash
# Runs the HourGlassCore package tests: the sand simulation, motion mapping and renderer.
#
# Usage: scripts/test.sh [--watch [simulator name]] [swift test options]
#   --watch     run them on the watchOS simulator instead of the Mac (default "Apple Watch Series 11
#               (46mm)"), to check the engine behaves the same on the watch's own runtime
set -euo pipefail
cd "$(dirname "$0")/../Packages/HourGlassCore"

if [ "${1:-}" = "--watch" ]; then
  SIM="Apple Watch Series 11 (46mm)"
  if [ $# -gt 1 ] && [ "${2#-}" = "$2" ]; then SIM="$2"; fi
  xcodebuild test -scheme HourGlassCore-Package -destination "platform=watchOS Simulator,name=$SIM" \
    -derivedDataPath ../../DerivedData/Package -quiet
  exit 0
fi

swift test "$@"
