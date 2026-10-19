#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_output="$(mktemp -d "${TMPDIR:-/tmp}/boring-notch-pedro-tests.XXXXXX")"
trap 'rm -R "$test_output"' EXIT

cd "$repo_root"

swiftc -parse-as-library \
  boringNotch/models/PedroContinuityModels.swift \
  boringNotch/Providers/PedroContinuityTransport.swift \
  Tests/PedroContinuityTests.swift \
  -o "$test_output/PedroContinuityTests"
"$test_output/PedroContinuityTests"

/usr/bin/python3 Tests/GeminiAppsUsageTests.py

swiftc -parse-as-library \
  boringNotch/models/PedroOpsModels.swift \
  boringNotch/models/PedroProxmoxModels.swift \
  boringNotch/Providers/PedroOpsProvider.swift \
  boringNotch/Providers/PedroProxmoxProvider.swift \
  Tests/PedroProxmoxProbeTests.swift \
  -lsqlite3 \
  -o "$test_output/PedroProxmoxProbeTests"
"$test_output/PedroProxmoxProbeTests"

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
  boringNotch/models/PedroProxmoxModels.swift \
  boringNotch/models/PedroStackModels.swift \
  boringNotch/models/PedroLiveActivityModels.swift \
  boringNotch/Providers/PedroStackProvider.swift \
  boringNotch/Providers/PedroProxmoxProvider.swift \
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
  boringNotch/Providers/AgentUsage/*.swift \
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
python3 -m unittest discover -s Tests -p test_scrcpy_phone.py
python3 -m unittest discover -s Tests -p test_android_window.py
python3 -m unittest discover -s Tests -p test_desk_hub.py
python3 -m unittest discover -s Tests -p test_battery_widgets.py
python3 -m unittest discover -s Tests -p test_battery_hub.py
python3 -m unittest discover -s Tests -p test_windows_battery.py
node Tests/test-battery-collect.cjs
swiftc -parse-as-library Widgets/macOS/Shared/BatteryViews.swift Tests/PedroBatteryWidgetTests.swift -o "$test_output/PedroBatteryWidgetTests"
"$test_output/PedroBatteryWidgetTests"
node Tests/PedroPhoneTransferTests.cjs
node Tests/PedroLocalConfigTests.cjs
node --test Tests/PedroPhoneEventsTests.cjs
swiftc -parse-as-library \
  boringNotch/models/PedroPhoneModels.swift \
  Tests/PedroPhoneNotificationTests.swift \
  -o "$test_output/PedroPhoneNotificationTests"
"$test_output/PedroPhoneNotificationTests"

swiftc -parse-as-library \
  boringNotch/models/PedroOpsModels.swift \
  boringNotch/models/PedroAgentModels.swift \
  boringNotch/Providers/PedroOpsProvider.swift \
  boringNotch/Providers/PedroAgentBridge.swift \
  boringNotch/Providers/PedroAgentSessionProvider.swift \
  boringNotch/Providers/AgentUsage/*.swift \
  boringNotch/Providers/MixerRender.swift \
  boringNotch/Providers/BoostLimiter.swift \
  Tests/PedroDifferentialTests.swift \
  -lsqlite3 -o "$test_output/PedroDifferentialTests"
"$test_output/PedroDifferentialTests"

swiftc -parse-as-library \
  boringNotch/models/PlaybackState.swift \
  "boringNotch/MediaControllers/YouTube Music Controller/YouTubeMusicModels.swift" \
  "boringNotch/MediaControllers/YouTube Music Controller/YouTubeMusicNetworking.swift" \
  boringNotch/components/Shelf/Services/ShelfFileDragWriter.swift \
  boringNotch/extensions/NSImage+Extensions.swift \
  Tests/MediaReliabilityTests.swift \
  -o "$test_output/MediaReliabilityTests"
"$test_output/MediaReliabilityTests"

swiftc -parse-as-library \
  boringNotch/models/PlaybackState.swift \
  boringNotch/MediaControllers/MediaControllerProtocol.swift \
  "boringNotch/MediaControllers/YouTube Music Controller/"*.swift \
  Tests/MediaSocketIntegrationTests.swift \
  -o "$test_output/MediaSocketIntegrationTests"
"$test_output/MediaSocketIntegrationTests"
