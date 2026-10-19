# Boring Notch - Pedro Edition

A configurable personal-tools derivative of
[Boring Notch](https://github.com/TheBoredTeam/boring.notch), based on v2.7.3.
This public source export does not contain the author's credentials, private
endpoints, device pairing IDs, runtime preferences or private Git history.
GPLv3 and original third-party notices are preserved.

## Tools

- Native Home and Shelf, with music and calendar integration
- Claude/Codex/Gemini usage windows, local activity events and optional Dot visibility
- Clipboard history on Control+V, normal pasting on Command+V
- Selected-area screenshots copied to the clipboard
- Moonlight actions and Obsidian link capture
- KDE Connect batteries, native macOS notifications, replies, media controls and file transfers
- Battery widgets for macOS and Android, with an optional authenticated Python/SQLite hub
- Android app windows with scrcpy, model icons and wireless ADB recovery helpers
- Deskflow keyboard/mouse sharing and SSH processing queues for Linux and Windows
- Mac, Linux/TrueNAS, Windows and Proxmox telemetry
- Optional read-only status and alert feeds, with local dismissal

The infrastructure slots retain this edition's layout. Configure your own
hosts and feeds before using them. The optional battery hub is source code for
your own deployment; no hosted service, account or credentials are supplied.
Dot activity uses an explicitly invoked local skill, not a native ChatGPT mirror.

## Build and Test

Requires macOS 14+, Xcode, and Node/npm. The helper launcher currently expects
Homebrew Node at `/opt/homebrew/bin/node`; Intel installations must adjust it.
KDE Connect and Moonlight are optional external applications.

```bash
cd Integrations
npm ci --omit=optional --ignore-scripts
cd ..
Scripts/run-pedro-tests.sh
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch \
  -configuration Release -derivedDataPath /tmp/boring-notch-clean \
  CODE_SIGNING_ALLOWED=NO build
```

`script/build_and_run.sh --verify` also installs the application and helpers,
after backing up the previous app/preferences. Use that only when you intend to
replace the installed Boring Notch. No notarized binary is provided here.

## Local Configuration

Never put real keys, cookies, preferences or host details in this repository.
SSH monitoring uses your local `~/.ssh/id_ed25519` and known-hosts file.
It sends read-only probes over SSH; remote commands need normal user permissions.
Configure the app with `defaults write theboringteam.boringnotch KEY -string VALUE`
while the app is stopped, then reopen it.

| Key | Purpose |
| --- | --- |
| `pedro_ssh_x99` | Linux status host, `user@host` |
| `pedro_ssh_truenas` | NAS status host, `user@host` |
| `pedro_ssh_proxmox` | Proxmox host, `user@host` |
| `pedro_ssh_pveo2` | Second Proxmox host, `user@host` |
| `pedro_ssh_pveo2_identity` | Second host's local SSH key filename |
| `pedro_ssh_vps` | VPS status host, `user@host` |
| `pedro_ssh_alienware` | Windows display endpoint |
| `pedro_ssh_alienware_relay` | Linux gateway for the Windows SSH probe |
| `pedro_ssh_alienware_worker` | Windows destination reached from that gateway |
| `pedro_ops_alerts_webhook_url` | Optional alerts JSON feed |
| `pedro_stack_webhook_url` | Optional stack JSON feed |
| `pedro_capture_vault_path` | Obsidian vault directory |

The Windows gateway probe expects its private identity at
`~/.ssh/id_ed25519_alienware_worker` on the gateway. Demo endpoints are reserved
examples, never the author's machines. Alert/stack webhooks default to disabled.
NAS backup examples use `PrimaryPool` and `ArchivePool`; adapt those probe names
to your datasets. The configuration tables are local setup, not credential sync.

For phone relaying, copy `Config/integrations.example.json` to
`~/.config/pedro-notch/integrations.json`. Set `relayHost` to an authorized Linux
SSH alias and optionally fill `deviceNames` with your KDE IDs/display labels.
An empty relay host leaves direct Mac pairings working without SSH discovery.
Install the helpers/dependencies on the relay under
`~/.local/share/pedro-notch/`; pair phones using KDE Connect itself.

The scrcpy, worker and battery helpers retain example device profiles and SSH
aliases (`x99` and `alienware`). Replace those examples with your own paired IDs,
hardware serials and authorized SSH aliases before installing them. They do not
pair devices or grant host access automatically.

See [Widgets/README.md](Widgets/README.md) for the four-phone Mac widget, six-device
Android widget and Windows battery publisher. The battery endpoint is deliberately
`https://batteries.example.com/v1/batteries`; replace it consistently in the Android
network client, Mac bridge and Windows publisher with your own HTTPS endpoint.
Generate separate per-device tokens outside this repository and provision them
through the existing protected configuration flow. Never commit the resulting files.
Android builds use `ANDROID_SDK_ROOT` (platforms/build-tools for API 36) and
`JAVA_HOME` (JDK 21); signing material is generated locally and ignored by Git.
The Mac widget installer accepts `WIDGET_BUILD_PRODUCTS` for its build directory.

Codex usage reads the authenticated local Codex app-server when available.
Claude usage depends on your own local widget session cookie/refresh setup;
this export supplies no cookie or account profile. Network/API behavior can
change independently of this derivative.

## Provenance

This is a fresh, sanitized source snapshot, not a rewrite of the upstream or
personal Git history. See [UPSTREAM_README.md](UPSTREAM_README.md), [LICENSE](LICENSE)
and [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES). Automatic upstream binary updates
are disabled because they would overwrite the custom edition.
