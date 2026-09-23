#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
manifest=${1:-docs/audits/2026-09-22/bangdream/manifest.json}
output=${2:-/tmp/live-dashboard-audit.json}
mode=${3:-}
compiler_cache=${TMPDIR:-/tmp}/live-dashboard-audit-module-cache
executable=${TMPDIR:-/tmp}/live-dashboard-official-audit
swiftc -parse-as-library -swift-version 6 -module-cache-path "$compiler_cache" \
  ios/Sources/LiveDashboardKit/Domain/Models/*.swift \
  ios/Sources/LiveDashboardKit/Data/LiveRepository.swift \
  ios/Sources/LiveDashboardKit/Data/LocalLiveRepository.swift \
  ios/Sources/LiveDashboardKit/Data/CardRefreshMerge.swift \
  ios/Sources/LiveDashboardKit/Data/OfficialEventScraper.swift \
  scripts/audit/OfficialScraperAudit.swift -o "$executable"
if [ "$mode" = '--live' ]; then
  "$executable" "$manifest" "$output" --live
else
  "$executable" "$manifest" "$output"
fi
