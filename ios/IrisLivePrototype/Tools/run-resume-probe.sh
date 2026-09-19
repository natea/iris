#!/usr/bin/env bash
# Builds the reconnect/resumption probe from the real app sources.
# Usage: ./Tools/run-resume-probe.sh [output-path]   (default ./.build/resumeprobe)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$DIR/.build/resumeprobe}"
mkdir -p "$(dirname "$OUT")"
swiftc -O -o "$OUT" \
  "$DIR/Sources/LiveClient.swift" \
  "$DIR/Sources/LinkClient.swift" \
  "$DIR/Sources/LinkTasks.swift" \
  "$DIR/Sources/RunProgress.swift" \
  "$DIR/Sources/DispatchGate.swift" \
  "$DIR/Sources/ReconnectPolicy.swift" \
  "$DIR/Sources/ToolRouter.swift" \
  "$DIR/Sources/SessionCoordinator.swift" \
  "$DIR/Tools/ResumeProbe/main.swift"
echo "built $OUT"
