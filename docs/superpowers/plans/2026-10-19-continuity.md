# Cross-platform continuity implementation

**Goal:** Complete the eight approved integrations in the existing Mac and Linux Notchs.
**Architecture:** Private persistent SSH/stdio bridge to a shared SQLite/blob coordinator on the existing Linux host, with native adapters and one processing queue.
**Tech Stack:** Python 3 standard library, Swift/AppKit/SwiftUI, C++/Qt/QML, existing native input/media integrations.
**Spec:** `docs/superpowers/specs/2026-10-19-continuity.md`
**Global Constraints:** No secrets or personal network information in Git/docs; retain local features and active input; preserve unrelated Linux edits and original Mac environment file; no new infrastructure or arbitrary command API; never forward permission responses; no needless reapproval of the user's explicit authorization.
**Review Focus:** Real native end-to-end behavior, cache/reconnect/idempotence, queue authority and provenance, clipboard privacy, blob integrity, stale media/actions, compact UI and scroll behavior.

### Task 1: Shared coordinator and client bridge

**Files:** Create `Integrations/continuity-server.py`, `Integrations/continuity-client.py`, optional focused `continuity_store.py`/`continuity_transport.py`, and `Tests/test_continuity.py`. Update the spec only to document additional compatible response details, not to remove requirements.

- [x] Implement the stable protocol, transactional topic storage/tombstones, persistent subscriptions, peer-scoped command delivery and expiration, secure blob streaming, native client cache/outbox/reconnect, disabled defaults.
- [x] Implement `desk` forwarding hook using a private configured local broker and `local_main(request)` bypass; return explicit unavailable until Task 2 provides the broker.
- [x] Test real stdio sessions and temporary SQLite/files for subscriptions, concurrent patch/update/delete, reconnect/deduplication, command expiry and delivery, corruption/traversal/size/peer checks, and no publication of partial blobs.
- [x] Run new focused suite plus existing 30 desk/input tests. Commit only owned source/tests; report exact interface and remaining integration needs.

### Task 2: Shared processing and desktop authority

**Files:** `Integrations/desk-hub.py`, `Integrations/lan-mouse-control.py`, new focused coordinator adapter if needed, `Tests/test_desk_hub.py`, `Tests/test_lan_mouse.py`, Linux `integrations/desk/desk-hub.py` (preserve all existing Linux-only functionality). Private runtime deployment/configuration performed by controller afterwards.

- [x] Route configured client jobs/submit/retry/cancel/archive/result and deskflow actions to the coordinator; keep search/file retrieval local. Use Task 1 staging/cache protocol, allow all three executor roles, and expose `local_main` only for coordinator calls.
- [x] Centralize queue inputs/results and ensure retry/download works from either origin. Preserve original provenance/name, integrity verification and cancellation, avoid recursive forwarding. Keep prior local completed history accessible without starting duplicate jobs.
- [x] Share authoritative layout and actual input status. Allow Linux coordinator to manage native workers without requiring a running Mac for Linux/Windows connectivity. Do not mutate running native sessions during tests or replace identities.
- [x] Test queue FIFO, cross-origin result retrieval, offline/cancellation behavior and layout/status; full Python suite once. Commit only owned files in isolated Mac worktree; leave unrelated remote source intact.

### Task 3: Native macOS adapters and existing panels

**Files:** New focused `boringNotch/Providers/PedroContinuityProvider.swift` and models; existing clipboard manager/view, Shelf view/model/drop/action services, capture manager/view, ops provider/view, agent provider/views, music manager/views, Desk view, app lifecycle and Xcode project as needed. Do not restructure unrelated views.

- [x] Add one lifecycle-owned asynchronous bridge process, typed snapshots/requests, offline status/cache, and safe shutdown. Disabled config leaves old features intact.
- [x] Wire local clipboard capture + shared history/pins/removal/PNG/manual copy/fresh remote apply, excluding private types and suppressing echo. Do not upload historical clipboard automatically.
- [x] Wire common Shelf drag/upload/download/remove; shared links and captures; matching alert dismissal; task origin/status/results without permission responses; media host selector and remote commands with native local dispatch.
- [x] Wire authoritative Desk layout, central queue retry/download; preserve compact cards/headers and scroll guards. Build Release, run appropriate existing native/Python tests, commit owned files. No install or permission changes from subagent.

