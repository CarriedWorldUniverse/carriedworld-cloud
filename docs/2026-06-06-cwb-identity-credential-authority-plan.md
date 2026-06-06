# CWB Multi-Consumer Identity & Credential Authority — Implementation Plan (Spec A)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let any consumer org authorize its identities' (human or AI) actions against CWB without the identity holding raw credentials — federated identity proof at herald, brokered external credentials at custodian, org-isolated.

**Architecture:** *Extend* herald (it already has Orgs, an EdDSA OIDC token core, a `GrantMux`, and a casket-key `AgentGrant`) with a **federated-issuer grant** so an enrolled identity proves itself with an external attestation (k8s SA token) instead of a held key. *Build* custodian as an external-credential vault keyed by the herald identity. Nexus is the first consumer (Spec B / NEX-467).

**Tech Stack:** Go; herald (`/home/jacinta/src/herald`: `internal/oidc`, `internal/identity`, `internal/store`); k8s `TokenReview` (`k8s.io/client-go`); casket (Ed25519, the issued-session substrate); `cwb-client` (the consumer lib).

**Spec:** `carriedworld-cloud/docs/2026-06-06-cwb-identity-credential-authority-design.md` (main `f3f2078`).

---

## Decomposition (this is multiple subsystems — four sequenced sub-plans)

Per the process, Spec A is broken into sub-plans, each producing working, testable software on its own. **This document fully details Sub-plan 1** (the foundation) and specifies the interface contracts + scope for 2–4, which get their own bite-sized detail when picked up (each needs a grounding pass in its target package).

1. **Herald — federated identity grant** *(detailed below; the foundation).* An identity enrolled as `{issuer, subject}` exchanges an external attestation for a short-lived herald token, org-scoped. No held key.
2. **Custodian — credential vault.** External creds granted per herald-identity; retrieved/brokered by herald identity; own-org only.
3. **Genesis / consumer-org grant.** Management org registers a consumer org + its org-scoped authority + its trusted issuers.
4. **Nexus consumption (= NEX-467 / Spec B).** k8s-SA-vouched pods get brokered herald sessions; the agent fleet behind the gateway, zero raw identity secrets.

**Build order:** 1 → 3 → 2 → 4. (Genesis registration is small and unblocks end-to-end testing of the grant; custodian builds on a working identity; nexus consumes both.)

**Cross-cutting interface contracts (frozen here so sub-plans compose):**
- **Issuer adapter:** `type IssuerVerifier interface { Verify(ctx, attestation string) (subject string, err error) }`. The k8s adapter wraps `TokenReview`; `subject` is `system:serviceaccount:<ns>:<name>`.
- **Enrollment binding:** an identity (`store.User`) gains zero-or-more `FederatedBinding{ IssuerID string; Subject string }`. `(IssuerID, Subject)` is unique within an org and resolves to exactly one identity.
- **Herald token:** unchanged shape from `AgentGrant` (short-lived access token, claims stamped from the record incl. `act.sub`), so custodian + cwb-client consume one token type regardless of grant path.

---

## Sub-plan 1 — Herald federated identity grant

**Files:**
- Modify: `internal/store/store.go` — add `FederatedBinding` + the trusted-issuer record; store methods.
- Create: `internal/store/federated.go` — binding/issuer CRUD + lookup (keep `store.go` from growing).
- Create: `internal/issuer/issuer.go` — the `IssuerVerifier` interface + registry.
- Create: `internal/issuer/k8s.go` — the k8s `TokenReview` adapter.
- Create: `internal/oidc/federated_grant.go` — the new grant (mirrors `agent_grant.go`).
- Modify: `cmd/herald/main.go:69` — register the federated grant in the `GrantMux`.
- Tests: `internal/store/federated_test.go`, `internal/issuer/k8s_test.go`, `internal/oidc/federated_grant_test.go`.

**Pattern to follow:** `internal/oidc/agent_grant.go` is the template — same `IdentityResolver` reuse (`IsActive`, `EffectiveScopes`, `EnabledProducts`), same "claims stamped from the record, never client input" rule, same uniform-401 on any failure. The federated grant differs only in *how the subject is established*: an issuer-verified attestation instead of a casket-signed assertion.

### Task 1.1: Enrollment storage — federated bindings + trusted issuers

**Files:** Create `internal/store/federated.go` (+ types in `store.go`); Test `internal/store/federated_test.go`.

