#!/usr/bin/env bash
# Builds and runs the macOS protocol probe against the real Live API.
# Usage: ./Tools/run-probe.sh ["your prompt"]
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$(mktemp -d)/liveprobe"
swiftc -O -o "$BIN" "$DIR/Sources/LiveClient.swift" "$DIR/Tools/main.swift"
"$BIN" "${1:-Say hello in five words.}"
