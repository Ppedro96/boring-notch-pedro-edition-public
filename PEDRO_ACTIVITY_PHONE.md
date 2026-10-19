# Activity, Phone and Meeting Integrations

## Scope

- Activity: Dot events emitted by an explicitly authorized local skill; NOT an
  automatic mirror of ChatGPT notifications. Dot requires local computer access.
- Transfers: regular-file copies initiated in the Notch, mounted NAS destinations,
  passive partial-download detection, and externally instrumented jobs. Not a
  universal Finder/export observer. Partial downloads without known totals show
  bytes, never a fabricated percentage. Completion requires destination evidence.
- Phone: official KDE Connect on macOS and Android, via its local authenticated
  D-Bus session. No cloud endpoint, SMS, remote input or automatic clipboard sync.
  Pairing and Android notification access are approved by the user in KDE Connect.
- Calendar: supported HTTPS meeting links in URL/location/notes, direct Join and
  countdown; existing calendar selections, media configuration and height unchanged.

## Build and Install

`./script/build_and_run.sh --verify` builds Release, signs ad hoc, installs the
local helpers and skill, backs up the existing app and preferences, then launches.
Dependencies: Xcode, Node/npm at /opt/homebrew, official KDE Connect.
Runtime: `~/.local/share/pedro-notch`; skill: `~/.agents/skills/notch-activity`.
Use `npm ci --omit=optional --ignore-scripts` for helpers. Optional native socket
dependencies are deliberately excluded; xml2js is pinned to a patched version.
The bridge only accepts a same-user UNIX socket under /tmp, with a 7-second timeout.
Phone polling runs every 5 seconds only while its tab is visible, independently of
Codex/Claude/SSH. Snapshot failures clear stale phone readings.

An explicitly configured Linux SSH relay is also queried. Its KDE Connect pairings
can supply phones when the Mac and phones cannot reach each other directly.
Install the same helper and pure-JS node_modules in
`/home/example/.local/share/pedro-notch/`; Linux uses the same-user session bus at
`/run/user/<uid>/bus`. No remote service or firewall change is created. Direct
connected pairings take precedence; relay devices are labelled `Via X99`.
Battery, notifications, ring, links and file sending work over the relay.
File sending uses `kde-file-transfer.cjs` on both hosts: stream over SSH to a
mode-600 file in a mode-700 UUID staging folder on X99, verify SHA-256 and source
stability, then pass its Linux file URL to KDE Connect. The user's source is
never deleted. Normal terminal results remove staging; unconfirmed jobs retain
it for at most 24 hours, cleaned on a later transfer. No new server is installed.
The same-user D-Bus monitor observes only KDE Connect JobView V2/V3 calls and
matches filename, device and total bytes. Completion requires successful KDE
job termination, not `shareUrl` acknowledgement or reaching 100% bytes. A
grouped/external job or missing monitor result remains explicitly unconfirmed.
Cancellation applies to queued files and Mac-to-X99 staging, not a dispatched
KDE job. Each file is sent sequentially; no request timeout is reused from polls.
Direct Mac pairings retain ordinary KDE sending with an acknowledgement only.

Optional display-name overrides come from `deviceNames` in
`~/.config/pedro-notch/integrations.json`. The bridge contains no personal device
IDs. These aliases change only the Notch label and preserve the pairing identity.

The phone selector is a fixed-height horizontal tab strip: short device name,
battery percentage and a charging bolt. Up to four devices share the width;
additional devices scroll horizontally. Selecting a tab retains the existing
detail panel below. Offline/unknown batteries show `--`, never stale percentages.
Its file button supports multiple regular files. Dropping Finder files onto the
Phone top icon, Phone panel or a device tab prepares a selection without sending it; choosing
a battery tab selects the recipient, then Enviar starts the queue. Notifications
and transfers share the same fixed-height right panel, with vertical scrolling.
Transfer outcomes also appear in Activity. No file-content history is retained.
Jobs too short for KDE's 500 ms progress window finish as `submitted` (Entregue
ao KDE), never `completed` without a terminal job event. They do not leave an
indefinite spinner. An active job instead has a 120-second no-progress timeout.

## Event Contract

`Integrations/notch-notify.cjs --id TASK_ID --title TITLE --detail TEXT --state completed`
writes an atomic, mode-600 event under `~/.pedroops/activity/events` (mode 700).
State: running/waiting/completed/failed/cancelled/unknown. Kind: dot/job/transfer.
Progress optional 0..100. HTTP(S) URL optional; no embedded credentials. Timestamp
is Unix seconds. Stable IDs and content-hash revisions make retries idempotent.
Swift accepts only regular non-symlink JSON, <=64 KiB, <=250 recent valid events,
at most 30 days old. Clearing records event revisions locally, not on the source.
Changed content creates a new revision; replaying identical content stays dismissed.
External events never execute commands or open a destination without a user click.

