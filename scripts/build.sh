#!/usr/bin/env bash
# Generates the Xcode project and builds the watch app into DerivedData/.
#
# Usage: scripts/build.sh [--run [simulator name]] [-- extra launch arguments]
#   (default)   build for the watchOS simulator
#   --run       also boot a simulator (default "Apple Watch Series 11 (46mm)"), install and launch
#               the app. The simulator has no motion sensors, so it's launched with -demo, which
#               sways gravity around; add e.g. `-- -mode hourglass -turnOver` for the hourglass.
#   --device    build for a real watch instead (signed with the team in project.yml)
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || { echo "XcodeGen is missing; install it with 'brew install xcodegen'." >&2; exit 1; }
xcodegen generate --quiet

RUN=false
DEVICE=false
SIM="Apple Watch Series 11 (46mm)"
EXTRA=()
while [ $# -gt 0 ]; do
  case "$1" in
    --run) RUN=true; if [ $# -gt 1 ] && [ "${2#-}" = "$2" ]; then SIM="$2"; shift; fi ;;
    --device) DEVICE=true ;;
    --) shift; EXTRA=("$@"); break ;;
    *) echo "Unknown option $1" >&2; exit 1 ;;
  esac
  shift
done

if $DEVICE; then
  # -allowProvisioningUpdates lets Xcode create the signing assets for the team in project.yml.
  xcodebuild -project HourGlass.xcodeproj -scheme HourGlass -configuration Release \
    -destination "generic/platform=watchOS" -derivedDataPath DerivedData -allowProvisioningUpdates -quiet build
  echo "Built: DerivedData/Build/Products/Release-watchos/HourGlass.app"
  exit 0
fi

xcodebuild -project HourGlass.xcodeproj -scheme HourGlass -configuration Debug \
  -destination "platform=watchOS Simulator,name=$SIM" -derivedDataPath DerivedData -quiet build
APP="DerivedData/Build/Products/Debug-watchsimulator/HourGlass.app"
echo "Built: $APP"

if $RUN; then
  xcrun simctl boot "$SIM" 2>/dev/null || true
  xcrun simctl bootstatus "$SIM" -b >/dev/null
  open -a Simulator
  xcrun simctl install "$SIM" "$APP"
  xcrun simctl launch --terminate-running-process "$SIM" nl.vincentbruijn.HourGlass -demo "${EXTRA[@]+"${EXTRA[@]}"}"
fi
