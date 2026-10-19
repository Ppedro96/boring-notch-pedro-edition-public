# Shared Notch continuity

The user approved all eight integrations: shared desktop state/layout, clipboard and pins (text, links, images), a shared Shelf with real file retrieval, one durable processing queue, media control between the two computers, links/captures, common alert acknowledgements, and agent task visibility. Both native interfaces must remain compact and retain local functionality. The always-on Linux computer coordinates state over existing private SSH access; sleeping the Mac must not stop storage or Linux/Windows jobs.

## Transport and ownership

Use only Python's standard library for the common service/client. Run `continuity-server.py --stdio --peer PEER --root ROOT` through existing SSH, or locally on the coordinator. Multiple stdio sessions share SQLite WAL state. No new public listener, infrastructure, DNS, or credentials in source. A private `continuity/config.json` beside the installed integrations describes `peer`, `server` (`ssh`, optional `python`, `root`, and `script`), and local runtime paths. Resolve paths relative to the user's home when possible. Default configuration is disabled; lack of configuration preserves existing local features.

The native application runs `continuity-client.py --stdio --config CONFIG`. UTF-8 NDJSON requests carry a unique string `id`; responses contain the same `id`, `ok`, and data or a bounded `error`. Unsolicited frames are `event` frames. The bridge must reconnect with bounded backoff, drain stderr, and terminate its own children on exit. A private local cache/outbox retains accepted shared changes while offline. Do not replay media actions or stale clipboard activation. Announce connection state separately from content. Restrict local storage to the current user.

## Stable native API

* `watch`, `topics:[...]`: subscribe; emits one snapshot per topic, then changed snapshots. Snapshot frame: `event:"snapshot",topic,revision,items`. Each item is `{id,origin,updatedAt,payload}`. `updatedAt` is a server Unix timestamp; revision is a monotonic server revision. Tombstones do not appear in snapshots. `get` returns the same snapshot for one topic.
* `put`, `topic`, `key`, `payload`, `mutationId`: upsert with idempotent mutation identity. `patch` merges payload fields atomically (pinning must not overwrite newer content). `delete` creates a tombstone. Mutations return `ok` and the committed revision, or `queued:true` while offline. Snapshots distinguish cached/replayed data, and startup snapshots never replace the system clipboard.
* `stage_file`, `path`: locally selected regular file only; upload bounded chunks with SHA-256 verification and atomic publication. Response `blob:{sha256,size,name}`. `fetch_blob`, `blob`: returns a verified local cache `path`. Reject traversal, symlinks, invalid hashes, oversize frames/chunks, and partial/corrupt files. Server-side operations are `upload_start`, `upload_chunk`, `upload_finish`, `blob_read`; temporary upload ids are bound to the authenticated peer. Maximum blob 2 GiB, chunk 512 KiB, PNG 20 MiB; reserve at least 1 GiB free disk. No shell-interpolated user paths. Do not auto-upload existing private history/files.
* `send_command`, `target`, `action`, `arguments`: allow only media play/pause/toggle/next/previous/seek/raise. Commands expire after 10 seconds, never queue offline, and emit `event:"command",commandId,target,action,arguments` only to the target's current session. `ack_command`, `commandId`, `ok`, optional `error`. Duplicate deliveries must not execute twice; keep consumed ids locally. Commands are not arbitrary shell operations.
* `desk`, `request:{...}`: common coordinator routes the allowlisted desk broker commands. Existing command/result shapes remain compatible, with `layout` and `inputMode` added to status. The server's local desk broker must have an explicit bypass entry point to prevent routing recursion. Do not block topic subscriptions on long transfers or desk actions.

Topic payload contracts:

| Topic | Key | Payload |
|---|---|---|
| clipboard | content SHA-256 | `kind:text/link/image`, `text` (exact whitespace, max 256 KiB), optional `blob` (PNG), `label`, `pinned`, `capturedAt`; no private MIME content |
| shelf | UUID | `kind:file/text/link`, `name`, `text` or `url` or `blob`, `createdAt`; never macOS bookmarks |
| links | UUID | `title`, `url`, `note`, `createdAt`, optional Markdown `blob`; Markdown retains `sync:false` |
| alerts | alert id + state hash | `alertId`, `stateHash`, `dismissed:true`; only matching shared infrastructure alerts |
| tasks | peer + task id | `taskId`, `host`, `agent`, `title`, `status`, `progress`, `summary`, `updatedAt`, optional result `blob`; no transcript, tokens, or permission answers |
| media | peer | `host`, `title`, `artist`, `album`, `playing`, `duration`, `position`, `available`, `updatedAt`; stale peers shown unavailable |
| desk | state | `layout`, `active`, `inputMode`, `updatedAt`; actual status remains authoritative |

Clipboard ingestion must skip concealed, transient, autogenerated, password-manager and private types. Fix the Linux Klipper polling bypass before publishing anything. Use event/content ids to suppress echo. Automatically apply only a newly received clipboard change captured within 30 seconds, never initial/replayed snapshots. Copying a shared item manually works offline if cached. Pins and deletions are common. Preserve local clipboard until explicit valid remote content arrives.

Processing: one FIFO per executor on Linux, protected by existing queue locks. Retain input and result metadata on the coordinator. Both clients submit after verified staging, see the same ids/progress, cancel/archive, retry retained input, and download verified results to their own filesystem. A remote result path must never be opened directly on another host. Preserve previous jobs/results and all three executors. Migrate only with no active jobs, otherwise keep following active old jobs until terminal.

Desktop: preserve active Lan Mouse and native grants. Shared layout/status must reflect the existing topology; do not stop working input during installation. Starting/pausing from either Notch controls the same session. The coordinator must permit Linux/Windows peer connectivity when the Mac is unavailable and report partial availability accurately. Never regenerate identities or delete portal tokens. Home returns control to the physical source in mesh mode.

## Native presentation and verification

Integrate shared items in the corresponding existing tabs, with small host/connection indicators and explicit local/remote media choice. Do not add a large new top-level dashboard or crowd buttons. Shelf entries fetch on demand and support removal; shared task details do not approve security prompts. All new vertical lists use the existing scroll-close guard. Preserve native widgets, local playback, Mixer, and disabled Dock previews.

Meaningful automated checks must cover concurrent updates, idempotence, reconnect/cache, private clipboard exclusion, echo suppression, corrupt/transversal blobs, queue authority/result retrieval/cancellation, stale media commands, matching alert hashes, and independent task origins. Build both native applications and test real cross-host synthetic data. Report physical input/visual limits truthfully. Do not change other active services, credentials, camera/ADB, OS packages, or existing unrelated worktree changes.

Latest explicit desktop clarification: geometry is linear, never wraparound. With the Windows computer on the left and Linux on the right, each endpoint exits only toward the center Mac; outer sides stay local. Reverse consistently for the alternate layout. If the Mac is unavailable, the two remaining hosts may connect directly using only their inward-facing edges, preserving partial availability. This supersedes the original implementation's ring assumption. Polling remains read-only; migration/rejoining is explicit.


Latest daily-use acceptance priorities: clipboard, media, desktop handoff/status, alerts and bounded task visibility. Existing optional file capabilities remain, but ordinary file storage stays with the user's NAS. Remove only this rollout's positively identified synthetic records and files after verification; preserve user history, unrelated work and rollback artifacts. Shared task presentation places active/waiting records before terminal history, then source update time descending and stable ID, without changing stored content or dropping history.