### Task 4: Native Linux adapters and existing panels

**Files:** Existing Linux source worktree `src/continuity/ContinuityProvider.*` (new), `src/main.cpp`, `CMakeLists.txt`, clipboard, Shelf/productivity, media, alerts, agents, Desk providers and corresponding QML pages. Back up and preserve all unrelated dirty changes.

- [x] Add one lifecycle-owned bridge process with exactly Task 1 protocol. Install integration helpers through existing user install tooling without replacing unrelated runtime helpers/configuration.
- [x] Implement the same shared clipboard/Shelf/links/alert/task/media/Desk/jobs behavior in existing panels; fix Klipper privacy bypass; show explicit origin and stale/offline status, keep native KDE media local control.
- [x] Keep compact dimensions, usable horizontal content, existing vertical scroll/pointer guards, correct mesh shortcut label. No extra crowded top-level tabs.
- [x] Build with the already-working local Qt/cachegen workaround, run meaningful CTest/QML/provider checks, review the exact diff against backup. Do not change OS packages or other active services; controller installs after review.

### Task 5: Rollout, end-to-end validation, documentation and repositories

**Files:** Private per-host runtime/config/cache, existing installed apps, sanitized READMEs/config examples, tests/diagnostics where useful. Preserve all unrelated source changes and private credential files.

- [x] Revalidate/back up existing source/runtime/apps and no active processing jobs. Deploy coordinator and bridge on the existing Linux host; configure private SSH role mappings. Publish native applications after builds and review; retain rollback backups.
- [x] Test all eight with synthetic cross-host clipboard text/PNG and pinned/removal, actual Shelf file hash round-trip, links, matching/new alert states, independent agent task origins, media exact target/expired commands, shared job submit/cancel/download, shared Mesa topology/status and continued native readiness. Test bridge reconnect without restarting input or ADB.
- [x] Review visual Mac UI and Linux rendered/native diagnostics, all vertical lists; state any physical/visual verification limits accurately. Verify no leaked keys, paths, domains, machine/device names in READMEs.
- [ ] Update authorized private/public/Forgejo repositories with sanitized implementation/docs and exact head verification; never include the legacy private credential-bearing commit. Record shared memory facts and final results/limits. Keep original unrelated environment and Linux work untouched.

### Task 6: Linux sender capture performance (latest user steering)

**Files:** Minimal attributed upstream patch/build documentation in existing integrations where useful; separate private Linux source/build and controller deployment artifact. Do not edit native Qt source or alter system packages.

- [x] Backport official Lan Mouse fix c194df791dc11c79d266ada4d413179d4da3525b to the exact installed release base 0d2190e787db9e482e17d4c16fb7c00ef4841bcb. Verify only the upstream Wayland capture read-once change; preserve wire/IPC compatibility and current layer-shell/libei choices.
- [x] Build headless on the existing Linux toolchain with pinned lockfile; run appropriate upstream tests without activating capture. Preserve a reproducible patch/source/build evidence and inspect the diff. No speculative mouse polling/coalescing, OS/network/permission changes.
- [x] Prepare a reviewed private one-host installer with exact binary backup/hash preconditions and identity/profile preservation, native ready/peer verification and truthful rollback. Controller alone installs after review. Mac/Windows native input binaries stay running.
- [x] Candidate trial explicitly waived after the corrected linear topology substantially improved actual mouse behavior. The candidate was built and reviewed but was not installed; the documented upstream condition was not established on this build. Preserve the original stable binary. A later trial requires fresh reviewed deployment preconditions.

### Task 7: Recover a failed Windows input receiver

**Files:** Existing `Integrations/lan-mouse-worker.py`, optional small private-runtime supervisor module, focused Python tests, generic integration notes. Controller deploys only Windows worker/helper after review.