## Privacy and Verification

Phone notification bodies stay in memory. Local dismissal persists only SHA-256
fingerprints; app filters persist names. No remote notification dismissal calls.
Sending a clipboard link asks confirmation showing the destination and exact URL.
Files are sent only after explicit selection. Ring is a user-triggered action.
KDE Connect accepting a transfer request is not confirmation of arrival.
Node bridge tests and Swift copy/dismissal/download/meeting tests are in
`Scripts/run-pedro-tests.sh`. Real device pairing and Dot-to-skill invocation need
separate end-to-end verification; passing a synthetic event does not establish it.

## Event bridge, native replies and media — 18 October 2026

The Mac now uses one persistent `kde-phone.cjs watch` process instead of a five-second snapshot timer. Local D-Bus signals update the Mac devices immediately; one separate SSH stream observes the S23 through X99. Both streams reconnect independently. Losing either source clears its live reply/media controls without blocking the other. A live probe produced the local frame in 140 ms and the X99 frame in 715 ms; idle observation produced no repeated snapshots.

`PedroPhoneNativeNotifications` uses macOS UserNotifications, device/app grouping and a text-input Reply action when KDE supplies a reply token. Old notifications are baselined rather than replayed on launch. Replies revalidate the current device, notification and reply token, and are submitted manually through stdin (not process arguments). Acknowledgement means handed to KDE, not delivery/read confirmation. Permission changes are checked on app activation events. Only KDE's forwarded-notification popup is temporarily muted after native authorization; its prior configuration is restored when the helper exits, including after the app closes, while preserving other KDE settings. Pairing/call/battery/error events stay with KDE.

The final Celular layout, explicitly chosen by Pedro, keeps battery readings in the four device tabs and uses two blocks below: a 180px media block on the left, and a wider notifications/composer/files block on the right. Secondary actions stay in the More menu. The left block controls the selected phone: cached artwork when available locally, track/artist, player choice, Previous/PlayPause/Next. It does not replace the existing Mac playback view. No active phone player was available during QA, so actual playback remains unverified.

Validation: Release build and strict codesign passed; 10 event/relay/reply/configuration tests, notification-ledger/legacy-decoding tests and existing transfer tests passed. The real Telegram notification on S25 exposed Reply and its composer; no reply was transmitted. Native test request was accepted without error; macOS silenced its banner because the existing display-sharing setting suppresses notifications. A real close/reopen removed the popup override and both event processes, then restored the four connected devices and native mode. One app and one local observer remained after installation. No pairing or KDE network settings changed; S23 remains through X99. No commits or pushes.

Visual revision verified live after installation: two side-by-side blocks with no footer spanning the panel, media on the left and the wider content area on the right. Player selection appears on the artwork when multiple players exist. Release build passed, canonical app signature verified; no messages transmitted during QA.

Upper-right controls review: hid the native Menu chevron and reserved separate 26x24 targets for files and More. Header text truncates before squeezing buttons. Reply mode has one header close button and a compact composer; notification actions use 24x24 targets. Pending files use a compact filename/destination row with separate send/discard controls. Installed Release build passed strict codesign. Live UI verified separated controls, opening/closing More and switching notifications/files on S23 and S25. No replyable notification or active media was present for this final review; composer and pending-file states were checked in source, not live. No files or messages were sent. One canonical app and one local observer were running.

## Optional Dot visibility — 18 October 2026

Settings > Geral > Integrações includes `Ocultar Dot` (`hideDotIntegration`, default false). It replaces Dot branding/filter with Transferências and filters Dot events out of the published list, which also removes their live activities. Raw events and local history remain intact; transfers/downloads remain visible. Changes apply without restart via preference observation. Activity tests cover hidden Dot history surviving recreation, transfers remaining visible, and restoration when unhidden.

Installed Release, strict codesign passed. Live settings QA toggled hide/show/hide without restart, confirmed the Dot picker returns when shown, and existing download/transfer cards remain when hidden. Pedro preference left enabled (`Ocultar Dot` on).

## Phone reply keyboard focus — 18 October 2026

