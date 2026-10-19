# Automatic Linux clipboard image cache cleanup

**Goal:** Reclaim retired PNGs automatically while retaining history and active transfers.
**Spec:** `docs/superpowers/specs/2026-10-19-linux-image-cache-gc.md`
**Global Constraints:** Only owned image cache; preserve referenced/pinned/in-flight images and external originals; preserve unrelated dirty Linux work, private configuration and working input; no keys/personal network data in Git/docs; no new permissions/infrastructure/UI change.
**Review Focus:** Ownership, transfer lifetime, persistence failure, references at deletion, bounded scheduling and incremental package provenance.

### Task 1: Implement, validate and package cache retirement

**Files:** Native Linux ClipboardStore/header and focused tests as needed; canonical incremental patch/manifest and generic guide note.

- [ ] Verify fresh protected baseline; edit only feature-owned files.
- [ ] Implement automatic cleanup per spec without changing clipboard/privacy/pins/retention.
- [ ] Run isolated filesystem/async regressions and affected clipboard/continuity native checks; build using existing Qt workaround. No actual OS clipboard/input/service operations in agent tests.
- [ ] Refresh exact incremental package against original prepared baseline, preserving existing prerequisite/before hashes; record new owned test paths honestly. Verify application/hashes. Commit canonical owned changes and report tests/artifacts. No deployment or remote Git mutations.

### Task 2: Controller rollout and publication

- [ ] Independent task/final review; back up actual cache/history; deploy only reviewed native binary with helper/input protections.
- [ ] Verify actual retained metadata/images, known orphan cleanup, app/input readiness; remove fixtures.
- [ ] Publish authorized private/public/Forgejo mirrors with scans/exact heads, save shared memory, preserve rollback, export decisions and remove plan scratch.