- [x] Fix the observed case where the Windows daemon remains IPC/capture/emulation ready after its UDP receive loop logs a fatal error and exits. Detect only the current owned child's new fatal listener event, never old log lines or normal inactive peers. Restart only that child through the existing hidden supervisor, retain profile/certificate/grants, and reactivate exactly the configured peers once native capture/emulation is ready.
- [x] Use bounded restart/backoff, explicit failure state and accurate status; no restart storms or broad network/permission changes. A deliberate Mesa stop must cancel recovery and leave no child, including stop-versus-recovery races. Keep Windows task hidden, limited interactive user, same session; no new scheduled task/service or privileged input injection.
- [x] Preserve Mac/Linux lifecycle behavior and wire protocol. Test real temporary-child/log transitions, stale-log exclusion, recovery/activation, identity/config refusal, failed start, restart bounds, and deliberate-stop fencing with fake native IPC only; no live input in subagent tests.
- [x] Report exact source and tests; controller performs one reviewed Windows rollout with before/after identity/topology verification and user physical comparison. Do not mix the Linux capture trial into this task.

### Task 8: Linear desktop edges and matching Linux layout

**Files:** `Integrations/lan-mouse-control.py`, `Integrations/lan-mouse-worker.py`, focused input tests; Linux existing `qml/pages/DeskPage.qml` and minimal provider changes only if needed. Controller owns native profile migration/installation after review.

- [x] Replace the mistaken ring with a line. For `alienware-left`, physical order is Alienware—Mac—X99: Mac has left Alienware/right X99; Alienware has only right Mac; X99 has only left Mac. Mirror correctly for `x99-left`. Empty outer edges must have no outbound capture region. Validate one or two distinct adjacent peers with one unique left/right edge each; retain strict certificate/address/backend validation and exact authorization.
- [x] Preserve all physical keyboards/mice among the three using native linear handoff; do not add outer wrap as a shortcut. Preserve Linux/Windows connectivity when the Mac is unavailable by configuring the available pair on their inward-facing edges, with accurate partial status. Read-only status never changes sessions. Explicit start/layout reconciles a legacy ring or returning peer; do not claim a mismatched old profile confirmed, and preserve unaffected active profiles whenever adjacency has not changed. Failed configuration cannot activate stale profiles. Bounded reconciliation, no infinite restart loop.
- [x] Make the Linux layout selector display and use authoritative provider status instead of its hardcoded first/default index; preserve current selection until initial status arrives and do not submit a layout change from initialization or polling. Existing Linux runtime proxies Mac status correctly. Keep current compact dimensions and scope.
- [x] Test both layouts' exact per-host edge sets, rejection of empty/duplicate/invalid profiles, legacy ring migration, partial graph and returning center, failed configure/pending status, no mutation from polling, and no redundant restart of unchanged neighbors. Build Linux using the existing cache/toolchain; no live binary installation or input lifecycle from implementer.
- [x] Preserve preexisting Linux dirty work with fresh hash checks and baseline artifact; report exact source diffs, build/tests and migration instructions. Do not modify private candidate installer pins or identity/permission caches. Controller applies reviewed helpers, migrates actual profiles, verifies inward edge sets and asks for physical endpoint/through-center comparison.

## Final acceptance record

All implementation tasks passed their independent source gates. The final Mac Release and Linux native binary are installed with valid artifact hashes; existing input identities, grants and native binaries were preserved. Actual cross-host text and original PNG clipboard, shared pin/removal, bounded task progress, links/Markdown, Shelf hash retrieval, native remote media controls, all three processing executors and native bridge crash/reconnect were exercised. Common alert state matching, expiry, privacy and cancellation were covered by isolated meaningful tests; actual user infrastructure alerts were not dismissed.

The Mac interface was inspected live in its existing compact panels. Linux compiled/native/QML checks and actual service-environment clipboard checks passed; interactive remote Linux UI inspection was unavailable. The user physically confirmed the linear handoff and recovery from both input senders. A later read-only Windows check found its receiver ready with zero recovery restarts. This does not prove reboot, sleep or network-failure endurance.

The user clarified that normal files belong on the NAS. No new file workflow or NAS changes are part of acceptance. Only synthetic records and files created for these tests are removed; rollback bundles, source tests and unrelated user history remain. Repository publication follows the final whole-branch review and exact remote-head verification.
