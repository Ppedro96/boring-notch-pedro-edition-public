# Boring Notch - Pedro Edition

Sanitized public derivative of [Boring Notch](https://github.com/TheBoredTeam/boring.notch),
built on the v2.7.3 codebase and kept under the original GPLv3 license.

## Added Features

- Claude and Codex usage windows
- Claude and Codex session activity and approval bridge
- Status alerts with local dismissal persistence
- Mac, X99, TrueNAS, VPS, Supabase, service, and backup status cards
- Clipboard history on Control+V while preserving Command+V
- Compact live activity state in the closed notch
- YouTube Music and calendar configuration preserved across local releases
- Alienware and Proxmox telemetry, including GPU data and guest navigation
- Moonlight quick actions, link capture and selected-area screenshots
- KDE Connect phone/tablet battery tabs, notifications and file transfers
- Local activity events and calendar meeting links

## Runtime Data

Credentials and runtime state are intentionally kept outside the repository:

- `~/.pedroops/` for agent bridge events and local usage state
- macOS Keychain and `~/.ssh/` for credentials
- the Boring Notch app container for preferences and alert state
- locally configured webhooks for optional read-only status feeds

Do not commit cookies, private keys, app containers, build products, or artwork
caches to the source branch or GitHub.

## Clean Export

This repository has independent history, example SSH destinations, disabled
default webhooks and no private configuration branch. Local setup is documented
in `README.md`. Do not publish a personal repository by changing its visibility
or deleting secrets from only its latest commit: use a separately audited export.

## Validation

Run the focused checks from the repository root:

```bash
Scripts/run-pedro-tests.sh
```

Build the local release:

```bash
xcodebuild \
  -project boringNotch.xcodeproj \
  -scheme boringNotch \
  -configuration Release \
  -derivedDataPath /tmp/boringNotch-pedro \
  build
```

## Update Policy

Sparkle automatic updates are disabled in this edition because installing an
upstream binary would replace the custom build. Upstream releases should be
reviewed and merged manually, followed by a full test and release build.
