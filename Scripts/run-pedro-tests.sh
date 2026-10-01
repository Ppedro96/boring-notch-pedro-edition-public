#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_output="$(mktemp -d "${TMPDIR:-/tmp}/boring-notch-pedro-tests.XXXXXX")"
trap 'rm -R "$test_output"' EXIT

cd "$repo_root"

swiftc -parse-as-library \
  boringNotch/models/PedroOpsModels.swift \
  boringNotch/models/PedroProxmoxModels.swift \
  boringNotch/models/PedroAgentModels.swift \
  boringNotch/Providers/PedroOpsProvider.swift \
  boringNotch/Providers/PedroAgentBridge.swift \
  boringNotch/Providers/PedroAgentSessionProvider.swift \
  boringNotch/Providers/PedroAgentMonitor.swift \
  Tests/PedroOpsModelTests.swift \
  -lsqlite3 \
  -o "$test_output/PedroOpsModelTests"
"$test_output/PedroOpsModelTests"

swiftc -parse-as-library \
  boringNotch/models/PedroOpsModels.swift \
  boringNotch/Providers/PedroOpsProvider.swift \
  boringNotch/models/PedroClipboardModels.swift \
  boringNotch/models/PedroStackModels.swift \
  boringNotch/models/PedroLiveActivityModels.swift \
  boringNotch/Providers/PedroStackProvider.swift \
  Tests/PedroClipboardStackTests.swift \
  -lsqlite3 \
  -o "$test_output/PedroClipboardStackTests"
"$test_output/PedroClipboardStackTests"

node Tests/PedroAgentBridgeHookTests.js

swiftc -parse-as-library \
  boringNotch/models/PedroMoonlightModels.swift \
  boringNotch/models/PedroCaptureStore.swift \
  boringNotch/Providers/PedroCaptureManager.swift \
  Tests/PedroQuickToolsTests.swift \
  -o "$test_output/PedroQuickToolsTests"
"$test_output/PedroQuickToolsTests"

swiftc -parse-as-library \
  boringNotch/Providers/PedroAreaScreenshot.swift \
  Tests/PedroAreaScreenshotTests.swift \
  -o "$test_output/PedroAreaScreenshotTests"
"$test_output/PedroAreaScreenshotTests"

swiftc -parse-as-library \
  boringNotch/models/PedroOpsModels.swift \
  boringNotch/Providers/PedroOpsProvider.swift \
  boringNotch/Providers/PedroOpsNetworkProvider.swift \
  Tests/PedroOpsNetworkTests.swift \
  -lsqlite3 \
  -o "$test_output/PedroOpsNetworkTests"
"$test_output/PedroOpsNetworkTests"

swiftc -parse-as-library \
  boringNotch/models/PedroActivityModels.swift \
  boringNotch/models/PedroPhoneModels.swift \
  boringNotch/models/PedroMeetingLink.swift \
  boringNotch/Providers/PedroActivityManager.swift \
  boringNotch/Providers/PedroTransferService.swift \
  Tests/PedroActivityTests.swift \
  -o "$test_output/PedroActivityTests"
"$test_output/PedroActivityTests"
node Tests/PedroActivityBridgeTests.cjs
node Tests/PedroPhoneTransferTests.cjs
node Tests/PedroLocalConfigTests.cjs
