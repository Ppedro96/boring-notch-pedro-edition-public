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