The phone composer previously activated NSApp and set SwiftUI FocusState but did not allow its NSPanel to become key (`allowsKeyboardFocus` remained false). A window reader now obtains the actual containing notch window, allows keyboard focus and makes it key before focusing the text field. Only the notch on the pointer's display acquires focus. A balanced interaction hold keeps the notch open while editing. Closing/switching away releases keyboard focus and the hold; Escape cancels the composer. Reply transmission logic stays manual.

Installed Release passed strict codesign. Live QA on a real S25 WhatsApp reply: automatic text-field focus, keyboard typing, accented paste and select-all/delete worked; Enviar enabled with text and disabled after clearing. Escape closed the editor/notch, reopening Reply focused the empty field again. All synthetic draft text removed; no message sent.

## Temporary phone action results — 18 October 2026

Pedro's real reply returned KDE success and the live notification disappeared. This confirms handoff to KDE, not WhatsApp delivery/read status. The persistent result was caused by feedback having no expiration and replacing the connectivity label. Phone action results now use a four-second, manually dismissible overlay with fixed height, without entering the layout calculation; the header always retains the connection status. Replacing a result cancels its old deadline. Automated tests cover automatic expiry, replacement surviving an earlier deadline, and explicit dismissal; no messages sent by the agent.

Release build/install and strict signature passed. Live installed panel returned to normal dimensions with connection label Mac and no persistent result. Timing/replacement/dismissal tested automatically; no new real reply was sent for QA.

## scrcpy on-demand display — 18 October 2026

scrcpy 5.0.1 installed through Homebrew, with a local app bundle for macOS window registration. Celular > More > Abrir tela (scrcpy) launches a separate window for the selected phone. S25/Fold6/Tab S8+ are paired to this Mac through a temporary Android Studio-compatible QR; pairing secrets are not retained. Discovered models/serials are stored privately in `scrcpy-devices.json`. A user LaunchAgent `marketing.insight360.adb-reconnect` starts at login and checks learned TLS services every 30 seconds, updating changing ports; it does not pair unknown devices, disable auth, enable port5555, or turn on Android Wi-Fi debugging. It avoids creating an IP transport when the mDNS transport already exists.

The worker limits video to 1600px/30fps/6Mbps, disables audio/clipboard autosync, retries a lost stream for up to two minutes and never reopens after normal window close. S23 may reuse X99 authorization over two loopback-only SSH forwards, without restarting its ADB/camera service. Four regression tests cover TLS discovery, known-device filtering, port changes, transport deduplication, normal close and disconnected retry.

Live: S25/Fold Android17 advertise ADB Wi-Fi2.0; Tab Android16 advertises Wi-Fi1. Fold changed port and reconnected during setup. S25 video window verified, launch from the installed Notch verified, close leaves no mirroring worker. This does not guarantee Android will retain its debugging toggle after a reboot/network change.

S23 remote display image verified over X99 SSH; its existing camera service remained active. User began interacting with the scrcpy window during final QA, so that window was left open. The temporary pairing watcher was stopped after all three Mac devices paired. No Android authorization timeout, debugging authentication, network/firewall or camera settings were changed. The local scrcpy app includes its matching server JAR to avoid a Homebrew server-version mismatch.

### 18/10/2026 — Tab S8+: quedas da depuração Wi-Fi

- Log Android confirmou `Detected wifi network change. Disabling adbwifi.` às 22:30:53 e 22:46:52. Tablet Android16/ADB Wi-Fi1, conectado/carregando e sem Doze; sinal observado entre -18 e -20dBm. Não era expiração de chave (timeout padrão não alterado).
- Ajuste somente no tablet DEMO_TABLET: `global sem_wifi_switch_to_better_wifi_enabled` passou de1 para0, desativando a troca automática por redes melhores. Valor anterior salvo no work da sessão t9/tablet-wifi-before.json; reversão é restaurar1. Isso reduz trocas automáticas; uma desconexão real/roaming/reinício ainda pode desligar o toggle Android16.
- Anúncio Bonjour duplicado `adb-DEMO_TABLET-yNXI9y (2)` revelou erro no parser por espaços. scrcpy helper agora preserva serial completo, deduplica hardware, ignora transporte que não responde e usa `adb mdns track-services --proto-text` quando a tabela legada vem vazia no adb37. Reconecta somente seriais já aprendidos, sem novas permissões, tcpip5555 ou restart global do ADB.
- Bridge de baterias também preserva serial com espaços e envia uma vez por hardware. Helpers copiados ao runtime local; LaunchAgents existentes usam as versões novas na próxima execução. Sete testes scrcpy e três testes de privacidade/offline de bateria passaram; execução real reconheceu tablet e Fold e enviou snapshot.
