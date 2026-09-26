#!/usr/bin/env bash
# Builds the end-to-end conversation probe from the real app sources.
# Usage: ./Tools/run-conversation-probe.sh [output-path]   (default ./.build/conversationprobe)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$DIR/.build/conversationprobe}"
mkdir -p "$(dirname "$OUT")"
swiftc -O -o "$OUT" \
  "$DIR/Sources/LiveClient.swift" \
  "$DIR/Sources/LinkClient.swift" \
  "$DIR/Sources/LinkTasks.swift Sources/RunProgress.swift" \
  "$DIR/Sources/DispatchGate.swift" \
  "$DIR/Sources/ToolRouter.swift" \
  "$DIR/Sources/SessionCoordinator.swift" \
  "$DIR/Tools/ConversationProbe/main.swift"
echo "built $OUT"
