# Porter as the casket-encrypted remote-FS primitive — design seed

**Date:** 2026-06-13
**Status:** design seed (operator-corrected reframe). Not build-now; captures the
primitive + the un-bake + the gating question.

## The reframe

**Porter is a casket-encrypted remote filesystem.** Backup was its FIRST
CONSUMER, not its definition — conflating the two is a category error (the same
instance-vs-primitive mistake as ledger's `assignee_aspect`, the dispatch-isn't-
a-pillar boundary, etc.).

Evidence in the code (`/home/operator/src/porter`):
- `internal/drive` = path-addressed CRUD over Drive: `List`, `Delete`, resumable
  chunked upload/download, folder resolution, backoff. Objects at paths.
- `internal/envelope` = per-path sealing: `RepoIdentity` + `ObjectPath` casket
  AAD binding. Each object encrypted to its path.
- Together: objects-at-paths, get/put/list/delete, encrypted per path = a remote
  encrypted FILESYSTEM.
- The backup-specific bits — `internal/{snapshot,manifest,retention}` + the 6h
  ticker (`cmd/porter-backup`) — are a LAYER ON TOP of the FS, one consumer.

## The tell / the un-bake

`envelope.RepoIdentity` is a hardcoded `const = "porter-backup"` — the first
consumer's identity welded into the primitive's AAD. To BE the reusable FS it
was designed as, parameterize RepoIdentity per consumer (backup →
"porter-backup", personal-cairn → its repo identity, satchel → another). Split
porter conceptually:
- **FS layer**: drive CRUD + per-path casket envelope, consumer-parameterized
  RepoIdentity. The reusable primitive.
- **Backup app**: snapshot + manifest + retention + ticker. ONE consumer of the
  FS.

## Consumers of the FS primitive

- **Backup** (today) — periodic snapshots → encrypted blobs.
- **Personal cairn storage tier** — a personal, single-user git whose canonical
  store is the porter-FS (casket-encrypted, in the person's OWN Drive,
  host-blind = e2e sovereignty), with a local working clone for live git. No
  cluster needed. The satchel pattern generalized from secrets to repos.
- **Satchel sync** (NEX-651) — `cw cred sync` of the personal credential bag
  over the same FS. Same casket→storage→sync spine.

## The gating question: FS semantics vs git's needs

NOT "backup vs storage" — the real constraint is whether the FS exposes what a
given git workload needs:
- Git wants atomic ref updates (rename), read-after-write consistency, locking
  for concurrent writers. Drive's NATIVE semantics are weak (no atomic rename,
  no locking, eventual-ish).
- **Personal / single-writer cairn: viable now.** No concurrency to lock;
  read-your-own-writes tractable; latency hidden behind a local working clone +
  porter-FS as canonical store. e2e to the person's key, in their Drive.
- **Multi-writer / platform / review-gating cairn: separate consistency
  problem.** Needs locking/atomicity Drive doesn't natively give → either the
  porter-FS layer provides a lock/consistency shim, or that mode keeps a
  low-latency store (PVC). The two cairn modes split here — semantics-rooted,
  not backup-rooted.

## Platform framing

Porter = a platform STORAGE PRIMITIVE: "casket-encrypted remote filesystem,"
provisioned and pointed-at by consumers — the same shape as
encrypted-DB-as-a-platform-type and the assemble-and-broker pattern. Backup,
personal-cairn, satchel-sync are consumers, not forks.

## Relates / next

- NEX-651 (cw cred sync via cairn) — a direct consumer; this seed is its
  storage substrate.
- cairn (two modes: live collaborative platform host w/ identity-native review
  gating vs personal Drive-backed single-writer store — don't conflate).
- The credential architecture (satchel local tier + e2e) and tenant sovereignty.
- Possible follow-up ticket: "un-bake porter into FS-primitive + backup-consumer
  (parameterize RepoIdentity)" — file when this moves from seed to build.
