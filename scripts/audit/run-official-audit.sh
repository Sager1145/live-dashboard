#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
manifest=${1:-docs/audits/2026-09-22/bangdream/manifest.json}
output=${2:-/tmp/live-dashboard-audit.json}
mode=${3:-}
swift build --package-path ios --product OfficialAuditCLI -c release
executable=ios/.build/release/OfficialAuditCLI
if [ "$mode" = '--live' ]; then
  "$executable" "$manifest" "$output" --live
else
  "$executable" "$manifest" "$output"
fi
