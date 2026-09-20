#!/usr/bin/env bash
# Builds the §13 voice-preview probe from the real app sources.
# Usage: ./Tools/run-voice-preview-probe.sh [output-path]   (default ./.build/voicepreviewprobe)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$DIR/.build/voicepreviewprobe}"
mkdir -p "$(dirname "$OUT")"
swiftc -O -o "$OUT" \
  "$DIR/Sources/LiveClient.swift" \
  "$DIR/Sources/LinkClient.swift" \
  "$DIR/Sources/PushToken.swift" \
  "$DIR/Tools/VoicePreviewProbe/main.swift"
echo "built $OUT"