- [ ] **Step 1: Write the failing test** — enroll a binding, resolve it, enforce org-uniqueness.
```go
func TestFederatedBindingResolves(t *testing.T) {
	s := newTestStore(t) // existing helper in store_test.go
	iss := s.RegisterIssuer(ctx, "org1", store.Issuer{Kind: "k8s", Ref: "nexus-cluster"})
	s.AddBinding(ctx, "org1", "user-plumb", store.FederatedBinding{IssuerID: iss.ID, Subject: "system:serviceaccount:nexus:plumb"})
	uid, err := s.ResolveBinding(ctx, "org1", iss.ID, "system:serviceaccount:nexus:plumb")
	if err != nil || uid != "user-plumb" {
		t.Fatalf("resolve = %q, %v; want user-plumb", uid, err)
	}
	// Cross-org isolation: the same subject in org2 must NOT resolve to org1's user.
	if _, err := s.ResolveBinding(ctx, "org2", iss.ID, "system:serviceaccount:nexus:plumb"); err == nil {
		t.Error("binding resolved across orgs")
	}
}
```
- [ ] **Step 2: Run it; expect FAIL** (types/methods undefined). `go test ./internal/store/ -run TestFederatedBinding`.
- [ ] **Step 3: Implement** `Issuer`, `FederatedBinding` structs + `RegisterIssuer`/`AddBinding`/`ResolveBinding` in `federated.go`, mirroring the SQL/store idiom already in `store.go` (same DB handle, same migration style — read `store.go`'s existing `CreateUser`/`ListScopes` for the exact pattern). Bindings carry `OrgID`; `ResolveBinding` filters on it (org isolation).
- [ ] **Step 4: Run it; expect PASS.**
- [ ] **Step 5: Commit** `feat(herald): federated identity bindings + trusted issuers`.

### Task 1.2: Issuer verifier interface + k8s TokenReview adapter

**Files:** Create `internal/issuer/issuer.go`, `internal/issuer/k8s.go`; Test `internal/issuer/k8s_test.go`.

- [ ] **Step 1: Write the failing test** — a fake `TokenReview` client; a valid review returns the SA subject + audience check; an unauthenticated review errors.
```go
func TestK8sVerifier(t *testing.T) {
	fc := fakeclient.NewSimpleClientset()
	fc.PrependReactor("create", "tokenreviews", func(a ktesting.Action) (bool, runtime.Object, error) {
		tr := a.(ktesting.CreateAction).GetObject().(*authnv1.TokenReview)
		tr.Status = authnv1.TokenReviewStatus{Authenticated: true,
			User: authnv1.UserInfo{Username: "system:serviceaccount:nexus:plumb"},
			Audiences: []string{"herald"}}
		return true, tr, nil
	})
	v := issuer.NewK8s(fc, "herald")
	sub, err := v.Verify(ctx, "any-token")
	if err != nil || sub != "system:serviceaccount:nexus:plumb" { t.Fatalf("got %q,%v", sub, err) }
}
```
- [ ] **Step 2: Run it; expect FAIL.**
- [ ] **Step 3: Implement** `IssuerVerifier` interface in `issuer.go`; `K8s` in `k8s.go` — `Verify` builds an `authnv1.TokenReview{Spec:{Token, Audiences:[expectedAud]}}`, calls `AuthenticationV1().TokenReviews().Create`, requires `Status.Authenticated` + the audience present, returns `Status.User.Username`.
- [ ] **Step 4: Run it; expect PASS.**
- [ ] **Step 5: Commit** `feat(herald): issuer verifier + k8s TokenReview adapter`.

### Task 1.3: The federated grant

**Files:** Create `internal/oidc/federated_grant.go`; Test `internal/oidc/federated_grant_test.go`.

- [ ] **Step 1: Write the failing test** — wire a fake `IdentityResolver` + a stub `IssuerVerifier` + a store with a binding; POST a token-exchange request; assert a herald token comes back with the enrolled identity's stamped claims; assert blocked/unknown-subject/cross-org all 401.
```go
func TestFederatedGrantIssues(t *testing.T) {
	g := oidc.NewFederatedGrant(provider, idsvc, store, issuerRegistry, refresh)
	rr := postForm(g.ServeToken, url.Values{
		"grant_type": {"urn:cwb:params:oauth:grant-type:federated"},
		"issuer": {issuerID}, "attestation": {"sa-token"}})
	requireToken(t, rr) // 200 + access_token whose sub == the enrolled user, scopes from EffectiveScopes
}
```
- [ ] **Step 2: Run it; expect FAIL.**
- [ ] **Step 3: Implement** `FederatedGrant.ServeToken` mirroring `AgentGrant.ServeToken`/`issue`: parse `grant_type` (a new `urn:cwb:params:oauth:grant-type:federated`), look up the issuer's `IssuerVerifier`, `Verify(attestation)→subject`, `store.ResolveBinding(org, issuer, subject)→userID`, then reuse `AgentGrant`'s tail verbatim — `IsActive` (block cascade), `EffectiveScopes`, `EnabledProducts`, stamp claims **from the record**, `provider` issues the token. Uniform 401 on every failure.
- [ ] **Step 4: Run it; expect PASS.**
- [ ] **Step 5: Commit** `feat(herald): federated-attestation token grant`.

### Task 1.4: Wire the grant into herald

**Files:** Modify `cmd/herald/main.go` (the `NewGrantMux` call ~line 69); Test: extend an existing herald integration test if present, else a `main`-level smoke test.

- [ ] **Step 1:** Construct the issuer registry (k8s adapter from in-cluster config or `HERALD_K8S_*` env) + `oidc.NewFederatedGrant(...)`, and add it to `oidc.NewGrantMux(agentGrant, federatedGrant, ...)`.
- [ ] **Step 2: Build** `go build ./...` (expect OK).
- [ ] **Step 3:** Run the full herald test suite `go test ./...` — expect green (the agent-grant path unchanged; federated path covered by 1.3).
- [ ] **Step 4: Commit** `feat(herald): register the federated grant in the GrantMux`.

**Sub-plan 1 acceptance:** an enrolled `{k8s-issuer, SA-subject}` identity exchanges a (fake-in-test, real-in-cluster) SA token for a herald access token carrying its org-scoped record claims; blocked/unknown/cross-org are rejected; the casket `AgentGrant` path is untouched.

---

## Sub-plan 2 — Custodian credential vault *(interfaces frozen; detail when picked up)*

**What it is:** the external-credential vault keyed by herald identity. Note `nexus/credentials` is nexus's *own* per-aspect store — custodian here is the CWB-level, herald-keyed vault, a new component (likely a herald subsystem or a sibling service behind interchange; settle location in this sub-plan's grounding pass).

