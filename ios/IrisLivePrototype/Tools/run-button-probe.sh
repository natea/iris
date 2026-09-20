#!/usr/bin/env bash
# Builds the answer-button probe from the real app sources.
# Usage: ./Tools/run-button-probe.sh [output-path]   (default ./.build/buttonprobe)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$DIR/.build/buttonprobe}"
mkdir -p "$(dirname "$OUT")"
swiftc -O -o "$OUT" \
  "$DIR/Sources/LiveClient.swift" \
  "$DIR/Sources/LinkClient.swift" \
  "$DIR/Sources/LinkTasks.swift" \
  "$DIR/Sources/RunProgress.swift" \
  "$DIR/Sources/PushToken.swift" \
  "$DIR/Sources/DispatchGate.swift" \
  "$DIR/Sources/ToolRouter.swift" \
  "$DIR/Sources/SessionCoordinator.swift" \
  "$DIR/Tools/ButtonProbe/main.swift"
echo "built $OUT"
