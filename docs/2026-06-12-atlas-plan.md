# Atlas (Strata Live Map) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build atlas — the read-only live map of the running Strata cloud (per `docs/2026-06-12-atlas-strata-viz-design.md`): collectors over k8s/mason/porter, `StrataService` in cwb-proto, herald-OIDC-protected web map at `atlas.tail41686e.ts.net`.

**Architecture:** New `atlas` repo following the mason pillar pattern (gRPC-over-mTLS, scratch image, GHCR release). One collector loop folds k8s + mason + porter into a mutex-guarded `CloudState` cache; a gRPC `StrataService` and a session-cookied web layer both serve from that cache. Status derivation is a pure function. Topology (nodes/edges) is static data. Porter grows a tiny `BackupStatusService`. Interchange registers the strata handler for edge REST.

**Tech Stack:** Go, cwb-proto (buf), k8s.io/client-go, google.golang.org/grpc, golang.org/x/oauth2 (RP side), stdlib html/template + embed. Vanilla JS/SVG page — no frontend framework.

**Dependencies:** Plan A (`2026-06-12-herald-authcode-plan.md`) gates ONLY Task B10's live login — develop everything against `ATLAS_DEV_INSECURE=1` + a stub herald meanwhile.

**Ordering note (proto first):** B1 must merge before B2/B4+ build against real generated code. Pin consumers to the cwb-proto pseudo-version after B1 merges (`go get github.com/CarriedWorldUniverse/cwb-proto@main`).