**Interface contract:**
- `Grant(orgID, identityID, cred CredentialRef)` — management/admin enrolls which identity may use which external credential.
- `Broker(ctx, heraldToken, action) (result | shortLivedToken, err)` — verify the herald token (issuer = herald, signature via JWKS), extract identity + org, check the grant is for *this* identity in *its own org*, then either proxy the action or mint a short-lived scoped token. **Raw secret never returned.**
- Revocation bites at `Broker` time (re-check the grant + token validity every call).

**Acceptance:** a herald-identity token retrieves only its own-org granted credential's *use*; a revoked grant or cross-org token is refused; the raw secret never crosses the boundary.

## Sub-plan 3 — Genesis / consumer-org grant *(small; do before 2)*

**What it is:** the management-org admin flow (herald `internal/adminapi`/`grpcadmin`) to register a consumer org, grant it an org-scoped authority, and register its trusted issuers (Task 1.1's `RegisterIssuer`) + enroll its first identities. One-time, operator-present.

**Acceptance:** from a clean herald, the management admin can stand up a consumer org whose identities then authenticate via Sub-plan 1 — fully autonomous thereafter.

## Sub-plan 4 — Nexus consumption (NEX-467 / Spec B) *(its own spec + plan)*

The cw init-container presents the pod's k8s SA token to herald's federated grant → herald token → custodian-brokered creds; the hosting chart's `identity.mode=custodian` realizes it. Tracked as NEX-467; gets its own brainstorm→spec→plan once Sub-plans 1–3 land.

---

## Self-review notes

- **Spec coverage:** identity+rights → Sub-plan 1 (+3 for genesis); federated external attestation (no held key) → 1.2/1.3; per-identity enrollment + org isolation → 1.1; custodian keyed-vault + brokered use → Sub-plan 2; consumer realization → Sub-plan 4. All spec sections map.
- **No invented herald APIs:** Sub-plan 1 reuses the *named, verified* seams (`GrantMux`, `AgentGrant`, `IdentityResolver`, `store` idiom); the implementer follows `agent_grant.go` for exact call shapes.
- Sub-plans 2–4 are intentionally interface-level here (each needs its own grounding pass in its target package before bite-sized tasks) — that is the decomposition the process calls for, not deferred detail within a single plan.
