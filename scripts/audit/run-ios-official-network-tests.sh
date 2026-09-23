#!/bin/sh
# Opt-in integration test: real iOS URLSession requests to official websites.
set -eu
cd "$(dirname "$0")/../.."
simulator_id=${1:?Usage: run-ios-official-network-tests.sh SIMULATOR_UUID [DERIVED_DATA_PATH]}
derived=${2:-${TMPDIR:-/tmp}/livedashboard-official-network}
xcodegen generate --spec ios/project.yml
xcodebuild -project ios/LiveDashboard.xcodeproj -scheme LiveDashboard \
  -destination "platform=iOS Simulator,id=$simulator_id" -derivedDataPath "$derived" \
  CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO build-for-testing
python3 - "$derived" <<'PY'
import pathlib, plistlib, sys
products = pathlib.Path(sys.argv[1]).resolve() / 'Build/Products'
source = max(products.glob('LiveDashboard_*.xctestrun'), key=lambda p: p.stat().st_mtime)
with source.open('rb') as stream:
    config = plistlib.load(stream)
config['LiveDashboardKitTests'].setdefault('EnvironmentVariables', {})['LIVE_DASHBOARD_NETWORK_TESTS'] = '1'
# Keep beside the original, so __TESTROOT__ still resolves to the build products.
with (products / 'OfficialNetwork.xctestrun').open('wb') as stream:
    plistlib.dump(config, stream)
PY
xcodebuild -xctestrun "$derived/Build/Products/OfficialNetwork.xctestrun" \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -parallel-testing-enabled NO \
  -only-testing:LiveDashboardKitTests/OfficialNetworkIntegrationTests test-without-building
