# Porter as the casket-encrypted remote-FS primitive — design seed

**Date:** 2026-06-13
**Status:** design seed (operator-corrected reframe). Not build-now; captures the
primitive + the un-bake + the gating question.

## The reframe

**Porter is a MOUNTED casket-encrypting filesystem**: a normal POSIX filesystem
at the mount point, encrypted casket objects at the backing. Backup was its
FIRST CONSUMER, not its definition (instance-vs-primitive error, same as
ledger's `assignee_aspect`). And backup is a GOOD consumer — snapshot-to-
encrypted-objects is the right shape for "seal non-recoverable data so we can
restore"; not a misuse, keep it.

**The mount framing is load-bearing**: git (or anything) never sees Drive — it
sees the normal POSIX mount (atomic rename, locking, read-after-write, all
local/kernel). The encrypt-and-upload-to-objects happens transparently BELOW
POSIX. So "cairn on porter" = git running on the mount, with encrypted-object
durability free underneath — NOT a local-cache bolted onto a Drive backup;
porter IS that, as one filesystem. (This corrects the earlier object-CRUD-only
framing, which wrongly implied git couldn't run on it.)

Prior art: the rclone-mount + crypt / gocryptfs-over-object-remote pattern —
an encrypted FUSE mount over an object backend is well-trodden. Porter = that,
with casket as the crypt + our identity/recovery-key model (which off-the-shelf
rclone-crypt doesn't give).

Evidence in the code (`/home/operator/src/porter`):
- `internal/drive` = path-addressed CRUD over Drive: `List`, `Delete`, resumable
  chunked upload/download, folder resolution, backoff. Objects at paths.
- `internal/envelope` = per-path sealing: `RepoIdentity` + `ObjectPath` casket
  AAD binding. Each object encrypted to its path.
- Together: objects-at-paths, get/put/list/delete, encrypted per path = a remote
  encrypted FILESYSTEM.
- The backup-specific bits — `internal/{snapshot,manifest,retention}` + the 6h
  ticker (`cmd/porter-backup`) — are a LAYER ON TOP of the FS, one consumer.

## Three layers (where the work is)

1. **Encrypted-object backing** — casket → Drive objects (`internal/drive` CRUD
   + `internal/envelope` per-path sealing). BUILT; the backup app uses it
   directly (snapshots don't need a mount). The tell that backup leaked in:
   `envelope.RepoIdentity` is a hardcoded `const = "porter-backup"` — the first
   consumer's identity welded into the primitive's AAD. Un-bake: parameterize
   RepoIdentity per consumer (backup→"porter-backup", personal-cairn→its repo
   identity, satchel→another) — same fix as ledger's `assignee_aspect`.
2. **The mount** — FUSE presenting normal POSIX, transparently sealing writes →
   layer-1 objects and unsealing reads. DESIGNED, NOT YET BUILT (backup skipped
   it). This is the piece that makes cairn-personal + satchel trivial.
3. **Consumers** — backup (uses layer 1 directly, snapshot-style; good); 
   cairn-personal / satchel-sync (use the mount).

## Consumers of the FS primitive

- **Backup** (today) — periodic snapshots → encrypted blobs.
- **Personal cairn storage tier** — a personal, single-user git whose canonical
  store is the porter-FS (casket-encrypted, in the person's OWN Drive,
  host-blind = e2e sovereignty), with a local working clone for live git. No
  cluster needed. The satchel pattern generalized from secrets to repos.
- **Satchel sync** (NEX-651) — `cw cred sync` of the personal credential bag
  over the same FS. Same casket→storage→sync spine.

## The gating question: the MOUNT's cache/sync semantics

NOT "backup vs storage," and NOT "Drive's weak semantics" — git sees the normal
POSIX mount, so its needs (atomic rename, locking, read-after-write) are met
locally. The real question is the MOUNT's cache/sync design:
- **Personal / single-writer (cairn, satchel): easy, viable now.** Write-back
  cache + async seal-and-upload; no conflicts to arbitrate; e2e to the person's
  key, in their Drive, host-blind.
- **Multi-writer / platform / review-gating cairn: the genuinely hard
  distributed-FS problem** — conflict/lock arbitration at the sync layer. This
  is why collaborative/platform cairn stays on a low-latency store (PVC). The
  two cairn modes split HERE — in the mount's sync semantics, not in Drive.

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
