# Linux clipboard image cache retirement

User explicitly requests automatic cleanup of the Linux image cache to close continuity M1.

Reclaim only unreferenced ClipboardStore PNGs in its owned image cache. Preserve all current history references, pinned/shared entries and files needed by in-flight uploads or other operations. Existing fourteen-day / hundred-unpinned history retention stays unchanged. Originals, external/symlink targets, unknown files, transport blobs, processing results and unrelated data are outside scope.

Cleanup runs automatically for existing startup orphans and after history retirement/removal, with recurring maintenance where needed. Coalesce and bound work for large old caches; do not scan on each clipboard poll or block the UI with unbounded work. Recheck current references before deletion. Failed history persistence must preserve files required by durable metadata. Completed/failed async operations release protection for later collection.

Preserve Wayland writer ownership/privacy/generation fences and original PNG bytes, existing shared behavior and native input. No UI redesign, new permissions, OS packages or infrastructure. Preserve preexisting Linux edits and the private Mac environment. Documentation remains generic without keys, personal domains/network data, machine/device names or runtime/install paths.

Meaningful isolated temporary-file/delayed-transfer regressions cover prune/remove/startup orphans; referenced/pinned images; in-flight then complete/fail transfers; persistence failure; unknown files/symlinks/external originals; relevant clipboard behavior. Build with the existing Qt workaround. Controller backs up actual cache/history, deploys reviewed app binary only, verifies a known orphan plus retained files/app/input, cleans fixtures and publishes to the already authorized mirrors.
