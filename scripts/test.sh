#!/usr/bin/env bash
# Runs the HourGlassCore package tests: the sand simulation, motion mapping and renderer.
set -euo pipefail
cd "$(dirname "$0")/../Packages/HourGlassCore"

swift test "$@"