**Amendments (2026-06-12, B1 review — schema as MERGED in cwb-proto PR #15 differs from the snippets below):**
- `GetCloudStateResponse.backup` is a strata-local `BackupSummary` (last_success, last_attempt, last_error, `sources_count` int32, next_due) — NOT porter's `BackupStatus`. The mesh `BackupStatusService` keeps the full per-source `BackupStatus`; atlas's fold (B8) maps status → summary. The page (B11) reads `backup.sourcesCount`, not a sources array.
- `Node.since` is named `created_at` (protojson: `createdAt`) — B6/B8/B11 snippets referring to `Since`/`since` follow the rename.
- `BackupSource.size` is named `size_bytes` (B2's holder/server map `Source.Size` → proto `size_bytes`).
- **Edge path (B12 reality):** the gateway mounts pillars under a stripped prefix — StrataService is externally **`/atlas/api/strata/state`**, not bare `/api/strata/state`. B13 verification + B14 conformance must use the prefixed path.

---

### Task B1: cwb-proto — strata.proto + porter.proto

**Files:**
- Create: `/home/operator/src/cwb-proto/proto/cwb/v1/porter.proto`
- Create: `/home/operator/src/cwb-proto/proto/cwb/v1/strata.proto`

Branch in `/home/operator/src/cwb-proto`: `feat/strata-porter-services`. Match `mason.proto`'s style exactly (header comment, package `cwb.v1`, go_package option — copy them from `proto/cwb/v1/mason.proto:1-15`).

- [ ] **Step 1: Write porter.proto**

```proto
syntax = "proto3";

package cwb.v1;

import "google/protobuf/timestamp.proto";

option go_package = "github.com/CarriedWorldUniverse/cwb-proto/gen/go/cwb/v1;cwbv1";

// BackupStatusService reports porter-backup's sync state. Read-only,
// in-mesh (mTLS) — consumed by atlas for the map's backup clock.
service BackupStatusService {
  rpc GetBackupStatus(GetBackupStatusRequest) returns (GetBackupStatusResponse);
}

message GetBackupStatusRequest {}

message GetBackupStatusResponse {
  BackupStatus status = 1;
}

// BackupStatus is one porter instance's view of its last sync pass.
message BackupStatus {
  // last_success is when the last fully-successful pass completed (unset if
  // no pass has succeeded since porter started).
  google.protobuf.Timestamp last_success = 1;
  // last_attempt is when the most recent pass (success or not) completed.
  google.protobuf.Timestamp last_attempt = 2;
  // last_error is the most recent pass failure message ("" if it succeeded).
  string last_error = 3;
  // sources backed up in the last successful pass.
  repeated BackupSource sources = 4;
  // next_due is last_attempt + the configured sync interval.
  google.protobuf.Timestamp next_due = 5;
}

message BackupSource {
  string name = 1;  // e.g. "croft-home"
  int64 size = 2;   // plaintext bytes
}
```

- [ ] **Step 2: Write strata.proto**

```proto
syntax = "proto3";

package cwb.v1;

import "google/api/annotations.proto";
import "google/protobuf/timestamp.proto";
import "cwb/v1/porter.proto";

option go_package = "github.com/CarriedWorldUniverse/cwb-proto/gen/go/cwb/v1;cwbv1";

// StrataService is the read-only "cloud state" surface behind the live map.
// PERMANENTLY read-only: write RPCs belong to mason/almanac (design doc,
// "Ops seams"). atlas serves it; cw/MCP/the web page consume it.
service StrataService {
  rpc GetCloudState(GetCloudStateRequest) returns (GetCloudStateResponse) {
    option (google.api.http) = {
      get: "/api/strata/state"
    };
  }
}

message GetCloudStateRequest {}

message GetCloudStateResponse {
  repeated Node nodes = 1;
  repeated Edge edges = 2;
  BackupStatus backup = 3;
  // observed_at is when the snapshot was collected — staleness is part of
  // the contract, not an error.
  google.protobuf.Timestamp observed_at = 4;
}

enum NodeKind {
  NODE_KIND_UNSPECIFIED = 0;
  NODE_KIND_PILLAR = 1;        // the OS layer (herald, almanac, ...)
  NODE_KIND_APP = 2;           // workloads on the cloud (broker, aspects, ...)
  NODE_KIND_CROSS_CUTTING = 3; // mason, porter
  NODE_KIND_INFRA = 4;         // sqld, interchange edge
}

enum NodeStatus {
  NODE_STATUS_UNSPECIFIED = 0;
  NODE_STATUS_UP = 1;
  NODE_STATUS_DEGRADED = 2;    // 0 < ready < desired
  NODE_STATUS_DOWN = 3;        // ready == 0, desired > 0
  NODE_STATUS_DORMANT = 4;     // desired == 0 — benched on purpose, not broken
}

message Node {
  string id = 1;                            // "herald", "nexus-broker", "croft"
  NodeKind kind = 2;
  string namespace = 3;
  NodeStatus status = 4;
  string version = 5;                       // human-readable pin, e.g. "sha-947a05e"
  string image_digest = 6;                  // full sha256 digest
  int32 ready = 7;
  int32 desired = 8;
  google.protobuf.Timestamp since = 9;      // deployment creation
  string detail = 10;                       // mason phase for managed apps; "" otherwise
  bool stale = 11;                          // true when this node's source collector failed last pass
}

enum EdgeKind {
  EDGE_KIND_UNSPECIFIED = 0;
  EDGE_KIND_REQUEST = 1;   // A calls B
  EDGE_KIND_RECONCILE = 2; // mason -> workloads
  EDGE_KIND_BACKUP = 3;    // porter -> offsite
}

// Edge is STATIC topology (the ARCHITECTURE.md shape), annotated — what
// should connect, not live traffic discovery.
message Edge {
  string from = 1;
  string to = 2;
  EdgeKind kind = 3;
}
```

- [ ] **Step 3: Generate + lint**

Run: `cd /home/operator/src/cwb-proto && buf lint && buf generate`
Expected: no lint errors; `gen/go/cwb/v1/{strata,porter}*.go` appear (including `strata.pb.gw.go`).

- [ ] **Step 4: Commit, push, PR, merge**

```bash
git add proto/cwb/v1/porter.proto proto/cwb/v1/strata.proto gen/
git commit -m "feat: StrataService (cloud-state map API) + porter BackupStatusService"
git push -u origin feat/strata-porter-services
gh pr create --title "StrataService + porter BackupStatusService" --body "Read-only cloud-state API for atlas (the Strata live map) + porter's backup clock. Per carriedworld-cloud docs/2026-06-12-atlas-strata-viz-design.md"
```

Merge when CI is green (squash, delete branch). Record the new pseudo-version: `go list -m github.com/CarriedWorldUniverse/cwb-proto@main`.

---

### Task B2: porter — BackupStatusService

**Files (in `/home/operator/src/porter`, branch `feat/backup-status-grpc`):**
- Create: `internal/status/status.go`
- Create: `internal/status/status_test.go`
- Create: `internal/status/server.go`
- Create: `internal/status/server_test.go`
- Modify: `cmd/porter-backup/main.go` (record pass results; start gRPC server)
- Modify: `cmd/porter-backup/env.go` (new env vars)

- [ ] **Step 1: Write the failing holder test** (`internal/status/status_test.go`)

```go
package status

import (
	"testing"
	"time"
)

func TestHolderRecordsPasses(t *testing.T) {
	h := NewHolder(6 * time.Hour)
	if got := h.Get(); got.LastAttempt != nil {
		t.Fatal("fresh holder must be empty")
	}

	now := time.Date(2026, 6, 12, 16, 0, 0, 0, time.UTC)
	h.RecordSuccess(now, []Source{{Name: "sqld", Size: 7868657}})
	got := h.Get()
	if got.LastSuccess == nil || !got.LastSuccess.Equal(now) {
		t.Fatalf("LastSuccess = %v", got.LastSuccess)
	}
	if got.LastError != "" || len(got.Sources) != 1 || got.Sources[0].Name != "sqld" {
		t.Fatalf("got %+v", got)
	}
	if want := now.Add(6 * time.Hour); !got.NextDue.Equal(want) {
		t.Fatalf("NextDue = %v want %v", got.NextDue, want)
	}

	later := now.Add(6 * time.Hour)
	h.RecordFailure(later, "drive: 503")
	got = h.Get()
	if got.LastError != "drive: 503" {
		t.Fatalf("LastError = %q", got.LastError)
	}
	if !got.LastSuccess.Equal(now) {
		t.Fatal("failure must not clobber LastSuccess")
	}
	if !got.LastAttempt.Equal(later) {
		t.Fatal("LastAttempt must advance on failure")
	}
	if len(got.Sources) != 1 {
		t.Fatal("failure must not clobber last good sources")
	}
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd /home/operator/src/porter && go test ./internal/status/ -v`
Expected: FAIL — package doesn't exist

- [ ] **Step 3: Implement the holder** (`internal/status/status.go`)

```go
// Package status holds porter's last-pass state and serves it over gRPC
// (cwb.v1.BackupStatusService) — the map's backup clock. State is in-memory:
// porter restarts show "no pass yet" until the next tick, which is honest.
package status

import (
	"sync"
	"time"
)

// Source is one backed-up source in the last successful pass.
type Source struct {
	Name string
	Size int64
}

// Snapshot is a copy of the holder's state (pointers are nil when unset).
type Snapshot struct {
	LastSuccess *time.Time
	LastAttempt *time.Time
	LastError   string
	Sources     []Source
	NextDue     time.Time
}

// Holder records sync-pass outcomes; safe for concurrent use.
type Holder struct {
	mu       sync.Mutex
	interval time.Duration
	s        Snapshot
}

// NewHolder builds a Holder; interval is the sync ticker period (for NextDue).
func NewHolder(interval time.Duration) *Holder {
	return &Holder{interval: interval}
}

// RecordSuccess notes a completed pass and its sources.
func (h *Holder) RecordSuccess(at time.Time, sources []Source) {
	h.mu.Lock()
	defer h.mu.Unlock()
	t := at
	h.s.LastSuccess = &t
	h.s.LastAttempt = &t
	h.s.LastError = ""
	h.s.Sources = append([]Source(nil), sources...)
	h.s.NextDue = at.Add(h.interval)
}

// RecordFailure notes a failed pass; the last good sources/success stand.
func (h *Holder) RecordFailure(at time.Time, msg string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	t := at
	h.s.LastAttempt = &t
	h.s.LastError = msg
	h.s.NextDue = at.Add(h.interval)
}

// Get returns a copy of the current snapshot.
func (h *Holder) Get() Snapshot {
	h.mu.Lock()
	defer h.mu.Unlock()
	out := h.s
	out.Sources = append([]Source(nil), h.s.Sources...)
	return out
}
```

- [ ] **Step 4: Run holder test — PASS, commit**

```bash
git add internal/status/status.go internal/status/status_test.go
git commit -m "feat(status): in-memory last-pass holder for the backup clock"
```

- [ ] **Step 5: Write the failing gRPC server test** (`internal/status/server_test.go`)

```go
package status

import (
	"context"
	"testing"
	"time"

	cwbv1 "github.com/CarriedWorldUniverse/cwb-proto/gen/go/cwb/v1"
)

func TestGetBackupStatus(t *testing.T) {
	h := NewHolder(6 * time.Hour)
	srv := NewServer(h)

	// Empty holder: response present, timestamps unset.
	resp, err := srv.GetBackupStatus(context.Background(), &cwbv1.GetBackupStatusRequest{})
	if err != nil {
		t.Fatal(err)
	}
	if resp.GetStatus().GetLastAttempt() != nil {
		t.Fatal("empty holder must yield unset last_attempt")
	}

	now := time.Date(2026, 6, 12, 16, 0, 0, 0, time.UTC)
	h.RecordSuccess(now, []Source{{Name: "sqld", Size: 42}})
	resp, err = srv.GetBackupStatus(context.Background(), &cwbv1.GetBackupStatusRequest{})
	if err != nil {
		t.Fatal(err)
	}
	st := resp.GetStatus()
	if st.GetLastSuccess().AsTime() != now || len(st.GetSources()) != 1 || st.GetSources()[0].GetName() != "sqld" {
		t.Fatalf("status = %+v", st)
	}
	if st.GetNextDue().AsTime() != now.Add(6*time.Hour) {
		t.Fatalf("next_due = %v", st.GetNextDue().AsTime())
	}
}
```

- [ ] **Step 6: Implement the server** (`internal/status/server.go`)

```go
package status

import (
	"context"

	cwbv1 "github.com/CarriedWorldUniverse/cwb-proto/gen/go/cwb/v1"
	"google.golang.org/protobuf/types/known/timestamppb"
)

// Server serves cwb.v1.BackupStatusService from a Holder.
type Server struct {
	cwbv1.UnimplementedBackupStatusServiceServer
	h *Holder
}

// NewServer wires the service to the holder.
func NewServer(h *Holder) *Server { return &Server{h: h} }

// GetBackupStatus reports the last pass. No authz beyond mesh mTLS: the data
// is operational metadata, and the mesh boundary is the trust boundary.
func (s *Server) GetBackupStatus(_ context.Context, _ *cwbv1.GetBackupStatusRequest) (*cwbv1.GetBackupStatusResponse, error) {
	snap := s.h.Get()
	st := &cwbv1.BackupStatus{LastError: snap.LastError}
	if snap.LastSuccess != nil {
		st.LastSuccess = timestamppb.New(*snap.LastSuccess)
	}
	if snap.LastAttempt != nil {
		st.LastAttempt = timestamppb.New(*snap.LastAttempt)
		st.NextDue = timestamppb.New(snap.NextDue)
	}
	for _, src := range snap.Sources {
		st.Sources = append(st.Sources, &cwbv1.BackupSource{Name: src.Name, Size: src.Size})
	}
	return &cwbv1.GetBackupStatusResponse{Status: st}, nil
}
```

Run `go get github.com/CarriedWorldUniverse/cwb-proto@main && go mod tidy` first (pulls B1's merge).

- [ ] **Step 7: Run — PASS, commit**

```bash
git add internal/status/ go.mod go.sum
git commit -m "feat(status): BackupStatusService gRPC server"
```

- [ ] **Step 8: Wire main.go**

In `cmd/porter-backup/main.go`:
(a) construct `holder := status.NewHolder(every)` next to the ticker setup (~line 143);
(b) in the loop, replace the bare `pass()` call so outcomes are recorded:

```go
		if err := pass(); err != nil {
			log.Error("sync pass failed", "error", err.Error())
			holder.RecordFailure(time.Now().UTC(), err.Error())
		}
```

and inside the success path (where "sync pass complete" logs, ~line 127, where manifest `m` is in scope):

```go
	var srcs []status.Source
	for _, se := range m.Sources {
		srcs = append(srcs, status.Source{Name: se.Name, Size: se.Size})
	}
	holder.RecordSuccess(time.Now().UTC(), srcs)
```

(adapt: if `pass()` doesn't expose the manifest, thread the holder into the function that has `m` — keep the recording at the single point where the pass outcome is known);
(c) start the gRPC server before the loop (mason's exact server pattern — copy `serverOptions()` from `/home/operator/src/mason/cmd/mason/main.go:185-216`, renaming env vars):

```go
	// BackupStatusService (the map's backup clock) — mTLS like every pillar.
	if addr := envOr("PORTER_GRPC_ADDR", ":8087"); addr != "" {
		grpcSrv := grpc.NewServer(serverOptions()...) // PORTER_SERVER_TLS_CERT/_KEY/_CA, PORTER_DEV_INSECURE
		cwbv1.RegisterBackupStatusServiceServer(grpcSrv, status.NewServer(holder))
		lis, err := net.Listen("tcp", addr)
		if err != nil {
			return fmt.Errorf("status listen %s: %w", addr, err)
		}
		go func() {
			if err := grpcSrv.Serve(lis); err != nil {
				log.Error("status grpc serve", "error", err.Error())
			}
		}()
		log.Info("backup status grpc listening", "addr", addr)
	}
```

Env additions in `env.go`: `PORTER_GRPC_ADDR` (default `:8087`), `PORTER_SERVER_TLS_CERT/_KEY/_CA`, `PORTER_DEV_INSECURE`. NOTE: the existing `PORTER_TLS_*` vars are porter's CLIENT certs — do not reuse them for the server listener.

- [ ] **Step 9: Build + full suite, commit, push, PR**

Run: `go build ./... && go test ./...` — PASS.

```bash
git add cmd/porter-backup/
git commit -m "feat: serve BackupStatusService — record pass outcomes, mTLS gRPC on :8087"
git push -u origin feat/backup-status-grpc
gh pr create --title "porter: BackupStatusService (backup clock for the Strata map)" --body "Per carriedworld-cloud docs/2026-06-12-atlas-strata-viz-design.md — exposes last-pass state over mesh mTLS. No deploy-ordering constraint with atlas."
```

- [ ] **Step 10: Manifest follow-up (deploy whenever)** — in carriedworld-cloud `hosting/services/porter-backup.yaml`: add a server Certificate (copy the commonplace server-cert pattern: secret `porter-backup-tls`, dnsNames `porter-backup.cwb.svc`, `porter-backup.cwb.svc.cluster.local`, usages `[server auth]`, issuer `cwb-ca`), mount at `/etc/porter/server-tls`, set `PORTER_SERVER_TLS_CERT/_KEY/_CA` env, add a Service (ClusterIP, port 8087), bump the image pin after merge. Commit before apply.

---

### Task B3: atlas repo scaffold

**Files (new repo `/home/operator/src/atlas`):**
- Create: `go.mod`, `README.md`, `.gitignore`
- Create: `cmd/atlas/main.go` (compiling skeleton)
- Create: `cmd/atlas/Containerfile`
- Create: `.github/workflows/ci.yml`, `.github/workflows/release-image.yml`

- [ ] **Step 1: Create the repo**

```bash
mkdir -p /home/operator/src/atlas && cd /home/operator/src/atlas
git init -b main
go mod init github.com/CarriedWorldUniverse/atlas
go get github.com/CarriedWorldUniverse/cwb-proto@main \
      google.golang.org/grpc k8s.io/client-go@latest k8s.io/api@latest k8s.io/apimachinery@latest \
      golang.org/x/oauth2
```

- [ ] **Step 2:** `README.md` — three sentences: what atlas is (live map / human-web gateway, "mason does, atlas sees"), pointer to the design doc in carriedworld-cloud, how to run tests.

- [ ] **Step 3:** Minimal `cmd/atlas/main.go` that compiles (full wiring lands in B9):

```go
// atlas is Strata's live map: collectors over k8s/mason/porter feed one
// CloudState cache, served as cwb.v1.StrataService (gRPC-mTLS) and as a
// herald-OIDC-protected web map. Read-only by design: mason does, atlas sees.
package main

import "log"

func main() {
	log.Fatal(run())
}

func run() error {
	return nil // wired up task by task
}
```

- [ ] **Step 4:** `cmd/atlas/Containerfile` — copy `/home/operator/src/mason/cmd/mason/Containerfile` verbatim, replacing `mason` with `atlas` (build path `./cmd/atlas`, EXPOSE 8089 8443).

- [ ] **Step 5:** Workflows — copy mason's `.github/workflows/release-image.yml` replacing the image name with `ghcr.io/carriedworlduniverse/atlas` and the Containerfile path; `ci.yml` runs `go vet ./... && go test ./...` on PRs (copy mason's CI if one exists: `ls /home/operator/src/mason/.github/workflows/`).

- [ ] **Step 6: Commit; create the GitHub repo**

```bash
git add -A && git commit -m "scaffold: atlas — Strata live map (pillar pattern)"
gh repo create CarriedWorldUniverse/atlas --private --source . --push
```

---

### Task B4: derive — pure status derivation

**Files:**
- Create: `internal/derive/derive.go`
- Test: `internal/derive/derive_test.go`

- [ ] **Step 1: Failing test**

```go
package derive

import (
	"testing"

	cwbv1 "github.com/CarriedWorldUniverse/cwb-proto/gen/go/cwb/v1"
)

func TestStatus(t *testing.T) {
	tests := []struct {
		name           string
		ready, desired int32
		want           cwbv1.NodeStatus
	}{
		{"all ready", 1, 1, cwbv1.NodeStatus_NODE_STATUS_UP},
		{"multi all ready", 2, 2, cwbv1.NodeStatus_NODE_STATUS_UP},
		{"partial", 1, 2, cwbv1.NodeStatus_NODE_STATUS_DEGRADED},
		{"none of some", 0, 1, cwbv1.NodeStatus_NODE_STATUS_DOWN},
		{"benched on purpose", 0, 0, cwbv1.NodeStatus_NODE_STATUS_DORMANT}, // roster policy: grey, never red
		{"over-ready transient", 3, 2, cwbv1.NodeStatus_NODE_STATUS_UP},    // rollout overlap
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := Status(tt.ready, tt.desired); got != tt.want {
				t.Fatalf("Status(%d,%d) = %v, want %v", tt.ready, tt.desired, got, tt.want)
			}
		})
	}
}

func TestSplitImage(t *testing.T) {
	tests := []struct {
		in, wantVer, wantDigest string
	}{
		{"ghcr.io/carriedworlduniverse/mason:sha-1cb7717@sha256:86e94eb", "sha-1cb7717", "sha256:86e94eb"},
		{"ghcr.io/tursodatabase/libsql-server:latest", "latest", ""},
		{"localhost/keel:dev", "dev", ""},
		{"no-tag-image", "", ""},
	}
	for _, tt := range tests {
		ver, digest := SplitImage(tt.in)
		if ver != tt.wantVer || digest != tt.wantDigest {
			t.Fatalf("SplitImage(%q) = %q,%q want %q,%q", tt.in, ver, digest, tt.wantVer, tt.wantDigest)
		}
	}
}
```

- [ ] **Step 2:** Run `go test ./internal/derive/ -v` — FAIL (undefined).

- [ ] **Step 3: Implement**

```go
// Package derive turns raw deployment facts into map semantics. Pure
// functions only — this is the one place the UP/DEGRADED/DOWN/DORMANT
// meaning lives.
package derive

import (
	"strings"

	cwbv1 "github.com/CarriedWorldUniverse/cwb-proto/gen/go/cwb/v1"
)

// Status derives a node's lamp from replica counts. DORMANT (desired=0) is
// deliberate bench, not failure — the aspect roster policy keeps idle
// specialists at 0/0 on purpose; the map must show grey, never red.
func Status(ready, desired int32) cwbv1.NodeStatus {
	switch {
	case desired == 0:
		return cwbv1.NodeStatus_NODE_STATUS_DORMANT
	case ready == 0:
		return cwbv1.NodeStatus_NODE_STATUS_DOWN
	case ready < desired:
		return cwbv1.NodeStatus_NODE_STATUS_DEGRADED
	default:
		return cwbv1.NodeStatus_NODE_STATUS_UP
	}
}

// SplitImage splits an image ref into the human-readable tag ("version") and
// the pinned digest (empty when unpinned).
func SplitImage(image string) (version, digest string) {
	rest := image
	if i := strings.Index(rest, "@"); i >= 0 {
		digest = rest[i+1:]
		rest = rest[:i]
	}
	// tag = text after the last ':' that comes after the last '/'
	// (avoids reading a registry port as a tag)
	slash := strings.LastIndex(rest, "/")
	if colon := strings.LastIndex(rest, ":"); colon > slash {
		version = rest[colon+1:]
	}
	return version, digest
}
```

- [ ] **Step 4:** Run — PASS. **Step 5: Commit** `feat(derive): status + image-pin derivation (DORMANT is first-class)`.

---

### Task B5: topology — the static map shape

**Files:**
- Create: `internal/topology/topology.go`
- Test: `internal/topology/topology_test.go`

The ARCHITECTURE.md shape as data. Workload nodes carry namespace+deployment so collectors can join k8s facts; abstract nodes (you/cw/drive) exist only for edges.

- [ ] **Step 1: Failing test**

```go
package topology

import (
	"testing"

	cwbv1 "github.com/CarriedWorldUniverse/cwb-proto/gen/go/cwb/v1"
)

func TestTopologyIntegrity(t *testing.T) {
	ids := map[string]bool{}
	for _, n := range Nodes {
		if ids[n.ID] {
			t.Errorf("duplicate node id %s", n.ID)
		}
		ids[n.ID] = true
		if n.Workload != nil && (n.Workload.Namespace == "" || n.Workload.Deployment == "") {
			t.Errorf("node %s: workload needs namespace+deployment", n.ID)
		}
	}
	for _, e := range Edges {
		if !ids[e.From] || !ids[e.To] {
			t.Errorf("edge %s->%s references unknown node", e.From, e.To)
		}
	}
	// the platform's known shape — guard against accidental deletion
	for _, must := range []string{"herald", "almanac", "custodian", "cairn", "ledger",
		"commonplace", "mason", "porter-backup", "interchange", "sqld",
		"nexus-broker", "lynxai", "croft", "atlas"} {
		if !ids[must] {
			t.Errorf("missing expected node %s", must)
		}
	}
	if Kind("herald") != cwbv1.NodeKind_NODE_KIND_PILLAR {
		t.Error("herald must be a pillar")
	}
}
```

- [ ] **Step 2:** Run — FAIL. **Step 3: Implement**

```go
// Package topology is the static map shape: the ARCHITECTURE.md diagram as
// data. Adding a node to the platform = one entry here (+ the SVG layout in
// web/static). Edges say what SHOULD connect; live lamps say what's alive.
package topology

import cwbv1 "github.com/CarriedWorldUniverse/cwb-proto/gen/go/cwb/v1"

// Workload binds a node to its k8s deployment (nil for abstract nodes).
type Workload struct {
	Namespace  string
	Deployment string // deployment name; croft is a statefulset — see Kind note
}

// Node is one box on the map.
type Node struct {
	ID       string
	Kind     cwbv1.NodeKind
	Workload *Workload
	// StatefulSet marks the rare workload that isn't a Deployment.
	StatefulSet bool
}

// Nodes is every box. Order is irrelevant (layout lives in the SVG).
var Nodes = []Node{
	// pillars — the OS
	{ID: "herald", Kind: cwbv1.NodeKind_NODE_KIND_PILLAR, Workload: &Workload{"cwb", "herald"}},
	{ID: "almanac", Kind: cwbv1.NodeKind_NODE_KIND_PILLAR, Workload: &Workload{"cwb", "almanac"}},
	{ID: "custodian", Kind: cwbv1.NodeKind_NODE_KIND_PILLAR, Workload: &Workload{"cwb", "custodian"}},
	{ID: "cairn", Kind: cwbv1.NodeKind_NODE_KIND_PILLAR, Workload: &Workload{"cwb", "cairn"}},
	{ID: "ledger", Kind: cwbv1.NodeKind_NODE_KIND_PILLAR, Workload: &Workload{"cwb", "ledger"}},
	{ID: "commonplace", Kind: cwbv1.NodeKind_NODE_KIND_PILLAR, Workload: &Workload{"cwb", "commonplace"}},
	// cross-cutting
	{ID: "mason", Kind: cwbv1.NodeKind_NODE_KIND_CROSS_CUTTING, Workload: &Workload{"cwb", "mason"}},
	{ID: "porter-backup", Kind: cwbv1.NodeKind_NODE_KIND_CROSS_CUTTING, Workload: &Workload{"cwb", "porter-backup"}},
	// infra
	{ID: "interchange", Kind: cwbv1.NodeKind_NODE_KIND_INFRA, Workload: &Workload{"cwb", "interchange-gateway"}},
	{ID: "sqld", Kind: cwbv1.NodeKind_NODE_KIND_INFRA, Workload: &Workload{"cwb", "sqld"}},
	{ID: "atlas", Kind: cwbv1.NodeKind_NODE_KIND_INFRA, Workload: &Workload{"cwb", "atlas"}},
	// apps — workloads ON the cloud
	{ID: "nexus-broker", Kind: cwbv1.NodeKind_NODE_KIND_APP, Workload: &Workload{"nexus", "nexus-broker"}},
	{ID: "keel", Kind: cwbv1.NodeKind_NODE_KIND_APP, Workload: &Workload{"nexus", "keel"}},
	{ID: "maren", Kind: cwbv1.NodeKind_NODE_KIND_APP, Workload: &Workload{"nexus", "maren"}},
	{ID: "anvil", Kind: cwbv1.NodeKind_NODE_KIND_APP, Workload: &Workload{"nexus", "anvil"}},
	{ID: "harrow", Kind: cwbv1.NodeKind_NODE_KIND_APP, Workload: &Workload{"nexus", "harrow"}},
	{ID: "gemma", Kind: cwbv1.NodeKind_NODE_KIND_APP, Workload: &Workload{"nexus", "gemma-ollama"}},
	{ID: "lynxai", Kind: cwbv1.NodeKind_NODE_KIND_APP, Workload: &Workload{"nexus", "lynxai"}},
	{ID: "croft", Kind: cwbv1.NodeKind_NODE_KIND_APP, Workload: &Workload{"croft", "croft"}, StatefulSet: true},
	// abstract (edges only; no workload, no lamp)
	{ID: "you", Kind: cwbv1.NodeKind_NODE_KIND_UNSPECIFIED},
	{ID: "drive", Kind: cwbv1.NodeKind_NODE_KIND_UNSPECIFIED},
}

// Edge mirrors cwbv1.Edge for the static shape.
type Edge struct {
	From, To string
	Kind     cwbv1.EdgeKind
}

// Edges is the ARCHITECTURE.md connectivity.
var Edges = []Edge{
	{"you", "interchange", cwbv1.EdgeKind_EDGE_KIND_REQUEST},
	{"interchange", "herald", cwbv1.EdgeKind_EDGE_KIND_REQUEST},
	{"interchange", "almanac", cwbv1.EdgeKind_EDGE_KIND_REQUEST},
	{"interchange", "custodian", cwbv1.EdgeKind_EDGE_KIND_REQUEST},
	{"interchange", "cairn", cwbv1.EdgeKind_EDGE_KIND_REQUEST},
	{"interchange", "ledger", cwbv1.EdgeKind_EDGE_KIND_REQUEST},
	{"interchange", "commonplace", cwbv1.EdgeKind_EDGE_KIND_REQUEST},
	{"interchange", "mason", cwbv1.EdgeKind_EDGE_KIND_REQUEST},
	{"mason", "nexus-broker", cwbv1.EdgeKind_EDGE_KIND_RECONCILE},
	{"mason", "lynxai", cwbv1.EdgeKind_EDGE_KIND_RECONCILE},
	{"custodian", "porter-backup", cwbv1.EdgeKind_EDGE_KIND_REQUEST},
	{"porter-backup", "drive", cwbv1.EdgeKind_EDGE_KIND_BACKUP},
	{"nexus-broker", "keel", cwbv1.EdgeKind_EDGE_KIND_REQUEST},
	{"nexus-broker", "maren", cwbv1.EdgeKind_EDGE_KIND_REQUEST},
	{"nexus-broker", "anvil", cwbv1.EdgeKind_EDGE_KIND_REQUEST},
	{"nexus-broker", "harrow", cwbv1.EdgeKind_EDGE_KIND_REQUEST},
	{"keel", "gemma", cwbv1.EdgeKind_EDGE_KIND_REQUEST},
	{"croft", "interchange", cwbv1.EdgeKind_EDGE_KIND_REQUEST},
	{"atlas", "mason", cwbv1.EdgeKind_EDGE_KIND_REQUEST},
	{"atlas", "porter-backup", cwbv1.EdgeKind_EDGE_KIND_REQUEST},
}

// Kind returns a node's kind ("" id → UNSPECIFIED).
func Kind(id string) cwbv1.NodeKind {
	for _, n := range Nodes {
		if n.ID == id {
			return n.Kind
		}
	}
	return cwbv1.NodeKind_NODE_KIND_UNSPECIFIED
}
```

- [ ] **Step 4:** Run — PASS. **Step 5: Commit** `feat(topology): the static map shape (nodes + edges) as data`.

---

### Task B6: collect — k8s collector

**Files:**
- Create: `internal/collect/k8s.go`
- Test: `internal/collect/k8s_test.go`

- [ ] **Step 1: Failing test** (fake clientset; mason's fake pattern, simpler — typed clientset is enough)

```go
package collect

import (
	"context"
	"testing"
	"time"

	cwbv1 "github.com/CarriedWorldUniverse/cwb-proto/gen/go/cwb/v1"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/fake"
)

func deploy(ns, name, image string, ready, desired int32, created time.Time) *appsv1.Deployment {
	return &appsv1.Deployment{
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: ns, CreationTimestamp: metav1.Time{Time: created}},
		Spec: appsv1.DeploymentSpec{
			Replicas: &desired,
			Template: corev1.PodTemplateSpec{Spec: corev1.PodSpec{Containers: []corev1.Container{{Name: name, Image: image}}}},
		},
		Status: appsv1.DeploymentStatus{ReadyReplicas: ready},
	}
}

func TestK8sCollect(t *testing.T) {
	created := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	cs := fake.NewSimpleClientset(
		deploy("cwb", "herald", "ghcr.io/x/herald:sha-0c07777@sha256:3448e2", 1, 1, created),
		deploy("nexus", "anvil", "localhost/anvil:dev", 0, 0, created),
	)
	k := NewK8s(cs, []string{"cwb", "nexus", "croft"})
	facts, err := k.Collect(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	h, ok := facts["cwb/herald"]
	if !ok {
		t.Fatalf("missing cwb/herald in %v", facts)
	}
	if h.Version != "sha-0c07777" || h.Digest != "sha256:3448e2" || h.Ready != 1 || h.Desired != 1 || !h.Since.Equal(created) {
		t.Fatalf("herald facts: %+v", h)
	}
	if a := facts["nexus/anvil"]; a.Desired != 0 {
		t.Fatalf("anvil facts: %+v", a)
	}
	_ = cwbv1.NodeStatus_NODE_STATUS_UP // derive applies status later; collector stays factual
}
```

- [ ] **Step 2:** Run — FAIL. **Step 3: Implement**

```go
// Package collect gathers raw facts from the platform's sources (k8s, mason,
// porter) and folds them into one CloudState snapshot. Collectors return
// FACTS; meaning (status lamps) is derive's job.
package collect

import (
	"context"
	"fmt"
	"time"

	"github.com/CarriedWorldUniverse/atlas/internal/derive"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
)

// WorkloadFacts is what k8s knows about one deployment/statefulset.
type WorkloadFacts struct {
	Version string // image tag
	Digest  string // image digest ("" if unpinned)
	Ready   int32
	Desired int32
	Since   time.Time
}

// K8s lists deployments+statefulsets in the watched namespaces.
type K8s struct {
	cs         kubernetes.Interface
	namespaces []string
}

// NewK8s builds the collector. The namespace list is static config — atlas
// knows its cloud (cwb/nexus/croft); discovery is not its job.
func NewK8s(cs kubernetes.Interface, namespaces []string) *K8s {
	return &K8s{cs: cs, namespaces: namespaces}
}

// Collect returns facts keyed "namespace/name".
func (k *K8s) Collect(ctx context.Context) (map[string]WorkloadFacts, error) {
	out := map[string]WorkloadFacts{}
	for _, ns := range k.namespaces {
		deps, err := k.cs.AppsV1().Deployments(ns).List(ctx, metav1.ListOptions{})
		if err != nil {
			return nil, fmt.Errorf("list deployments %s: %w", ns, err)
		}
		for _, d := range deps.Items {
			var desired int32
			if d.Spec.Replicas != nil {
				desired = *d.Spec.Replicas
			}
			image := ""
			if c := d.Spec.Template.Spec.Containers; len(c) > 0 {
				image = c[0].Image
			}
			ver, digest := derive.SplitImage(image)
			out[ns+"/"+d.Name] = WorkloadFacts{
				Version: ver, Digest: digest,
				Ready: d.Status.ReadyReplicas, Desired: desired,
				Since: d.CreationTimestamp.Time,
			}
		}
		stss, err := k.cs.AppsV1().StatefulSets(ns).List(ctx, metav1.ListOptions{})
		if err != nil {
			return nil, fmt.Errorf("list statefulsets %s: %w", ns, err)
		}
		for _, s := range stss.Items {
			var desired int32
			if s.Spec.Replicas != nil {
				desired = *s.Spec.Replicas
			}
			image := ""
			if c := s.Spec.Template.Spec.Containers; len(c) > 0 {
				image = c[0].Image
			}
			ver, digest := derive.SplitImage(image)
			out[ns+"/"+s.Name] = WorkloadFacts{
				Version: ver, Digest: digest,
				Ready: s.Status.ReadyReplicas, Desired: desired,
				Since: s.CreationTimestamp.Time,
			}
		}
	}
	return out, nil
}
```

Multi-container note: first container is the workload by convention here (tailscale sidecars come AFTER the app container in this platform's manifests — keep that true in B13's atlas manifest, app container first).

- [ ] **Step 4:** Run — PASS. **Step 5: Commit** `feat(collect): k8s workload facts (deployments + statefulsets)`.

---

### Task B7: collect — mason + porter clients

**Files:**
- Create: `internal/collect/mason.go`, `internal/collect/porter.go`
- Test: `internal/collect/grpc_test.go`

- [ ] **Step 1: Failing test** (in-proc gRPC fakes over bufconn)

```go
package collect

import (
	"context"
	"net"
	"testing"

	cwbv1 "github.com/CarriedWorldUniverse/cwb-proto/gen/go/cwb/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/test/bufconn"
	"google.golang.org/protobuf/types/known/timestamppb"
)

type fakeMason struct {
	cwbv1.UnimplementedAppServiceServer
}

func (fakeMason) ListApps(context.Context, *cwbv1.ListAppsRequest) (*cwbv1.ListAppsResponse, error) {
	return &cwbv1.ListAppsResponse{Apps: []*cwbv1.App{
		{Name: "lynxai", Namespace: "nexus", Phase: cwbv1.AppPhase_APP_PHASE_SYNCED},
	}}, nil
}

type fakePorter struct {
	cwbv1.UnimplementedBackupStatusServiceServer
}

func (fakePorter) GetBackupStatus(context.Context, *cwbv1.GetBackupStatusRequest) (*cwbv1.GetBackupStatusResponse, error) {
	return &cwbv1.GetBackupStatusResponse{Status: &cwbv1.BackupStatus{
		LastSuccess: timestamppb.Now(),
		Sources:     []*cwbv1.BackupSource{{Name: "sqld", Size: 42}},
	}}, nil
}

func bufDial(t *testing.T, register func(*grpc.Server)) *grpc.ClientConn {
	t.Helper()
	lis := bufconn.Listen(1 << 20)
	srv := grpc.NewServer()
	register(srv)
	go func() { _ = srv.Serve(lis) }()
	t.Cleanup(srv.Stop)
	conn, err := grpc.NewClient("passthrough:///bufnet",
		grpc.WithContextDialer(func(ctx context.Context, _ string) (net.Conn, error) { return lis.DialContext(ctx) }),
		grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	return conn
}

func TestMasonCollect(t *testing.T) {
	conn := bufDial(t, func(s *grpc.Server) { cwbv1.RegisterAppServiceServer(s, fakeMason{}) })
	m := NewMason(cwbv1.NewAppServiceClient(conn), "cwb")
	phases, err := m.Collect(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if phases["nexus/lynxai"] != "Synced" {
		t.Fatalf("phases = %v", phases)
	}
}

func TestPorterCollect(t *testing.T) {
	conn := bufDial(t, func(s *grpc.Server) { cwbv1.RegisterBackupStatusServiceServer(s, fakePorter{}) })
	p := NewPorter(cwbv1.NewBackupStatusServiceClient(conn))
	st, err := p.Collect(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if st.GetSources()[0].GetName() != "sqld" {
		t.Fatalf("status = %v", st)
	}
}
```

NOTE: check the real `cwbv1.App` field names against `cwb-proto/gen/go/cwb/v1/mason.pb.go` (the mason exploration showed `Name/Namespace/Phase` with `AppPhase_APP_PHASE_SYNCED`); adjust the fake + assertions to the actual generated names. Same for the mason auth metadata: mason's handlers require `cwb-subject`/`cwb-org`/`cwb-scopes` metadata with scope `app:read` (see `/home/operator/src/mason/internal/source/almanac.go:29` for how mason itself attaches them as a client) — the Mason collector must attach the same three headers.

- [ ] **Step 2:** Run — FAIL. **Step 3: Implement**

```go
// internal/collect/mason.go
package collect

import (
	"context"
	"strings"

	cwbv1 "github.com/CarriedWorldUniverse/cwb-proto/gen/go/cwb/v1"
	"google.golang.org/grpc/metadata"
)

// Mason reads app sync phases from mason's AppService.
type Mason struct {
	client cwbv1.AppServiceClient
	org    string
}

// NewMason wires the collector; org goes into the cwb-org metadata header.
func NewMason(c cwbv1.AppServiceClient, org string) *Mason {
	return &Mason{client: c, org: org}
}

// Collect returns phase strings keyed "namespace/name" (e.g. "Synced").
func (m *Mason) Collect(ctx context.Context) (map[string]string, error) {
	ctx = metadata.AppendToOutgoingContext(ctx,
		"cwb-subject", "atlas", "cwb-org", m.org, "cwb-scopes", "app:read")
	resp, err := m.client.ListApps(ctx, &cwbv1.ListAppsRequest{})
	if err != nil {
		return nil, err
	}
	out := map[string]string{}
	for _, a := range resp.GetApps() {
		// "APP_PHASE_SYNCED" -> "Synced"
		phase := strings.TrimPrefix(a.GetPhase().String(), "APP_PHASE_")
		out[a.GetNamespace()+"/"+a.GetName()] = strings.Title(strings.ToLower(phase))
	}
	return out, nil
}
```

```go
// internal/collect/porter.go
package collect

import (
	"context"

	cwbv1 "github.com/CarriedWorldUniverse/cwb-proto/gen/go/cwb/v1"
)

// Porter reads the backup clock from porter's BackupStatusService.
type Porter struct {
	client cwbv1.BackupStatusServiceClient
}

// NewPorter wires the collector.
func NewPorter(c cwbv1.BackupStatusServiceClient) *Porter { return &Porter{client: c} }

// Collect returns the raw proto status (the API type IS the model here).
func (p *Porter) Collect(ctx context.Context) (*cwbv1.BackupStatus, error) {
	resp, err := p.client.GetBackupStatus(ctx, &cwbv1.GetBackupStatusRequest{})
	if err != nil {
		return nil, err
	}
	return resp.GetStatus(), nil
}
```

(`strings.Title` is deprecated; if `go vet` complains use a two-line manual capitalize — first rune upper, rest lower.)

- [ ] **Step 4:** Run — PASS. **Step 5: Commit** `feat(collect): mason phases + porter backup clock clients`.

---

### Task B8: collect — the loop + fold (CloudState cache)

**Files:**
- Create: `internal/collect/loop.go`
- Test: `internal/collect/loop_test.go`

- [ ] **Step 1: Failing test**

```go
package collect

import (
	"context"
	"errors"
	"testing"
	"time"

	cwbv1 "github.com/CarriedWorldUniverse/cwb-proto/gen/go/cwb/v1"
)

type stubSources struct {
	k8s      map[string]WorkloadFacts
	k8sErr   error
	phases   map[string]string
	masonErr error
	backup   *cwbv1.BackupStatus
	portErr  error
}

func (s stubSources) K8s(context.Context) (map[string]WorkloadFacts, error) { return s.k8s, s.k8sErr }
func (s stubSources) Mason(context.Context) (map[string]string, error)      { return s.phases, s.masonErr }
func (s stubSources) Porter(context.Context) (*cwbv1.BackupStatus, error)   { return s.backup, s.portErr }

func TestFoldHappyPath(t *testing.T) {
	now := time.Date(2026, 6, 12, 18, 0, 0, 0, time.UTC)
	l := NewLoop(stubSources{
		k8s: map[string]WorkloadFacts{
			"cwb/herald":   {Version: "sha-0c07777", Ready: 1, Desired: 1},
			"nexus/anvil":  {Ready: 0, Desired: 0},
			"nexus/lynxai": {Version: "sha-aaa", Ready: 1, Desired: 1},
		},
		phases: map[string]string{"nexus/lynxai": "Synced"},
		backup: &cwbv1.BackupStatus{LastError: ""},
	}, 0)
	l.collectOnce(context.Background(), now)
	st := l.State()
	if st.GetObservedAt().AsTime() != now {
		t.Fatalf("observed_at = %v", st.GetObservedAt().AsTime())
	}
	byID := map[string]*cwbv1.Node{}
	for _, n := range st.GetNodes() {
		byID[n.GetId()] = n
	}
	if byID["herald"].GetStatus() != cwbv1.NodeStatus_NODE_STATUS_UP || byID["herald"].GetVersion() != "sha-0c07777" {
		t.Fatalf("herald: %+v", byID["herald"])
	}
	if byID["anvil"].GetStatus() != cwbv1.NodeStatus_NODE_STATUS_DORMANT {
		t.Fatalf("anvil must be DORMANT: %+v", byID["anvil"])
	}
	if byID["lynxai"].GetDetail() != "Synced" {
		t.Fatalf("lynxai detail: %+v", byID["lynxai"])
	}
	if len(st.GetEdges()) == 0 || st.GetBackup() == nil {
		t.Fatal("edges/backup missing")
	}
	// a workload in topology but absent from k8s facts = DOWN, not missing
	if byID["sqld"].GetStatus() != cwbv1.NodeStatus_NODE_STATUS_DOWN {
		t.Fatalf("absent workload must read DOWN: %+v", byID["sqld"])
	}
}

func TestFoldPartialFailureKeepsServing(t *testing.T) {
	now := time.Now().UTC()
	l := NewLoop(stubSources{
		k8s:      map[string]WorkloadFacts{"cwb/herald": {Ready: 1, Desired: 1}},
		masonErr: errors.New("mason down"),
		portErr:  errors.New("porter down"),
	}, 0)
	l.collectOnce(context.Background(), now)
	st := l.State()
	var herald, lynxai *cwbv1.Node
	for _, n := range st.GetNodes() {
		if n.GetId() == "herald" {
			herald = n
		}
		if n.GetId() == "lynxai" {
			lynxai = n
		}
	}
	if herald.GetStatus() != cwbv1.NodeStatus_NODE_STATUS_UP {
		t.Fatal("k8s-derived lamps must survive mason/porter failure")
	}
	if !lynxai.GetStale() {
		t.Fatal("mason-managed node must be marked stale when mason is down")
	}
	if st.GetBackup() != nil {
		t.Fatal("backup must be nil when porter is down")
	}

	// total k8s failure: previous snapshot keeps serving
	prev := st.GetObservedAt().AsTime()
	l.sources = stubSources{k8sErr: errors.New("apiserver down")}
	l.collectOnce(context.Background(), now.Add(10*time.Second))
	if l.State().GetObservedAt().AsTime() != prev {
		t.Fatal("k8s failure must keep the previous snapshot (staleness visible via observed_at)")
	}
}
```

- [ ] **Step 2:** Run — FAIL. **Step 3: Implement**

```go
package collect

import (
	"context"
	"log/slog"
	"sync"
	"time"

	"github.com/CarriedWorldUniverse/atlas/internal/derive"
	"github.com/CarriedWorldUniverse/atlas/internal/topology"
	cwbv1 "github.com/CarriedWorldUniverse/cwb-proto/gen/go/cwb/v1"
	"google.golang.org/protobuf/types/known/timestamppb"
)

// Sources is the seam the loop collects through (stubbed in tests).
type Sources interface {
	K8s(ctx context.Context) (map[string]WorkloadFacts, error)
	Mason(ctx context.Context) (map[string]string, error)
	Porter(ctx context.Context) (*cwbv1.BackupStatus, error)
}

// Loop runs the collectors on a ticker and folds results into one
// mutex-guarded CloudState. Consumers (web + gRPC) read the same cache;
// requests never trigger collection.
type Loop struct {
	sources  Sources
	interval time.Duration

	mu    sync.RWMutex
	state *cwbv1.GetCloudStateResponse
}

// NewLoop builds the loop (interval 0 = caller drives collectOnce, tests).
func NewLoop(s Sources, interval time.Duration) *Loop {
	return &Loop{sources: s, interval: interval, state: &cwbv1.GetCloudStateResponse{}}
}

// Run ticks until ctx ends. First collection is immediate.
func (l *Loop) Run(ctx context.Context) {
	l.collectOnce(ctx, time.Now().UTC())
	t := time.NewTicker(l.interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			l.collectOnce(ctx, time.Now().UTC())
		}
	}
}

// State returns the current snapshot (shared pointer; treat as immutable).
func (l *Loop) State() *cwbv1.GetCloudStateResponse {
	l.mu.RLock()
	defer l.mu.RUnlock()
	return l.state
}

// collectOnce gathers all sources and folds. Partial failure is a DISPLAY
// state: mason/porter failures stale-mark their fields; a k8s failure keeps
// the whole previous snapshot (observed_at then shows the staleness).
func (l *Loop) collectOnce(ctx context.Context, now time.Time) {
	facts, err := l.sources.K8s(ctx)
	if err != nil {
		slog.Error("collect: k8s failed; keeping previous snapshot", "error", err)
		return
	}
	phases, masonErr := l.sources.Mason(ctx)
	if masonErr != nil {
		slog.Warn("collect: mason unavailable; managed apps marked stale", "error", masonErr)
	}
	backup, porterErr := l.sources.Porter(ctx)
	if porterErr != nil {
		slog.Warn("collect: porter unavailable; backup clock absent", "error", porterErr)
	}

	resp := &cwbv1.GetCloudStateResponse{ObservedAt: timestamppb.New(now), Backup: backup}
	for _, tn := range topology.Nodes {
		if tn.Workload == nil {
			continue // abstract nodes (you/drive) are edge anchors, not lamps
		}
		key := tn.Workload.Namespace + "/" + tn.Workload.Deployment
		f, found := facts[key]
		node := &cwbv1.Node{
			Id: tn.ID, Kind: tn.Kind, Namespace: tn.Workload.Namespace,
			Version: f.Version, ImageDigest: f.Digest,
			Ready: f.Ready, Desired: f.Desired,
		}
		if !found {
			// In topology but not in the cluster: that IS a down signal.
			node.Status = cwbv1.NodeStatus_NODE_STATUS_DOWN
		} else {
			node.Status = derive.Status(f.Ready, f.Desired)
			if !f.Since.IsZero() {
				node.Since = timestamppb.New(f.Since)
			}
		}
		if phase, ok := phases[key]; ok {
			node.Detail = phase
		} else if masonErr != nil {
			node.Stale = true // can't tell managed from unmanaged while mason is down
		}
		resp.Nodes = append(resp.Nodes, node)
	}
	for _, e := range topology.Edges {
		resp.Edges = append(resp.Edges, &cwbv1.Edge{From: e.From, To: e.To, Kind: e.Kind})
	}

	l.mu.Lock()
	l.state = resp
	l.mu.Unlock()
}
```

- [ ] **Step 4:** Run — PASS (note the test reaches `l.sources` — keep the field unexported, test is same-package). **Step 5: Commit** `feat(collect): collector loop + fold — partial failure is a display state`.

---

### Task B9: strataserver + main.go wiring

**Files:**
- Create: `internal/strataserver/server.go`
- Test: `internal/strataserver/server_test.go`
- Modify: `cmd/atlas/main.go` (full wiring)

- [ ] **Step 1: Failing test**

```go
package strataserver

import (
	"context"
	"testing"
	"time"

	"github.com/CarriedWorldUniverse/atlas/internal/collect"
	cwbv1 "github.com/CarriedWorldUniverse/cwb-proto/gen/go/cwb/v1"
)

type emptySources struct{}

func (emptySources) K8s(context.Context) (map[string]collect.WorkloadFacts, error) {
	return map[string]collect.WorkloadFacts{"cwb/herald": {Ready: 1, Desired: 1}}, nil
}
func (emptySources) Mason(context.Context) (map[string]string, error)    { return nil, nil }
func (emptySources) Porter(context.Context) (*cwbv1.BackupStatus, error) { return nil, nil }

func TestGetCloudStateServesTheCache(t *testing.T) {
	loop := collect.NewLoop(emptySources{}, 0)
	loop.CollectNow(context.Background(), time.Now().UTC())
	s := New(loop)
	resp, err := s.GetCloudState(context.Background(), &cwbv1.GetCloudStateRequest{})
	if err != nil {
		t.Fatal(err)
	}
	if len(resp.GetNodes()) == 0 {
		t.Fatal("empty nodes")
	}
}
```

`CollectNow` is `collectOnce` exported — add the one-line exported wrapper to loop.go (tests in other packages need it; the web layer's tests will too):

```go
// CollectNow runs one collection synchronously (startup + tests).
func (l *Loop) CollectNow(ctx context.Context, now time.Time) { l.collectOnce(ctx, now) }
```

- [ ] **Step 2:** Run — FAIL. **Step 3: Implement**

```go
// Package strataserver serves cwb.v1.StrataService from the collector cache.
// Read-only by design, permanently: write RPCs belong to mason/almanac.
package strataserver

import (
	"context"

	"github.com/CarriedWorldUniverse/atlas/internal/collect"
	cwbv1 "github.com/CarriedWorldUniverse/cwb-proto/gen/go/cwb/v1"
)

// Server implements StrataService over the loop's cache.
type Server struct {
	cwbv1.UnimplementedStrataServiceServer
	loop *collect.Loop
}

// New wires the server.
func New(loop *collect.Loop) *Server { return &Server{loop: loop} }

// GetCloudState returns the current snapshot. Always succeeds once the first
// collection has run; staleness rides observed_at, not errors.
func (s *Server) GetCloudState(context.Context, *cwbv1.GetCloudStateRequest) (*cwbv1.GetCloudStateResponse, error) {
	return s.loop.State(), nil
}
```

- [ ] **Step 4: Wire `cmd/atlas/main.go`** — mason's main.go is the template (`/home/operator/src/mason/cmd/mason/main.go`): copy `serverOptions()` and `clientCredentials()` renaming `MASON_`→`ATLAS_` (client credentials get TWO server names — mason and porter — so make `clientCredentials(serverName string)` take it as a parameter). Then:

```go
func run() error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	// k8s: in-cluster SA (read-only RBAC; the manifest is the enforcement)
	kcfg, err := rest.InClusterConfig()
	if err != nil {
		return fmt.Errorf("in-cluster config: %w", err)
	}
	cs, err := kubernetes.NewForConfig(kcfg)
	if err != nil {
		return err
	}

	masonConn, err := grpc.NewClient(env("ATLAS_MASON_ADDR", "mason.cwb.svc.cluster.local:8086"),
		grpc.WithTransportCredentials(clientCredentials(env("ATLAS_MASON_TLS_SERVER_NAME", "mason.cwb.svc.cluster.local"))))
	if err != nil {
		return err
	}
	porterConn, err := grpc.NewClient(env("ATLAS_PORTER_ADDR", "porter-backup.cwb.svc.cluster.local:8087"),
		grpc.WithTransportCredentials(clientCredentials(env("ATLAS_PORTER_TLS_SERVER_NAME", "porter-backup.cwb.svc.cluster.local"))))
	if err != nil {
		return err
	}

	loop := collect.NewLoop(prodSources{
		k8s:    collect.NewK8s(cs, []string{"cwb", "nexus", "croft"}),
		mason:  collect.NewMason(cwbv1.NewAppServiceClient(masonConn), env("ATLAS_ORG", "cwb")),
		porter: collect.NewPorter(cwbv1.NewBackupStatusServiceClient(porterConn)),
	}, envDuration("ATLAS_POLL_INTERVAL", 10*time.Second))
	go loop.Run(ctx)

	// gRPC StrataService (mesh + interchange)
	grpcSrv := grpc.NewServer(serverOptions()...)
	cwbv1.RegisterStrataServiceServer(grpcSrv, strataserver.New(loop))
	healthSrv := health.NewServer()
	grpc_health_v1.RegisterHealthServer(grpcSrv, healthSrv)
	healthSrv.SetServingStatus("cwb.v1.StrataService", grpc_health_v1.HealthCheckResponse_SERVING)
	lis, err := net.Listen("tcp", env("ATLAS_GRPC_ADDR", ":8089"))
	if err != nil {
		return err
	}
	go func() { <-ctx.Done(); grpcSrv.GracefulStop() }()
	go func() {
		if err := grpcSrv.Serve(lis); err != nil {
			slog.Error("grpc serve", "error", err)
		}
	}()

	// web layer (Task B10/B11 fills internal/web)
	return web.Serve(ctx, loop)
}

// prodSources adapts the three collectors to collect.Sources.
type prodSources struct {
	k8s    *collect.K8s
	mason  *collect.Mason
	porter *collect.Porter
}

func (p prodSources) K8s(ctx context.Context) (map[string]collect.WorkloadFacts, error) {
	return p.k8s.Collect(ctx)
}
func (p prodSources) Mason(ctx context.Context) (map[string]string, error) { return p.mason.Collect(ctx) }
func (p prodSources) Porter(ctx context.Context) (*cwbv1.BackupStatus, error) {
	return p.porter.Collect(ctx)
}
```

(`web.Serve` won't exist until B10 — stub it as `func Serve(context.Context, *collect.Loop) error { select{} }` in `internal/web/web.go` so this compiles, then B10 replaces it. `env`/`envDuration` helpers: copy mason's.)

- [ ] **Step 5:** `go build ./... && go test ./...` — PASS. **Step 6: Commit** `feat: StrataService server + full collector wiring`.

---

### Task B10: web — session + OIDC RP

**Files:**
- Create: `internal/web/session.go`, `internal/web/oidc.go`
- Test: `internal/web/oidc_test.go`

- [ ] **Step 1: Failing test** (stub herald = httptest server implementing /authorize + /token the way Plan A builds them)

```go
package web

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

// stubHerald speaks just enough of Plan A's protocol: /authorize immediately
// 302s back with a fixed code (skipping the login form), /token validates the
// code + verifier shape and returns a token.
func stubHerald(t *testing.T) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("GET /authorize", func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		if q.Get("client_id") != "atlas" || q.Get("code_challenge") == "" || q.Get("code_challenge_method") != "S256" {
			http.Error(w, "bad authorize", 400)
			return
		}
		u, _ := url.Parse(q.Get("redirect_uri"))
		uq := u.Query()
		uq.Set("code", "test-code")
		uq.Set("state", q.Get("state"))
		u.RawQuery = uq.Encode()
		http.Redirect(w, r, u.String(), http.StatusFound)
	})
	mux.HandleFunc("POST /token", func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		if r.Form.Get("grant_type") != "authorization_code" || r.Form.Get("code") != "test-code" || r.Form.Get("code_verifier") == "" {
			http.Error(w, "bad exchange", 401)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"access_token": "tok-abc", "token_type": "Bearer", "expires_in": 600, "refresh_token": "ref-abc",
		})
	})
	return httptest.NewServer(mux)
}

func TestLoginCallbackRoundTrip(t *testing.T) {
	herald := stubHerald(t)
	defer herald.Close()

	h := NewAuth(AuthConfig{
		Issuer: herald.URL, ClientID: "atlas",
		RedirectURL: "https://atlas.example/oauth/callback",
	})
	mux := http.NewServeMux()
	h.Mount(mux)
	srv := httptest.NewServer(mux)
	defer srv.Close()

	jar := newTestJar(t) // http.CookieJar via net/http/cookiejar
	client := &http.Client{Jar: jar, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}

	// 1. /login redirects to herald with PKCE + state, and sets the flow cookie
	resp, err := client.Get(srv.URL + "/login")
	if err != nil || resp.StatusCode != http.StatusFound {
		t.Fatalf("login: %v %d", err, resp.StatusCode)
	}
	authzURL, _ := url.Parse(resp.Header.Get("Location"))
	if authzURL.Query().Get("code_challenge") == "" {
		t.Fatal("no PKCE challenge in authorize redirect")
	}

	// 2. follow to stub herald, which bounces straight back with a code
	resp, err = client.Get(authzURL.String())
	if err != nil || resp.StatusCode != http.StatusFound {
		t.Fatalf("authorize: %v %d", err, resp.StatusCode)
	}
	cb, _ := url.Parse(resp.Header.Get("Location"))

	// 3. hit OUR callback path with herald's code+state (rewrite host to test server)
	resp, err = client.Get(srv.URL + cb.RequestURI())
	if err != nil || resp.StatusCode != http.StatusFound || resp.Header.Get("Location") != "/" {
		t.Fatalf("callback: %v %d -> %s", err, resp.StatusCode, resp.Header.Get("Location"))
	}

	// 4. session cookie now grants /api probe
	req, _ := http.NewRequest("GET", srv.URL+"/session-check", nil)
	resp, err = client.Do(req)
	if err != nil || resp.StatusCode != http.StatusOK {
		t.Fatalf("session check: %v %d", err, resp.StatusCode)
	}
}

func TestCallbackRejectsBadState(t *testing.T) {
	herald := stubHerald(t)
	defer herald.Close()
	h := NewAuth(AuthConfig{Issuer: herald.URL, ClientID: "atlas", RedirectURL: "https://atlas.example/oauth/callback"})
	mux := http.NewServeMux()
	h.Mount(mux)
	srv := httptest.NewServer(mux)
	defer srv.Close()
	resp, err := http.Get(srv.URL + "/oauth/callback?code=x&state=forged")
	if err != nil || resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("forged state must 400: %v %d", err, resp.StatusCode)
	}
}
```

(`newTestJar`: 3 lines over `cookiejar.New(nil)`.)

- [ ] **Step 2:** Run — FAIL. **Step 3: Implement session.go**

```go
// Package web is atlas's human face: the OIDC relying-party flow against
// herald, an in-memory session store, and the map page + its /api/state
// poll endpoint. The session retains the herald tokens server-side — that
// is the identity seam v2 write verbs ride on (design doc, "Ops seams").
package web

import (
	"crypto/rand"
	"encoding/base64"
	"net/http"
	"sync"
	"time"
)

const sessionCookie = "atlas_session"

// Session is one logged-in browser. AccessToken/RefreshToken are herald's;
// they never reach the page.
type Session struct {
	AccessToken  string
	RefreshToken string
	Expires      time.Time // access-token expiry
}

// sessions is an in-memory store: atlas is single-replica and read-only; a
// restart logging everyone out is acceptable (login is one redirect).
type sessions struct {
	mu sync.Mutex
	m  map[string]*Session
}

func newSessions() *sessions { return &sessions{m: map[string]*Session{}} }

func randToken() string {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		panic("web: crypto/rand failed: " + err.Error())
	}
	return base64.RawURLEncoding.EncodeToString(b)
}

func (s *sessions) create(w http.ResponseWriter, sess *Session) {
	id := randToken()
	s.mu.Lock()
	s.m[id] = sess
	s.mu.Unlock()
	http.SetCookie(w, &http.Cookie{
		Name: sessionCookie, Value: id, Path: "/",
		HttpOnly: true, Secure: true, SameSite: http.SameSiteLaxMode,
		MaxAge: int((30 * 24 * time.Hour).Seconds()), // refresh-token lifetime
	})
}

// get returns the session for the request, or nil.
func (s *sessions) get(r *http.Request) *Session {
	c, err := r.Cookie(sessionCookie)
	if err != nil {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.m[c.Value]
}

func (s *sessions) drop(w http.ResponseWriter, r *http.Request) {
	if c, err := r.Cookie(sessionCookie); err == nil {
		s.mu.Lock()
		delete(s.m, c.Value)
		s.mu.Unlock()
	}
	http.SetCookie(w, &http.Cookie{Name: sessionCookie, Value: "", Path: "/", MaxAge: -1})
}
```

- [ ] **Step 4: Implement oidc.go**

```go
package web

import (
	"context"
	"net/http"
	"strings"
	"sync"
	"time"

	"golang.org/x/oauth2"
)

// AuthConfig configures the relying-party flow.
type AuthConfig struct {
	Issuer      string // herald base URL (no trailing slash needed)
	ClientID    string // "atlas"
	RedirectURL string // https://atlas.tail41686e.ts.net/oauth/callback
}

// Auth is the OIDC relying party: /login, /oauth/callback, /logout, and the
// session gate other handlers call. PKCE always; state is a short-lived
// cookie-bound nonce.
type Auth struct {
	cfg      oauth2.Config
	sessions *sessions

	mu      sync.Mutex
	pending map[string]string // state -> PKCE verifier (one redirect hop, in-memory)
}

// NewAuth builds the RP from herald's well-known endpoint shapes (Plan A:
// issuer + /authorize, /token).
func NewAuth(c AuthConfig) *Auth {
	base := strings.TrimRight(c.Issuer, "/")
	return &Auth{
		cfg: oauth2.Config{
			ClientID:    c.ClientID,
			RedirectURL: c.RedirectURL,
			Endpoint:    oauth2.Endpoint{AuthURL: base + "/authorize", TokenURL: base + "/token"},
		},
		sessions: newSessions(),
		pending:  map[string]string{},
	}
}

// Mount registers the auth routes plus a session probe for tests.
func (a *Auth) Mount(mux *http.ServeMux) {
	mux.HandleFunc("GET /login", a.handleLogin)
	mux.HandleFunc("GET /oauth/callback", a.handleCallback)
	mux.HandleFunc("POST /logout", a.handleLogout)
	mux.HandleFunc("GET /session-check", func(w http.ResponseWriter, r *http.Request) {
		if a.sessions.get(r) == nil {
			http.Error(w, "no session", http.StatusUnauthorized)
			return
		}
		w.WriteHeader(http.StatusOK)
	})
}

func (a *Auth) handleLogin(w http.ResponseWriter, r *http.Request) {
	state := randToken()
	verifier := oauth2.GenerateVerifier()
	a.mu.Lock()
	a.pending[state] = verifier
	a.mu.Unlock()
	http.Redirect(w, r, a.cfg.AuthCodeURL(state, oauth2.S256ChallengeOption(verifier)), http.StatusFound)
}

func (a *Auth) handleCallback(w http.ResponseWriter, r *http.Request) {
	state := r.URL.Query().Get("state")
	a.mu.Lock()
	verifier, ok := a.pending[state]
	delete(a.pending, state)
	a.mu.Unlock()
	if !ok {
		http.Error(w, "unknown or replayed state", http.StatusBadRequest)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	tok, err := a.cfg.Exchange(ctx, r.URL.Query().Get("code"), oauth2.VerifierOption(verifier))
	if err != nil {
		// fail closed, loudly: herald down or code rejected = no session
		http.Error(w, "login failed: "+err.Error(), http.StatusBadGateway)
		return
	}
	a.sessions.create(w, &Session{
		AccessToken:  tok.AccessToken,
		RefreshToken: tok.RefreshToken,
		Expires:      tok.Expiry,
	})
	http.Redirect(w, r, "/", http.StatusFound)
}

func (a *Auth) handleLogout(w http.ResponseWriter, r *http.Request) {
	a.sessions.drop(w, r)
	http.Redirect(w, r, "/login", http.StatusFound)
}

// Require gates a handler on a live session (redirects browsers to /login).
func (a *Auth) Require(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if a.sessions.get(r) == nil {
			if strings.HasPrefix(r.URL.Path, "/api/") {
				http.Error(w, "unauthenticated", http.StatusUnauthorized)
				return
			}
			http.Redirect(w, r, "/login", http.StatusFound)
			return
		}
		next(w, r)
	}
}
```

Token refresh on expiry: YAGNI'd for v1 deliberately — when the access token lapses the session still exists and v1 makes no outbound calls with it; refresh mechanics land with v2 writes (the seam is the stored RefreshToken). Note this in a code comment.

- [ ] **Step 5:** Run — PASS. **Step 6: Commit** `feat(web): herald OIDC relying party + in-memory sessions (PKCE, fail-closed)`.

---

### Task B11: web — /api/state + the map page

**Files:**
- Create: `internal/web/web.go` (replace B9's stub), `internal/web/static/index.html`, `internal/web/static/map.css`, `internal/web/static/map.js`
- Test: `internal/web/web_test.go`

- [ ] **Step 1: Failing test**

```go
package web

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/CarriedWorldUniverse/atlas/internal/collect"
	"github.com/CarriedWorldUniverse/atlas/internal/topology"
	cwbv1 "github.com/CarriedWorldUniverse/cwb-proto/gen/go/cwb/v1"
)

type oneNodeSources struct{}

func (oneNodeSources) K8s(context.Context) (map[string]collect.WorkloadFacts, error) {
	return map[string]collect.WorkloadFacts{"cwb/herald": {Version: "sha-1", Ready: 1, Desired: 1}}, nil
}
func (oneNodeSources) Mason(context.Context) (map[string]string, error)    { return nil, nil }
func (oneNodeSources) Porter(context.Context) (*cwbv1.BackupStatus, error) { return nil, nil }

func testHandler(t *testing.T) http.Handler {
	t.Helper()
	loop := collect.NewLoop(oneNodeSources{}, 0)
	loop.CollectNow(context.Background(), time.Now().UTC())
	auth := NewAuth(AuthConfig{Issuer: "http://herald.invalid", ClientID: "atlas", RedirectURL: "http://atlas.invalid/oauth/callback"})
	return Handler(auth, loop)
}

func TestStateRequiresSession(t *testing.T) {
	srv := httptest.NewServer(testHandler(t))
	defer srv.Close()
	resp, _ := http.Get(srv.URL + "/api/state")
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("want 401, got %d", resp.StatusCode)
	}
	resp, _ = http.Get(srv.URL + "/") // browser path redirects to login
	if resp.Request.URL.Path != "/login" && resp.StatusCode != http.StatusFound {
		t.Fatalf("unauthenticated / should land on login, got %d %s", resp.StatusCode, resp.Request.URL.Path)
	}
}

func TestStateJSONShape(t *testing.T) {
	loop := collect.NewLoop(oneNodeSources{}, 0)
	loop.CollectNow(context.Background(), time.Now().UTC())
	rec := httptest.NewRecorder()
	serveState(loop)(rec, httptest.NewRequest("GET", "/api/state", nil))
	if rec.Code != 200 {
		t.Fatalf("status %d", rec.Code)
	}
	var body struct {
		Nodes []struct {
			Id, Status, Version string
		} `json:"nodes"`
		ObservedAt string `json:"observedAt"`
	}
	if err := json.NewDecoder(rec.Body).Decode(&body); err != nil {
		t.Fatal(err)
	}
	if len(body.Nodes) == 0 || body.ObservedAt == "" {
		t.Fatalf("body: %+v", body)
	}
	found := false
	for _, n := range body.Nodes {
		if n.Id == "herald" && n.Status == "NODE_STATUS_UP" && n.Version == "sha-1" {
			found = true
		}
	}
	if !found {
		t.Fatalf("herald missing/wrong in %+v", body.Nodes)
	}
}

// Every workload node in topology must exist in the SVG skeleton, and vice
// versa — the layout can't silently drift from the data.
func TestSVGCoversTopology(t *testing.T) {
	html := string(staticFS_MustRead(t, "static/index.html"))
	for _, n := range topology.Nodes {
		if n.Workload == nil {
			continue
		}
		if !strings.Contains(html, `id="node-`+n.ID+`"`) {
			t.Errorf("index.html missing SVG element for node %s", n.ID)
		}
	}
}
```

(`staticFS_MustRead`: tiny helper reading from the `//go:embed static` FS.)

- [ ] **Step 2:** Run — FAIL. **Step 3: Implement web.go**

```go
package web

import (
	"context"
	"crypto/tls"
	"embed"
	"net/http"
	"os"
	"time"

	"github.com/CarriedWorldUniverse/atlas/internal/collect"
	"google.golang.org/protobuf/encoding/protojson"
)

//go:embed static
var staticFS embed.FS

// Handler assembles the web mux: auth routes open, everything else gated.
func Handler(auth *Auth, loop *collect.Loop) http.Handler {
	mux := http.NewServeMux()
	auth.Mount(mux)
	mux.HandleFunc("GET /api/state", auth.Require(serveState(loop)))
	mux.HandleFunc("GET /", auth.Require(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		http.ServeFileFS(w, r, staticFS, "static/index.html")
	}))
	mux.Handle("GET /static/", auth.Require(func(w http.ResponseWriter, r *http.Request) {
		http.FileServerFS(staticFS).ServeHTTP(w, r)
	}))
	return mux
}

// serveState renders the cache as protojson (camelCase keys, enum names —
// the page reads the same shapes cw/MCP will get via the edge).
func serveState(loop *collect.Loop) http.HandlerFunc {
	marshal := protojson.MarshalOptions{}
	return func(w http.ResponseWriter, r *http.Request) {
		b, err := marshal.Marshal(loop.State())
		if err != nil {
			http.Error(w, "marshal failed", http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		_, _ = w.Write(b)
	}
}

// Serve runs the HTTPS server (tailscale-cert files) until ctx ends.
func Serve(ctx context.Context, loop *collect.Loop) error {
	auth := NewAuth(AuthConfig{
		Issuer:      os.Getenv("ATLAS_OIDC_ISSUER"), // e.g. http://dmonextreme.tail41686e.ts.net:8080/herald
		ClientID:    envOr("ATLAS_OIDC_CLIENT_ID", "atlas"),
		RedirectURL: os.Getenv("ATLAS_OIDC_REDIRECT_URL"),
	})
	srv := &http.Server{
		Addr:              envOr("ATLAS_HTTP_ADDR", ":8443"),
		Handler:           Handler(auth, loop),
		ReadHeaderTimeout: 10 * time.Second,
		TLSConfig:         &tls.Config{MinVersion: tls.VersionTLS12},
	}
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdownCtx)
	}()
	cert, key := os.Getenv("ATLAS_HTTPS_CERT"), os.Getenv("ATLAS_HTTPS_KEY")
	if cert == "" || os.Getenv("ATLAS_DEV_INSECURE") == "1" {
		return srv.ListenAndServe() // dev only
	}
	return srv.ListenAndServeTLS(cert, key)
}

func envOr(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}
```

- [ ] **Step 4: The page.** `static/index.html`: the ARCHITECTURE.md layout as a fixed SVG — a `<svg viewBox="0 0 1200 800">` with one `<g id="node-<id>" class="node">` per workload node (rect + name + lamp circle + version text + ready text), grouped in labeled bands top-to-bottom: interchange (the door), pillars row (herald almanac custodian cairn ledger commonplace), cross-cutting column (mason, porter-backup + backup-clock text block), apps row (nexus-broker keel maren anvil harrow gemma lynxai croft), infra (sqld, atlas), drive offsite. Static `<line>` elements for each topology edge (`id="edge-<from>-<to>"`). A header bar: "Strata — live map", observed-at staleness text (`id="observed"`), logout button. A `<aside id="panel">` detail panel (hidden by default) with title, dl fields (status/version/digest/ready/age/namespace/detail), and an EMPTY `<div id="panel-actions">` — the reserved v2 ops region (design doc, "Ops seams").

`static/map.css`: dark theme matching the herald login (bg `#14161a`, panel `#1c1f26`, line `#2a2e37`); `.lamp-up{fill:#3fb950}` `.lamp-degraded{fill:#d29922}` `.lamp-down{fill:#f85149}` `.lamp-dormant{fill:#6e7681}` `.lamp-unknown{fill:#30363d}`; `.node{cursor:pointer}`; `.stale{opacity:.55}`; lamp transitions `transition: fill .6s ease`; `#observed.stale-warn{color:#d29922}`.

`static/map.js` (complete file):

```js
// atlas map: poll /api/state, flip lamps/text on the fixed SVG. The layout
// never moves — only the lights change.
const POLL_MS = 10000;
const lampClass = {
  NODE_STATUS_UP: "lamp-up", NODE_STATUS_DEGRADED: "lamp-degraded",
  NODE_STATUS_DOWN: "lamp-down", NODE_STATUS_DORMANT: "lamp-dormant",
};
let lastState = null, lastFetchOk = Date.now();

async function poll() {
  try {
    const r = await fetch("/api/state", { cache: "no-store" });
    if (r.status === 401) { location.href = "/login"; return; }
    if (!r.ok) throw new Error("state " + r.status);
    lastState = await r.json();
    lastFetchOk = Date.now();
    render(lastState);
  } catch (e) {
    // degrade loudly: keep last render, show the gap
    console.warn("poll failed", e);
  }
  banner();
}

function render(st) {
  for (const n of st.nodes || []) {
    const g = document.getElementById("node-" + n.id);
    if (!g) continue;
    const lamp = g.querySelector(".lamp");
    lamp.setAttribute("class", "lamp " + (lampClass[n.status] || "lamp-unknown"));
    g.querySelector(".version").textContent = n.version || "";
    g.querySelector(".ready").textContent =
      n.status === "NODE_STATUS_DORMANT" ? "benched" : `${n.ready ?? 0}/${n.desired ?? 0}`;
    g.classList.toggle("stale", !!n.stale);
    g.dataset.node = JSON.stringify(n);
  }
  const clock = document.getElementById("backup-clock");
  if (clock) {
    if (st.backup && st.backup.lastSuccess) {
      const last = new Date(st.backup.lastSuccess);
      const due = st.backup.nextDue ? new Date(st.backup.nextDue) : null;
      clock.textContent = `last sync ${last.toLocaleTimeString()} · ${(st.backup.sources || []).length} sources` +
        (st.backup.lastError ? " · ⚠ " + st.backup.lastError : " ✓") +
        (due ? ` · next ~${due.toLocaleTimeString()}` : "");
    } else {
      clock.textContent = "backup status unavailable";
    }
  }
}

function banner() {
  const el = document.getElementById("observed");
  if (!el) return;
  const obs = lastState && lastState.observedAt ? new Date(lastState.observedAt) : null;
  const fetchGap = (Date.now() - lastFetchOk) / 1000;
  if (fetchGap > 25) {
    el.textContent = `lost contact with atlas ${Math.round(fetchGap)}s ago`;
    el.className = "stale-warn";
  } else if (obs) {
    const age = (Date.now() - obs.getTime()) / 1000;
    el.textContent = `as of ${Math.round(age)}s ago`;
    el.className = age > 30 ? "stale-warn" : "";
  }
}

document.addEventListener("click", (ev) => {
  const g = ev.target.closest(".node");
  const panel = document.getElementById("panel");
  if (!g || !g.dataset.node) { panel.hidden = true; return; }
  const n = JSON.parse(g.dataset.node);
  document.getElementById("panel-title").textContent = n.id;
  const set = (k, v) => (document.getElementById("panel-" + k).textContent = v || "—");
  set("status", (n.status || "").replace("NODE_STATUS_", ""));
  set("version", n.version);
  set("digest", n.imageDigest);
  set("ready", `${n.ready ?? 0}/${n.desired ?? 0}`);
  set("namespace", n.namespace);
  set("detail", n.detail);
  set("since", n.since ? new Date(n.since).toLocaleString() : "");
  panel.hidden = false;
});

// visibility API: don't poll a hidden tab (lazy-connection, browser edition)
let timer = setInterval(poll, POLL_MS);
document.addEventListener("visibilitychange", () => {
  clearInterval(timer);
  if (!document.hidden) { poll(); timer = setInterval(poll, POLL_MS); }
});
poll();
```

Writing the full index.html SVG by hand: ~15 node groups × 5 elements. Keep every node group structurally identical:

```html
<g id="node-herald" class="node" transform="translate(140,260)">
  <rect width="150" height="64" rx="8"/>
  <circle class="lamp lamp-unknown" cx="18" cy="20" r="7"/>
  <text class="name" x="34" y="25">herald</text>
  <text class="version" x="18" y="48"></text>
  <text class="ready" x="120" y="25"></text>
</g>
```

Lay the bands out on a 1200×800 grid: interchange y=140 centered; pillars y=260, x = 140 + 170·i; mason/porter right column x=1010, y=260/360; apps y=480, x = 60 + 140·i; infra y=620; drive x=1010 y=620. Edges as `<line>` between band anchors — straight lines, `stroke:#2a2e37`, no routing cleverness in v1.

- [ ] **Step 5:** Run all web tests — PASS (the SVG-coverage test enforces the node groups exist). Replace B9's `web.Serve` stub with the real one; `go build ./...` — PASS.

- [ ] **Step 6: Commit** `feat(web): the map — fixed SVG, 10s poll, detail panel with reserved ops region`.

---

### Task B12: interchange — register StrataService at the edge

**Files (in `/home/operator/src/interchange`, branch `feat/strata-route`):**
- Modify: `cmd/interchange-gateway/main.go` (follow the exact mason-registration pattern already there)
- Modify: `deploy/k3s/20-deployment.yaml` (env `INTERCHANGE_ATLAS_GRPC: "atlas.cwb.svc.cluster.local:8089"`)

- [ ] **Step 1:** `go get github.com/CarriedWorldUniverse/cwb-proto@main && go mod tidy`, then add next to the mason block in main.go:

```go
	// /api/strata → atlas (read-only cloud state for cw/MCP/web)
	atlasAddr := env("INTERCHANGE_ATLAS_GRPC", "atlas.cwb.svc.cluster.local:8089")
	atlasConn, err := edge.DialPillar(atlasAddr, tlsCert, tlsKey, tlsCA)
	if err != nil {
		log.Fatalf("interchange-gateway: dial atlas (%s): %v", atlasAddr, err)
	}
	if err := cwbv1.RegisterStrataServiceHandler(context.Background(), strataMux, atlasConn); err != nil {
		log.Fatalf("interchange-gateway: register strata handler: %v", err)
	}
```

Mirror EXACTLY how the mason route builds its mux + `authInject(...)` wrapper and mounts the path prefix — read the surrounding code, match it (including which herald scopes gate it; reads should require a valid herald identity, same as mason's read path).

- [ ] **Step 2:** `go build ./... && go test ./...` — PASS. Commit, push, PR (`interchange: route /api/strata to atlas`), merge on green, bump the interchange image pin in its manifest after release (commit before apply).

---

### Task B13: manifests — atlas.yaml + herald client + GitOps deploy

**Files (in `/home/operator/src/carriedworld-cloud`, branch `feat/atlas-deploy`):**
- Create: `hosting/services/atlas.yaml`
- Modify: herald deployment manifest (HERALD_OIDC_CLIENTS — Plan A Task A7 may have done this; verify)

- [ ] **Step 1: Write atlas.yaml** — assemble from the established patterns (copy, then adapt):
1. **ServiceAccount** `atlas` (ns cwb).
2. **RBAC**: one ClusterRole `atlas-read` (`apiGroups: ["apps"], resources: ["deployments","statefulsets"], verbs: ["get","list"]`) + three RoleBindings (cwb, nexus, croft) binding it to the SA. No pods, no secrets, no write verbs — atlas physically cannot mutate (design doc, "Collectors").
3. **Certificates** (issuer `cwb-ca`, copy commonplace's shape): `atlas-tls` (server auth; dnsNames `atlas.cwb.svc`, `atlas.cwb.svc.cluster.local`) and `atlas-client-tls` (client auth — copy how `porter-backup-client-tls` declares usages).
4. **Deployment** `atlas` (ns cwb, Recreate, SA atlas): app container FIRST (B6's first-container convention), image `ghcr.io/carriedworlduniverse/atlas:sha-<short>@sha256:<digest>` (pin after first release), ports 8089 (grpc) + 8443 (https). Env: `ATLAS_GRPC_ADDR=:8089`, `ATLAS_HTTP_ADDR=:8443`, `ATLAS_TLS_CERT/_KEY/_CA=/etc/cwb/tls/...`, `ATLAS_CLIENT_TLS_CERT/_KEY/_CA=/etc/cwb/client-tls/...`, `ATLAS_MASON_ADDR`, `ATLAS_PORTER_ADDR`, `ATLAS_OIDC_ISSUER=http://dmonextreme.tail41686e.ts.net:8080/herald`, `ATLAS_OIDC_REDIRECT_URL=https://atlas.tail41686e.ts.net/oauth/callback`, `ATLAS_HTTPS_CERT/_KEY=/certs/tls.crt|key`. Mounts: the two cert secrets + the shared `/certs` emptyDir.
5. **Tailscale sidecars**: copy the two containers from `hosting/services/nexus-broker.yaml` verbatim with `TS_HOSTNAME: "atlas"` and the cert loop issuing `atlas.tail41686e.ts.net` into the shared `/certs` emptyDir. Reuses the existing `tailscale-auth` secret pattern (check which namespace it lives in; mirror how nexus-broker references it — if it's namespace-local, add a copy in cwb).
6. **Service** `atlas` (ClusterIP, port 8089) — for interchange.

- [ ] **Step 2:** First image: merge atlas repo main → release workflow pushes to GHCR → resolve tag+digest → pin in atlas.yaml.
- [ ] **Step 3:** Commit + push the manifest BEFORE applying (15-min reconciler!), then apply and watch:

```bash
ssh jacinta@100.91.185.71 'sudo kubectl apply -f -' < hosting/services/atlas.yaml
ssh jacinta@100.91.185.71 'sudo kubectl -n cwb rollout status deploy/atlas && sudo kubectl -n cwb logs deploy/atlas --tail=20'
```

Expected: collector loop logging, gRPC listening, https listening, tailscale up.

- [ ] **Step 4: Live verification (the whole point):**

```bash
# 1. from croft: edge REST returns state
cw whoami  # confirm herald identity works
curl -s -H "Authorization: Bearer $(cw token)" http://dmonextreme.tail41686e.ts.net:8080/api/strata/state | jq '.nodes[] | select(.id=="herald")'
# Expected: herald node, status NODE_STATUS_UP, version sha-...
# (adapt the token acquisition to how cw actually exposes it; if there's no
# `cw token`, test via grpcurl against atlas.cwb.svc from inside the mesh instead)

# 2. from the operator's browser (Mac, tailnet):
#    https://atlas.tail41686e.ts.net  → herald login form → sign in → THE MAP
#    - all pillars green; anvil/harrow grey "benched"; backup clock populated
#    - kill something: sudo kubectl -n nexus scale deploy/lynxai --replicas=0
#      → within ~20s lynxai lamp goes grey (DORMANT); scale back to 1 → green
```

- [ ] **Step 5:** Update `clusters/dmon`/`RECOVERY.md`/`ARCHITECTURE.md` (add atlas to the Mermaid diagram + pillar list; ARCHITECTURE.md's "Where this is going" section now describes a thing that exists — rewrite it forward-state as "The live version is atlas: …"). Commit.

---

### Task B14: conformance layer

**Files:** in `/home/operator/src/cwb-conformance` — find the newest pillar's layer (mason's) and mirror it: `grep -rn "mason\|AppService" --include="*.go" -l` there, copy its shape for a `strata` layer asserting `GetCloudState` over the edge returns ≥10 nodes, all with non-UNSPECIFIED status, and `observed_at` within 60s. Run the suite against live dMon; commit + PR.

---

## Execution order & parallelism

```
B1 (proto) ──> B2 (porter) ──────────────┐
   └────────> B3..B11 (atlas, sequential)─┼─> B12 (interchange) ─> B13 (deploy) ─> B14 (conformance)
Plan A (herald) ── independent ───────────┘        (A7 must land before B13 step 4's login test)
```

B2 and B3-B11 are independent of each other; Plan A is independent of everything until B13. One ticket per builder if dispatched (B1 must merge first; then porter and atlas can run as parallel single-ticket dispatches).

## Self-review notes (already applied)

- **Spec coverage**: every design-doc section maps to a task — API (B1), collectors+porter (B2/B6-B8), DORMANT derivation (B4), static topology+edges (B5), OIDC/session (B10), page+staleness+panel+ops-region (B11), edge REST (B12), RBAC/tailnet/OIDC-client deploy (B13), conformance (B14). Ops seams: action region (B11 step 4), token retention (B10 session), read-only SA (B13).
- **Type consistency**: `collect.WorkloadFacts`/`Sources`/`Loop.State()`/`CollectNow` names used identically across B6-B11; proto field names match B1's strata.proto throughout.
- **Known intentional indirections** (verify-at-execution, flagged in-task): cwbv1.App field names (B7), mason's exact authInject pattern (B12), tailscale-auth secret namespace (B13), `cw token` acquisition (B13 step 4). Each carries explicit "read the real code, match it" instructions.
- **protojson enum casing**: the JS keys off `NODE_STATUS_*` enum names and camelCase fields — that's what `protojson.Marshal` emits for this schema; the B11 JSON-shape test pins it.
