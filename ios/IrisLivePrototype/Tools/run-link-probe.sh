#!/usr/bin/env bash
# Builds the Iris Link + Live probe from the real app sources.
# Usage: ./Tools/run-link-probe.sh [output-path]      (default: ./.build/linkprobe)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$DIR/.build/linkprobe}"
mkdir -p "$(dirname "$OUT")"
swiftc -O -o "$OUT" \
  "$DIR/Sources/LiveClient.swift" \
  "$DIR/Sources/LinkClient.swift" \
  "$DIR/Tools/LinkProbe/main.swift"
echo "built $OUT"
