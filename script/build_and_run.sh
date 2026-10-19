#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
mode="${1:-run}"
derived=/tmp/boringNotch-pedro-proxmox
built="$derived/Build/Products/Release/boringNotch.app"
installed="/Applications/Insight Notch.app"
legacyInstalled=/Applications/boringNotch.app
prefs="$HOME/Library/Preferences/theboringteam.boringnotch.plist"
runtime="$HOME/.local/share/pedro-notch"
backup="$HOME/Library/Application Support/PedroEditionBackups/pre-activity-$(date +%Y%m%d-%H%M%S)"
cd "$root"
case "$mode" in
  run|--verify|--logs|--debug|--install-built) ;;
  *) printf 'Usage: %s [--verify|--logs|--debug|--install-built]\n' "$0"; exit 2 ;;
esac
if [[ "$mode" != --install-built ]]; then
  # Xcode's Swift runtime scan requires these folders even without extensions.
  mkdir -p "$built/Contents/PlugIns" "$built/Contents/Library/SystemExtensions" "$built/Contents/Extensions"
  xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Release \
    -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO build
fi
test -x "$built/Contents/MacOS/boringNotch"
# Keep the existing executable/module identity while branding the packaged app.
/usr/libexec/PlistBuddy -c "Set :CFBundleName Insight Notch" "$built/Contents/Info.plist"
codesign --force --deep --sign - "$built"
codesign --verify --deep --strict "$built"
(cd Integrations && npm ci --omit=optional --ignore-scripts)
mkdir -p "$backup"
[[ ! -f "$prefs" ]] || ditto "$prefs" "$backup/preferences-before-stop.plist"
[[ ! -d "$runtime" ]] || ditto "$runtime" "$backup/integrations"
mkdir -p "$runtime" "$HOME/.agents/skills/notch-activity"
ditto Integrations "$runtime"
chmod 700 "$runtime"
ditto Integrations/notch-activity/SKILL.md "$HOME/.agents/skills/notch-activity/SKILL.md"
/usr/bin/python3 script/repair_launch_services.py --stop-all
[[ ! -f "$prefs" ]] || ditto "$prefs" "$backup/preferences.plist"
for appPath in "$installed" "$legacyInstalled"; do
  [[ ! -d "$appPath" ]] || mv "$appPath" "$backup/$(basename "$appPath")"
done
if ! ditto "$built" "$installed"; then
  [[ ! -d "$installed" ]] || mv "$installed" "$backup/failed-install.app"
  for appPath in "$installed" "$legacyInstalled"; do
    previous="$backup/$(basename "$appPath")"
    [[ ! -d "$previous" ]] || ditto "$previous" "$appPath"
  done
  if [[ -d "$installed" ]]; then open -n "$installed"; else open -n "$legacyInstalled"; fi
  exit 1
fi
codesign --verify --deep --strict "$installed"
/usr/bin/python3 script/repair_launch_services.py
open -n "$installed"
sleep 2
pgrep -f '^/Applications/Insight Notch\.app/Contents/MacOS/boringNotch$' >/dev/null
printf 'Installed; backup: %s\n' "$backup"
case "$mode" in
  --logs) /usr/bin/log stream --level info --predicate 'process == "boringNotch"' ;;
  --debug) lldb -n boringNotch ;;
esac
