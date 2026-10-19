#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
build="${WIDGET_BUILD_PRODUCTS:-${HOME}/Library/Caches/insight-notch/widget-build/Build/Products/Release}"
app="$build/InsightBatteries.app"
ext="$app/Contents/PlugIns/GalaxyBatteriesWidget.appex"
codesign --force --sign - --entitlements "$root/Extension/Widget.entitlements" "$ext"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
if [[ -d '/Applications/Insight Batteries.app' ]]; then
 backup="${HOME}/Library/Application Support/PedroEditionBackups/batteries-$(date +%Y%m%d-%H%M%S)"
 mkdir -p "$backup"
 ditto '/Applications/Insight Batteries.app' "$backup/Insight Batteries.app"
fi
pkill -TERM -f '^/Applications/Insight Batteries.app/Contents/MacOS/InsightBatteries$' || true
pkill -TERM -f '^/Applications/Insight Batteries.app/Contents/PlugIns/GalaxyBatteriesWidget.appex/Contents/MacOS/GalaxyBatteriesWidget' || true
ditto "$app" '/Applications/Insight Batteries.app'
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f '/Applications/Insight Batteries.app'
pluginkit -a '/Applications/Insight Batteries.app/Contents/PlugIns/GalaxyBatteriesWidget.appex'
