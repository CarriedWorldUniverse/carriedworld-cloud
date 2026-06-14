# herald ID-JAG agent-auth model — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make herald mint audience-scoped, IdP-signed **ID-JAGs** (auth.md / RFC-8693 identity-assertion grants) for its agents, and make `heraldauth` verify them (audience + replay + responsible-human), so a CWB service can accept an ID-JAG directly as a bearer that is cryptographically bound to one target service.

**Architecture:** Extend herald's *existing* RFC-7523 jwt-bearer agent grant. The agent already proves possession of its casket key by signing an assertion; today that mints a general access token. We add a second mint path — `POST /agent/identity` — that produces an **audience-scoped, short-lived** token (`aud=<target service>`, `jti`, `client_id`, `act.sub=responsible_human`) advertised via the `agent_auth` discovery block. On the verify side, `heraldauth` gains opt-in `aud` enforcement + a `jti` replay cache. Internal-first: herald trusts only itself; federation seams stay dormant. The minted ID-JAG is used directly as the bearer (no second token-exchange step in the MVP).

**Tech Stack:** Go, `github.com/go-jose/go-jose/v4` (EdDSA), herald's `internal/oidc` provider + `internal/identity` + `internal/store`, `heraldauth` consumer library, `casket-go` (agent key derivation). Repo: **CarriedWorldUniverse/herald**. Work on a feature branch off `main`.

**Repo orientation (already verified against `main`):**
- `internal/oidc/provider.go` — `Provider`: `SignToken(claims)` stamps `iss/iat/exp` (TTL `p.ttl`); `TokenURL()` = issuer+`/token`; `Handler()` mounts routes; `handleDiscovery` serves `/.well-known/openid-configuration`; `SetTokenHandler`, `SetRevokeHandler`, `SetAuthorizeHandler`.
- `internal/oidc/agent_grant.go` — `AgentGrant`: `ServeToken` (POST /token, jwt-bearer), `issue()` verifies the assertion (iss==sub, registered casket key, `aud`==tokenURL, exp, block cascade) then `accessClaims` → `SignToken`. `assertionClaims` + `audienceMatches`.
- `internal/oidc/claims.go` — `accessClaims(ctx, id, u)` builds `{sub,kind,org,scope,products}` + agent `{agent_fp, act:{sub:responsible_human}, human_fp}` FROM THE RECORD.
- `heraldauth/heraldauth.go` — `Verifier.Verify` checks signature (JWKS) + `iss` + `exp`; `Config{Issuer, JWKSURL, ...}`; `tokenClaims` struct; `Identity{Subject,Kind,Org,ResponsibleHuman,Scopes,Products,AgentFP,HumanFP}`.
- Tests: `internal/oidc/agent_grant_test.go` (`testStack`, `signAssertion`, `postAssertion`), `internal/oidc/oidc_test.go` (`newTestProvider`, discovery test), `heraldauth/heraldauth_test.go` (`liveHerald`).

**Conventions to follow:** errors from `issue()`-style helpers are deliberately coarse and mapped to a uniform 401 at the handler (don't leak which check failed); claims are always stamped FROM THE RECORD, never from client input; `aud` of an assertion is compared against the *issuer-derived* canonical URL, never `r.Host` (proxy-safe — see `TestAgentGrant_AudienceFromIssuer_WorksBehindProxy`).

---

## File structure

| File | Responsibility | Change |
|---|---|---|
| `heraldauth/heraldauth.go` | consumer verify lib | add `Config.Audience`; parse `aud`/`jti`; opt-in audience check; jti replay cache; `ProtectedResourceMetadata`/`ProtectedResourceHandler` |
| `heraldauth/heraldauth_test.go` | verify-side tests | aud accept/reject, replay reject, protected-resource doc |
| `heraldauth/idjag_e2e_test.go` | end-to-end | mint via `/agent/identity` → verify, wrong-aud, replay, responsible-human |
| `internal/oidc/provider.go` | OIDC provider | `SignShortLived`; `IdentityURL`; `SetIdentityHandler`+`handleIdentity`+route; `oauth-authorization-server` route; `agent_auth` discovery block |
| `internal/oidc/provider_idjag.go` | (new) provider ID-JAG helpers | `SignShortLived`, `IdentityURL`, identity-handler plumbing — keep `provider.go` focused |
| `internal/oidc/agent_grant.go` | agent grant | refactor `verifyAssertion` out of `issue`; add `mintIDJAG`; add `ServeIdentity`; `idjagTTL` field + `SetIDJAGTTL` |
| `internal/oidc/agent_grant_test.go` | grant tests | ID-JAG mint claim-set, wrong-assertion 401, missing-audience 400 |
| `internal/oidc/oidc_test.go` | provider tests | discovery `agent_auth` block; `oauth-authorization-server` route |
| `cmd/herald/main.go` | wiring | `provider.SetIdentityHandler(...)` |

New constant shared by mint + verify + discovery: `idJAGType = "urn:ietf:params:oauth:token-type:id-jag"` (define once in `agent_grant.go`, reference elsewhere within the `oidc` package; `heraldauth` defines its own local copy since it's a separate module path — repeated string literal is fine across the package boundary).

---

## Task 1: heraldauth — parse `aud`/`jti`, opt-in audience enforcement

**Files:**
- Modify: `heraldauth/heraldauth.go` (`Config`, `Verifier`, `New`, `tokenClaims`, `Verify`)
- Test: `heraldauth/heraldauth_test.go`

- [ ] **Step 1: Write the failing test**

Add to `heraldauth/heraldauth_test.go`. This reuses the existing `liveHerald` helper but the ID-JAG path doesn't exist yet, so for this verifier-only task we mint a *general* token (which has no `aud`) and assert: (a) a verifier with no `Audience` configured still accepts it (backward compatible); (b) a verifier WITH `Audience` set rejects a token whose `aud` is absent/mismatched.

```go
func TestVerifier_AudienceOptIn_BackwardCompatible(t *testing.T) {
	issuer, tok, _, _, _ := liveHerald(t)
	ctx := context.Background()
	// No Audience configured → aud is not enforced (existing behavior).
	v, err := heraldauth.New(ctx, heraldauth.Config{Issuer: issuer})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if _, err := v.Verify(ctx, tok); err != nil {
		t.Fatalf("a verifier with no Audience must still accept a general token: %v", err)
	}
}

func TestVerifier_AudienceConfigured_RejectsTokenWithoutMatchingAud(t *testing.T) {
	issuer, tok, _, _, _ := liveHerald(t)
	ctx := context.Background()
	// Audience configured, but the general token carries no `aud` → reject.
	v, err := heraldauth.New(ctx, heraldauth.Config{Issuer: issuer, Audience: "ledger"})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if _, err := v.Verify(ctx, tok); err == nil {
		t.Fatal("a verifier configured with Audience must reject a token lacking that aud")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./heraldauth/ -run 'TestVerifier_Audience' -v`
Expected: `TestVerifier_AudienceConfigured_RejectsTokenWithoutMatchingAud` FAILS (token accepted despite no aud — audience not yet enforced). `TestVerifier_AudienceOptIn_BackwardCompatible` PASSES already.

- [ ] **Step 3: Add `Audience` to `Config`**

In `heraldauth/heraldauth.go`, add to the `Config` struct (after `JWKSRefresh`):

```go
	// Audience, if set, is this service's own identifier; Verify then
	// requires the token's `aud` claim to include it. Leave empty to accept
	// any audience (backward compatible — pre-ID-JAG tokens carry no aud).
	Audience string
```

- [ ] **Step 4: Add `audience` field to `Verifier` + wire it in `New`**

Add to the `Verifier` struct (after `now func() time.Time`):

```go
	audience string
```

In `New`, change the verifier construction line:

```go
	v := &Verifier{issuer: cfg.Issuer, http: hc, refresh: refresh, now: nowFn}
```

to:

```go
	v := &Verifier{issuer: cfg.Issuer, audience: cfg.Audience, http: hc, refresh: refresh, now: nowFn}
```

- [ ] **Step 5: Parse `aud`/`jti` in `tokenClaims`**

In `tokenClaims` (the struct mirroring the access-token shape), add two fields:

```go
	Audience any    `json:"aud"`
	JTI      string `json:"jti"`
```

- [ ] **Step 6: Enforce audience in `Verify`**

In `Verify`, after the existing expiry check (`if c.Expiry == 0 || v.now().After(...) { ... }`) and before assembling `id`, add:

```go
	if v.audience != "" && !audienceContains(c.Audience, v.audience) {
		return Identity{}, fmt.Errorf("heraldauth: audience %v does not include %q", c.Audience, v.audience)
	}
```

Add this helper at the bottom of the file:

```go
// audienceContains reports whether a JWT aud claim (string or []string)
// includes want.
func audienceContains(aud any, want string) bool {
	switch a := aud.(type) {
	case string:
		return a == want
	case []any:
		for _, v := range a {
			if s, _ := v.(string); s == want {
				return true
			}
		}
	}
	return false
}
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `go test ./heraldauth/ -run 'TestVerifier_Audience' -v`
Expected: both PASS.

Run the full verifier suite to confirm no regression:
Run: `go test ./heraldauth/ -v`
Expected: all PASS (existing tests configure no `Audience`, so enforcement is skipped).

- [ ] **Step 8: Commit**

```bash
git add heraldauth/heraldauth.go heraldauth/heraldauth_test.go
git commit -m "heraldauth: opt-in audience enforcement for ID-JAGs"
```

---

## Task 2: heraldauth — jti replay cache

**Files:**
- Modify: `heraldauth/heraldauth.go` (`Verifier`, `New`, `Verify`, new `markJTI`)
- Test: `heraldauth/heraldauth_test.go`

- [ ] **Step 1: Write the failing test**

The replay test needs a token that carries a `jti`. General tokens don't, so we craft one with herald's own signer via the provider's `SignShortLived` — which does not exist yet either. To keep this task self-contained on the verify side, use a small local helper that signs a token with a `jti` using a throwaway herald provider, and point the verifier at it. Add to `heraldauth/heraldauth_test.go`:

```go
// liveHeraldWithClaims spins a real herald and returns a token herald itself
// signed over the given extra claims (merged with iss/iat/exp), so heraldauth
// verifies a genuine-issuer token whose shape we control (e.g. carrying jti).
func liveHeraldWithClaims(t *testing.T, extra map[string]any) (issuer, token string) {
	t.Helper()
	_, signKey, _ := ed25519.GenerateKey(nil)
	srv := httptest.NewServer(nil)
	t.Cleanup(srv.Close)
	p, _ := herald.NewProvider(herald.Config{Issuer: srv.URL + "/", SigningKey: signKey})
	srv.Config.Handler = p.Handler()
	tok, err := p.SignToken(extra)
	if err != nil {
		t.Fatalf("SignToken: %v", err)
	}
	return srv.URL + "/", tok
}

func TestVerifier_ReplayedJTI_Rejected(t *testing.T) {
	ctx := context.Background()
	issuer, tok := liveHeraldWithClaims(t, map[string]any{
		"sub": "agent:anvil", "kind": "agent", "jti": "jti-replay-001",
	})
	v, err := heraldauth.New(ctx, heraldauth.Config{Issuer: issuer})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if _, err := v.Verify(ctx, tok); err != nil {
		t.Fatalf("first presentation must succeed: %v", err)
	}
	if _, err := v.Verify(ctx, tok); err == nil {
		t.Fatal("second presentation of the same jti must be rejected as a replay")
	}
}

func TestVerifier_DistinctJTI_BothAccepted(t *testing.T) {
	ctx := context.Background()
	issuer, tok1 := liveHeraldWithClaims(t, map[string]any{"sub": "a", "jti": "jti-A"})
	_, tok2 := liveHeraldWithClaims(t, map[string]any{"sub": "a", "jti": "jti-B"})
	v, _ := heraldauth.New(ctx, heraldauth.Config{Issuer: issuer})
	if _, err := v.Verify(ctx, tok1); err != nil {
		t.Fatalf("tok1: %v", err)
	}
	// tok2 is from a different issuer instance; verify it on its own verifier.
	issuer2, tok2b := liveHeraldWithClaims(t, map[string]any{"sub": "a", "jti": "jti-C"})
	_ = tok2
	v2, _ := heraldauth.New(ctx, heraldauth.Config{Issuer: issuer2})
	if _, err := v2.Verify(ctx, tok2b); err != nil {
		t.Fatalf("distinct jti must be accepted: %v", err)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./heraldauth/ -run 'TestVerifier_ReplayedJTI' -v`
Expected: FAIL — the second `Verify` currently succeeds (no replay tracking).

- [ ] **Step 3: Add the replay cache to `Verifier` + init in `New`**

Add to the `Verifier` struct:

```go
	seenMu sync.Mutex
	seen   map[string]int64 // jti -> exp unix; replay guard
```

In `New`, after constructing `v`, initialize the map (edit the construction to include it):

```go
	v := &Verifier{issuer: cfg.Issuer, audience: cfg.Audience, http: hc, refresh: refresh, now: nowFn, seen: make(map[string]int64)}
```

- [ ] **Step 4: Add `markJTI` + enforce in `Verify`**

Add this method near the other `Verifier` methods:

```go
// markJTI records a token's jti, returning false if it was already seen
// (replay). Expired entries are evicted on each call so the map stays bounded
// by the count of currently-live tokens.
func (v *Verifier) markJTI(jti string, exp int64) bool {
	v.seenMu.Lock()
	defer v.seenMu.Unlock()
	nowUnix := v.now().Unix()
	for j, e := range v.seen {
		if e < nowUnix {
			delete(v.seen, j)
		}
	}
	if _, dup := v.seen[jti]; dup {
		return false
	}
	v.seen[jti] = exp
	return true
}
```

In `Verify`, after the audience check (Task 1, Step 6) and before assembling `id`, add:

```go
	if c.JTI != "" && !v.markJTI(c.JTI, c.Expiry) {
		return Identity{}, errors.New("heraldauth: token replayed (jti seen)")
	}
```

(`sync` and `errors` are already imported in this file.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `go test ./heraldauth/ -run 'TestVerifier_(ReplayedJTI|DistinctJTI)' -v`
Expected: both PASS.

Run: `go test ./heraldauth/ -v`
Expected: all PASS (general tokens have empty `jti` → replay guard skipped).

- [ ] **Step 6: Commit**

```bash
git add heraldauth/heraldauth.go heraldauth/heraldauth_test.go
git commit -m "heraldauth: jti replay cache for ID-JAGs"
```

---

## Task 3: heraldauth — protected-resource metadata helper

**Files:**
- Modify: `heraldauth/heraldauth.go` (new exported `ProtectedResourceMetadata` + `ProtectedResourceHandler`)
- Test: `heraldauth/heraldauth_test.go`

- [ ] **Step 1: Write the failing test**

```go
func TestProtectedResourceHandler_PointsAtHerald(t *testing.T) {
	h := heraldauth.ProtectedResourceHandler("ledger", "https://herald.test/")
	srv := httptest.NewServer(h)
	defer srv.Close()
	resp, err := http.Get(srv.URL + "/.well-known/oauth-protected-resource")
	if err != nil || resp.StatusCode != 200 {
		t.Fatalf("get: %v status=%d", err, resp.StatusCode)
	}
	defer resp.Body.Close()
	var d map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&d); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if d["resource"] != "ledger" {
		t.Fatalf("resource = %v, want ledger", d["resource"])
	}
	servers, _ := d["authorization_servers"].([]any)
	if len(servers) != 1 || servers[0] != "https://herald.test/" {
		t.Fatalf("authorization_servers = %v, want [https://herald.test/]", d["authorization_servers"])
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./heraldauth/ -run TestProtectedResourceHandler -v`
Expected: FAIL — `undefined: heraldauth.ProtectedResourceHandler`.

- [ ] **Step 3: Implement the helpers**

Add to `heraldauth/heraldauth.go` (after the `Config`/`Verifier` definitions):

```go
// ProtectedResourceMetadata returns the RFC 9728 oauth-protected-resource
// document a CWB service publishes so that an agent which receives a 401 can
// discover herald as the authorization server. `resource` is the service's
// own audience identifier; `authServer` is herald's issuer URL.
func ProtectedResourceMetadata(resource, authServer string) map[string]any {
	return map[string]any{
		"resource":              resource,
		"authorization_servers": []string{authServer},
	}
}

// ProtectedResourceHandler serves ProtectedResourceMetadata as JSON. Mount it
// at /.well-known/oauth-protected-resource on the CWB service.
func ProtectedResourceHandler(resource, authServer string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(ProtectedResourceMetadata(resource, authServer))
	})
}
```

(`net/http` and `encoding/json` are already imported.)

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./heraldauth/ -run TestProtectedResourceHandler -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add heraldauth/heraldauth.go heraldauth/heraldauth_test.go
git commit -m "heraldauth: oauth-protected-resource metadata helper"
```

---

## Task 4: provider — `SignShortLived` + `IdentityURL`

**Files:**
- Create: `internal/oidc/provider_idjag.go`
- Modify: `internal/oidc/provider.go` (refactor `SignToken` to share `signClaims`)
- Test: `internal/oidc/oidc_test.go`

- [ ] **Step 1: Write the failing test**

Add to `internal/oidc/oidc_test.go`:

```go
func TestProvider_SignShortLived_StampsShortExpAndPreservesAud(t *testing.T) {
	p := newTestProvider(t)
	tok, err := p.SignShortLived(map[string]any{
		"sub": "agent:anvil", "aud": "ledger", "jti": "j1",
	}, 30*time.Second)
	if err != nil {
		t.Fatalf("SignShortLived: %v", err)
	}
	claims, err := p.VerifyToken(tok)
	if err != nil {
		t.Fatalf("VerifyToken: %v", err)
	}
	if claims["aud"] != "ledger" || claims["jti"] != "j1" {
		t.Fatalf("aud/jti not preserved: %+v", claims)
	}
	iat, _ := claims["iat"].(float64)
	exp, _ := claims["exp"].(float64)
	if d := exp - iat; d < 1 || d > 60 {
		t.Fatalf("short exp expected ~30s, got exp-iat=%v", d)
	}
}

func TestProvider_IdentityURL(t *testing.T) {
	p := newTestProvider(t) // issuer "https://herald.test/"
	if got := p.IdentityURL(); got != "https://herald.test/agent/identity" {
		t.Fatalf("IdentityURL = %q", got)
	}
}
```

Add `"time"` to the `oidc_test.go` import block if not present.

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/oidc/ -run 'TestProvider_(SignShortLived|IdentityURL)' -v`
Expected: FAIL — `p.SignShortLived` / `p.IdentityURL` undefined.

- [ ] **Step 3: Refactor `SignToken` to share `signClaims`**

In `internal/oidc/provider.go`, replace the body of `SignToken` so it delegates:

```go
func (p *Provider) SignToken(claims map[string]any) (string, error) {
	return p.signClaims(claims, p.ttl)
}

func (p *Provider) signClaims(claims map[string]any, ttl time.Duration) (string, error) {
	now := p.now()
	out := make(map[string]any, len(claims)+3)
	for k, v := range claims {
		out[k] = v
	}
	out["iss"] = p.issuer
	out["iat"] = now.Unix()
	out["exp"] = now.Add(ttl).Unix()

	payload, err := json.Marshal(out)
	if err != nil {
		return "", fmt.Errorf("oidc.SignToken: marshal: %w", err)
	}
	obj, err := p.signer.Sign(payload)
	if err != nil {
		return "", fmt.Errorf("oidc.SignToken: sign: %w", err)
	}
	return obj.CompactSerialize()
}
```

- [ ] **Step 4: Add `SignShortLived` + `IdentityURL` in the new file**

Create `internal/oidc/provider_idjag.go`:

```go
package oidc

import (
	"strings"
	"time"
)

// SignShortLived signs a claim set with an explicit (typically short) TTL.
// Used for audience-scoped ID-JAGs whose lifetime is deliberately brief so a
// leaked assertion is useful only momentarily.
func (p *Provider) SignShortLived(claims map[string]any, ttl time.Duration) (string, error) {
	return p.signClaims(claims, ttl)
}

// IdentityURL returns the canonical agent-identity endpoint — issuer +
// "/agent/identity". This is what the discovery doc advertises as the
// agent_auth identity_endpoint and what agents set as the `aud` of the
// proof-of-possession assertion they present there.
func (p *Provider) IdentityURL() string {
	return strings.TrimRight(p.issuer, "/") + "/agent/identity"
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `go test ./internal/oidc/ -run 'TestProvider_(SignShortLived|IdentityURL)' -v`
Expected: both PASS.

Run: `go test ./internal/oidc/ -v`
Expected: all PASS (the `SignToken` refactor preserves behavior — existing agent/human/refresh grant tests cover it).

- [ ] **Step 6: Commit**

```bash
git add internal/oidc/provider.go internal/oidc/provider_idjag.go internal/oidc/oidc_test.go
git commit -m "oidc: SignShortLived + IdentityURL for ID-JAG minting"
```

---

## Task 5: agent grant — `verifyAssertion` refactor, `mintIDJAG`, `ServeIdentity`

**Files:**
- Modify: `internal/oidc/agent_grant.go` (extract `verifyAssertion`; add `idjagTTL`, `SetIDJAGTTL`, `mintIDJAG`, `ServeIdentity`, `randomJTI`, `idJAGType`)
- Test: `internal/oidc/agent_grant_test.go`

- [ ] **Step 1: Write the failing test**

Add to `internal/oidc/agent_grant_test.go`. A new helper wires the identity endpoint and posts an identity request; the tests assert the conformant ID-JAG claim set and the error cases.

```go
// testStackWithIdentity is like testStack but also wires /agent/identity.
func testStackWithIdentity(t *testing.T) (*herald.Provider, *identity.Service, *httptest.Server, *herald.AgentGrant) {
	t.Helper()
	s, err := store.Open(":memory:")
	if err != nil {
		t.Fatalf("store.Open: %v", err)
	}
	t.Cleanup(func() { _ = s.Close() })
	svc := identity.New(s)
	_, priv, _ := ed25519.GenerateKey(nil)
	p, err := herald.NewProvider(herald.Config{Issuer: "https://herald.test/", SigningKey: priv})
	if err != nil {
		t.Fatalf("NewProvider: %v", err)
	}
	ag := herald.NewAgentGrant(p, svc, nil)
	p.SetTokenHandler(ag)
	p.SetIdentityHandler(http.HandlerFunc(ag.ServeIdentity))
	srv := httptest.NewServer(p.Handler())
	t.Cleanup(srv.Close)
	return p, svc, srv, ag
}

func postIdentity(t *testing.T, identityURL, assertion, audience string) (*http.Response, map[string]any) {
	t.Helper()
	form := url.Values{
		"type":      {"identity_assertion"},
		"assertion": {assertion},
		"audience":  {audience},
	}
	resp, err := http.PostForm(identityURL, form)
	if err != nil {
		t.Fatalf("POST /agent/identity: %v", err)
	}
	var body map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&body)
	resp.Body.Close()
	return resp, body
}

func TestAgentIdentity_MintsConformantIDJAG(t *testing.T) {
	p, svc, srv, _ := testStackWithIdentity(t)
	ctx := context.Background()
	org, _ := svc.CreateOrg(ctx, "acme")
	h, _ := svc.CreateHuman(ctx, org.ID, "jacinta")
	priv, pub, _ := casket.DeriveAgentKey([]byte(grantTestSeed), "anvil")
	a, _ := svc.CreateAgent(ctx, org.ID, "anvil", h.ID, pub)
	_ = svc.GrantScope(ctx, a.ID, "repo:write", h.ID)

	// The assertion's aud is the IDENTITY endpoint (not /token).
	assertion := signAssertion(t, a.ID, p.IdentityURL(), priv, time.Now().Add(2*time.Minute))
	resp, body := postIdentity(t, srv.URL+"/agent/identity", assertion, "ledger")
	if resp.StatusCode != 200 {
		t.Fatalf("identity status=%d body=%+v", resp.StatusCode, body)
	}
	if body["issued_token_type"] != "urn:ietf:params:oauth:token-type:id-jag" {
		t.Fatalf("issued_token_type = %v", body["issued_token_type"])
	}
	idjag, _ := body["access_token"].(string)
	claims, err := p.VerifyToken(idjag)
	if err != nil {
		t.Fatalf("verify id-jag: %v", err)
	}
	if claims["aud"] != "ledger" {
		t.Fatalf("aud = %v, want ledger", claims["aud"])
	}
	if claims["sub"] != a.ID {
		t.Fatalf("sub = %v, want %v", claims["sub"], a.ID)
	}
	if claims["client_id"] != a.ID {
		t.Fatalf("client_id = %v, want %v", claims["client_id"], a.ID)
	}
	if jti, _ := claims["jti"].(string); jti == "" {
		t.Fatal("id-jag must carry a jti")
	}
	act, _ := claims["act"].(map[string]any)
	if act == nil || act["sub"] != h.ID {
		t.Fatalf("act.sub must be the responsible human %v, got %+v", h.ID, claims["act"])
	}
}

func TestAgentIdentity_WrongAssertion_Rejected(t *testing.T) {
	p, svc, srv, _ := testStackWithIdentity(t)
	ctx := context.Background()
	org, _ := svc.CreateOrg(ctx, "acme")
	h, _ := svc.CreateHuman(ctx, org.ID, "jacinta")
	_, pub, _ := casket.DeriveAgentKey([]byte(grantTestSeed), "anvil")
	a, _ := svc.CreateAgent(ctx, org.ID, "anvil", h.ID, pub)
	wrongPriv, _, _ := casket.DeriveAgentKey([]byte(grantTestSeed), "imposter")
	assertion := signAssertion(t, a.ID, p.IdentityURL(), wrongPriv, time.Now().Add(2*time.Minute))
	resp, _ := postIdentity(t, srv.URL+"/agent/identity", assertion, "ledger")
	if resp.StatusCode == 200 {
		t.Fatal("assertion signed by the wrong key must be rejected")
	}
}

func TestAgentIdentity_MissingAudience_Rejected(t *testing.T) {
	p, svc, srv, _ := testStackWithIdentity(t)
	ctx := context.Background()
	org, _ := svc.CreateOrg(ctx, "acme")
	h, _ := svc.CreateHuman(ctx, org.ID, "jacinta")
	priv, pub, _ := casket.DeriveAgentKey([]byte(grantTestSeed), "anvil")
	a, _ := svc.CreateAgent(ctx, org.ID, "anvil", h.ID, pub)
	assertion := signAssertion(t, a.ID, p.IdentityURL(), priv, time.Now().Add(2*time.Minute))
	resp, _ := postIdentity(t, srv.URL+"/agent/identity", assertion, "")
	if resp.StatusCode != 400 {
		t.Fatalf("missing audience must be a 400, got %d", resp.StatusCode)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/oidc/ -run TestAgentIdentity -v`
Expected: FAIL — `p.SetIdentityHandler` / `ag.ServeIdentity` undefined (compile error). (`SetIdentityHandler` is added in Task 6; this task adds `ServeIdentity` + the mint. To keep the task compiling on its own, add `SetIdentityHandler` here as Step 6 and the discovery/route wiring in Task 6 — see note.)

> **Build-order note:** `ServeIdentity` (this task) and `SetIdentityHandler`/route (Task 6) are mutually dependent for the test to compile. Implement `SetIdentityHandler` + `handleIdentity` + the route mount as Step 6 below so this task is self-contained; Task 6 then only adds the discovery `agent_auth` block.

- [ ] **Step 3: Extract `verifyAssertion` from `issue`**

In `internal/oidc/agent_grant.go`, replace `issue` with a thin wrapper over a new `verifyAssertion`. Replace the current `issue` (steps 1–6 inside it) with:

```go
// verifyAssertion validates an agent's casket-signed jwt-bearer assertion
// against the registered key + block cascade and returns the agent record.
// wantAud is the canonical endpoint URL the assertion's `aud` must match
// (issuer+"/token" for the token endpoint, issuer+"/agent/identity" for the
// identity endpoint) — never r.Host, so it is proxy-safe.
func (g *AgentGrant) verifyAssertion(ctx context.Context, assertion, wantAud string) (store.User, error) {
	jws, err := jose.ParseSigned(assertion, []jose.SignatureAlgorithm{jose.EdDSA})
	if err != nil {
		return store.User{}, fmt.Errorf("parse assertion: %w", err)
	}
	var unverified assertionClaims
	if err := json.Unmarshal(jws.UnsafePayloadWithoutVerification(), &unverified); err != nil {
		return store.User{}, fmt.Errorf("assertion claims: %w", err)
	}
	if unverified.Subject == "" || unverified.Issuer != unverified.Subject {
		return store.User{}, errors.New("assertion iss must equal sub (the agent id)")
	}
	agent, err := g.id.GetUser(ctx, unverified.Subject)
	if err != nil {
		return store.User{}, fmt.Errorf("unknown agent: %w", err)
	}
	if agent.Kind != store.KindAgent || len(agent.CasketPubkey) != ed25519.PublicKeySize {
		return store.User{}, errors.New("subject is not a key-registered agent")
	}
	verified, err := jws.Verify(ed25519.PublicKey(agent.CasketPubkey))
	if err != nil {
		return store.User{}, fmt.Errorf("assertion signature: %w", err)
	}
	var claims assertionClaims
	if err := json.Unmarshal(verified, &claims); err != nil {
		return store.User{}, fmt.Errorf("verified claims: %w", err)
	}
	if !claims.audienceMatches(wantAud) {
		return store.User{}, errors.New("assertion audience mismatch")
	}
	if claims.Expiry == 0 || g.p.Now().After(time.Unix(claims.Expiry, 0)) {
		return store.User{}, errors.New("assertion expired or missing exp")
	}
	if !g.id.IsActive(ctx, agent.ID) {
		return store.User{}, errors.New("agent inactive (blocked, or responsible human/org blocked)")
	}
	return agent, nil
}

// issue verifies the assertion and returns a signed general access token (the
// jwt-bearer /token path). The handler maps any error to a uniform 401.
func (g *AgentGrant) issue(ctx context.Context, assertion, tokenURL string) (token, subject string, err error) {
	agent, err := g.verifyAssertion(ctx, assertion, tokenURL)
	if err != nil {
		return "", "", err
	}
	out, err := accessClaims(ctx, g.id, agent)
	if err != nil {
		return "", "", fmt.Errorf("claims: %w", err)
	}
	signed, err := g.p.SignToken(out)
	if err != nil {
		return "", "", err
	}
	return signed, agent.ID, nil
}
```

- [ ] **Step 4: Add the `idjagTTL` field + constructor default + setter**

Add to the `AgentGrant` struct:

```go
	idjagTTL time.Duration
```

Update `NewAgentGrant` to set the default (keep the signature unchanged so existing callers compile):

```go
func NewAgentGrant(p *Provider, id IdentityResolver, refresh *RefreshIssuer) *AgentGrant {
	return &AgentGrant{p: p, id: id, refresh: refresh, idjagTTL: 5 * time.Minute}
}
```

Add a setter (used by config / tests that want a different lifetime):

```go
// SetIDJAGTTL overrides the lifetime of minted ID-JAGs (default 5m).
func (g *AgentGrant) SetIDJAGTTL(d time.Duration) { g.idjagTTL = d }
```

- [ ] **Step 5: Add `idJAGType`, `randomJTI`, `mintIDJAG`, `ServeIdentity`**

Add the constant near `jwtBearerGrant`:

```go
// idJAGType is the auth.md / RFC 8693 identity-assertion grant token type.
const idJAGType = "urn:ietf:params:oauth:token-type:id-jag"
```

Add the imports `crypto/rand` and `encoding/base64` to the file's import block. Then add:

```go
// randomJTI returns a 128-bit base64url replay nonce.
func randomJTI() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b[:]), nil
}

// mintIDJAG builds an audience-scoped ID-JAG for the given agent. Claims come
// FROM THE RECORD (sub/org/act.sub/scope/products via accessClaims) plus the
// requested audience, a fresh jti, and client_id. Signed short-lived.
func (g *AgentGrant) mintIDJAG(ctx context.Context, agent store.User, audience string) (string, error) {
	out, err := accessClaims(ctx, g.id, agent)
	if err != nil {
		return "", fmt.Errorf("claims: %w", err)
	}
	jti, err := randomJTI()
	if err != nil {
		return "", fmt.Errorf("jti: %w", err)
	}
	out["aud"] = audience
	out["jti"] = jti
	out["client_id"] = agent.ID
	return g.p.SignShortLived(out, g.idjagTTL)
}

// ServeIdentity handles POST /agent/identity — the auth.md identity endpoint.
// For type=identity_assertion the agent presents a self-signed proof-of-
// possession assertion (aud = this endpoint) plus the target service
// `audience`; herald returns an audience-scoped ID-JAG.
func (g *AgentGrant) ServeIdentity(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		oauthError(w, http.StatusBadRequest, "invalid_request", "unparseable form")
		return
	}
	if r.Form.Get("type") != "identity_assertion" {
		oauthError(w, http.StatusBadRequest, "unsupported_identity_type", "only identity_assertion is supported")
		return
	}
	assertion := r.Form.Get("assertion")
	audience := r.Form.Get("audience")
	if assertion == "" || audience == "" {
		oauthError(w, http.StatusBadRequest, "invalid_request", "assertion and audience are required")
		return
	}
	agent, err := g.verifyAssertion(r.Context(), assertion, g.p.IdentityURL())
	if err != nil {
		// Uniform 401 — don't leak which check failed.
		oauthError(w, http.StatusUnauthorized, "invalid_grant", "assertion rejected")
		return
	}
	idjag, err := g.mintIDJAG(r.Context(), agent, audience)
	if err != nil {
		oauthError(w, http.StatusInternalServerError, "server_error", "mint failed")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"access_token":      idjag,
		"issued_token_type": idJAGType,
		"token_type":        "N_A",
		"expires_in":        int(g.idjagTTL.Seconds()),
	})
}
```

- [ ] **Step 6: Add `SetIdentityHandler` + `handleIdentity` + route (provider side)**

In `internal/oidc/provider.go`, add an `identityEP http.Handler` field to the `Provider` struct (near `tokenEP`/`revokeEP`/`authorizeEP`), a setter, and mount the route. Add the setter next to `SetTokenHandler`:

```go
// SetIdentityHandler wires the agent-identity endpoint (POST /agent/identity).
func (p *Provider) SetIdentityHandler(h http.Handler) { p.identityEP = h }
```

In `Handler()`, add the route (after the `/token` line):

```go
	mux.HandleFunc("POST /agent/identity", p.handleIdentity)
```

Add the handler next to `handleToken`:

```go
func (p *Provider) handleIdentity(w http.ResponseWriter, r *http.Request) {
	if p.identityEP == nil {
		http.Error(w, `{"error":"identity endpoint not configured"}`, http.StatusNotImplemented)
		return
	}
	p.identityEP.ServeHTTP(w, r)
}
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `go test ./internal/oidc/ -run TestAgentIdentity -v`
Expected: all three PASS.

Run: `go test ./internal/oidc/ -v`
Expected: all PASS (the `issue`/`verifyAssertion` refactor keeps the existing `/token` tests green, including `TestAgentGrant_AudienceFromIssuer_WorksBehindProxy`).

- [ ] **Step 8: Commit**

```bash
git add internal/oidc/agent_grant.go internal/oidc/provider.go internal/oidc/agent_grant_test.go
git commit -m "oidc: ID-JAG mint via /agent/identity (audience-scoped, act.sub)"
```

---

## Task 6: discovery — `agent_auth` block + `oauth-authorization-server` route

**Files:**
- Modify: `internal/oidc/provider.go` (`handleDiscovery`, `Handler`)
- Test: `internal/oidc/oidc_test.go`

- [ ] **Step 1: Write the failing test**

Add to `internal/oidc/oidc_test.go`:

```go
func TestProvider_Discovery_AgentAuthBlock(t *testing.T) {
	p := newTestProvider(t)
	srv := httptest.NewServer(p.Handler())
	defer srv.Close()

	// auth.md discovers via /.well-known/oauth-authorization-server (RFC 8414).
	resp, err := http.Get(srv.URL + "/.well-known/oauth-authorization-server")
	if err != nil || resp.StatusCode != 200 {
		t.Fatalf("oauth-authorization-server: %v status=%d", err, resp.StatusCode)
	}
	defer resp.Body.Close()
	var d map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&d); err != nil {
		t.Fatalf("decode: %v", err)
	}
	aa, ok := d["agent_auth"].(map[string]any)
	if !ok {
		t.Fatalf("discovery missing agent_auth block: %+v", d)
	}
	if aa["identity_endpoint"] != "https://herald.test/agent/identity" {
		t.Fatalf("identity_endpoint = %v", aa["identity_endpoint"])
	}
	types, _ := aa["identity_types_supported"].([]any)
	if len(types) == 0 || types[0] != "identity_assertion" {
		t.Fatalf("identity_types_supported = %v", aa["identity_types_supported"])
	}
	ia, _ := aa["identity_assertion"].(map[string]any)
	at, _ := ia["assertion_types_supported"].([]any)
	if len(at) == 0 || at[0] != "urn:ietf:params:oauth:token-type:id-jag" {
		t.Fatalf("assertion_types_supported = %v", ia["assertion_types_supported"])
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/oidc/ -run TestProvider_Discovery_AgentAuthBlock -v`
Expected: FAIL — `/.well-known/oauth-authorization-server` 404 / no `agent_auth` block.

- [ ] **Step 3: Add the `agent_auth` block to `handleDiscovery`**

In `internal/oidc/provider.go`, inside `handleDiscovery`, add an entry to the returned map (alongside `subject_types_supported`):

```go
		"agent_auth": map[string]any{
			"identity_endpoint":        base + "/agent/identity",
			"events_endpoint":          base + "/agent/events",
			"identity_types_supported": []string{"identity_assertion"},
			"identity_assertion": map[string]any{
				"assertion_types_supported": []string{idJAGType},
			},
		},
```

(`idJAGType` is defined in `agent_grant.go`, same package.)

- [ ] **Step 4: Mount the RFC 8414 discovery route**

In `Handler()`, add (next to the `openid-configuration` line):

```go
	mux.HandleFunc("GET /.well-known/oauth-authorization-server", p.handleDiscovery)
```

(Reuses the same handler — herald advertises the agent_auth block on both the OIDC and the OAuth-AS discovery documents.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `go test ./internal/oidc/ -run TestProvider_Discovery -v`
Expected: `TestProvider_Discovery` (existing) and `TestProvider_Discovery_AgentAuthBlock` both PASS.

Run: `go test ./internal/oidc/ -v`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add internal/oidc/provider.go internal/oidc/oidc_test.go
git commit -m "oidc: advertise agent_auth block on RFC 8414 + OIDC discovery"
```

---

## Task 7: wire the identity endpoint in `cmd/herald/main.go`

**Files:**
- Modify: `cmd/herald/main.go`

> **Verify first:** open `cmd/herald/main.go` and find where the provider + agent grant are constructed (the existing `provider.SetTokenHandler(oidc.NewAgentGrant(...))` call). The exact variable names below (`provider`, `agentGrant`) may differ — match what's there. The agent grant is currently likely passed inline to `SetTokenHandler`; refactor to a named variable so the same instance is shared with `SetIdentityHandler`.

- [ ] **Step 1: Hold the agent grant in a variable + wire both endpoints**

Locate the existing wiring, e.g.:

```go
	provider.SetTokenHandler(oidc.NewAgentGrant(provider, idSvc, refreshIssuer))
```

Replace with:

```go
	agentGrant := oidc.NewAgentGrant(provider, idSvc, refreshIssuer)
	provider.SetTokenHandler(agentGrant)
	provider.SetIdentityHandler(http.HandlerFunc(agentGrant.ServeIdentity))
```

Ensure `net/http` is imported in `main.go` (it almost certainly already is).

- [ ] **Step 2: Build to verify it compiles**

Run: `go build ./...`
Expected: success, no errors.

- [ ] **Step 3: Run the full module test suite**

Run: `go test ./...`
Expected: all PASS.

- [ ] **Step 4: Commit**

```bash
git add cmd/herald/main.go
git commit -m "herald: serve /agent/identity (ID-JAG mint)"
```

---

## Task 8: end-to-end — mint via `/agent/identity`, verify via heraldauth

**Files:**
- Create: `heraldauth/idjag_e2e_test.go`

This is the integration test the spec calls for: an agent mints an ID-JAG against a *real* herald and a real `heraldauth.Verifier` accepts it with the matching audience, surfaces `responsible_human`, rejects a wrong audience, and rejects a replay.

- [ ] **Step 1: Write the failing test**

Create `heraldauth/idjag_e2e_test.go`:

```go
package heraldauth_test

import (
	"context"
	"crypto/ed25519"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"net/http/httptest"
	"testing"
	"time"

	casket "github.com/CarriedWorldUniverse/casket-go"
	jose "github.com/go-jose/go-jose/v4"

	"github.com/CarriedWorldUniverse/herald/heraldauth"
	"github.com/CarriedWorldUniverse/herald/internal/identity"
	herald "github.com/CarriedWorldUniverse/herald/internal/oidc"
	"github.com/CarriedWorldUniverse/herald/internal/store"
)

// liveHeraldIDJAG spins a real herald, registers an agent, and mints an ID-JAG
// scoped to `audience` via the real /agent/identity endpoint.
func liveHeraldIDJAG(t *testing.T, audience string) (issuer, idjag, agentID, humanID string) {
	t.Helper()
	s, err := store.Open(":memory:")
	if err != nil {
		t.Fatalf("store.Open: %v", err)
	}
	t.Cleanup(func() { _ = s.Close() })
	svc := identity.New(s)
	ctx := context.Background()
	org, _ := svc.CreateOrg(ctx, "acme")
	h, _ := svc.CreateHuman(ctx, org.ID, "jacinta")
	slug := fmt.Sprintf("anvil-%d", liveHeraldSeq.Add(1))
	priv, pub, _ := casket.DeriveAgentKey([]byte("owner-seed-32-bytes-padded-xxxxx"), slug)
	a, err := svc.CreateAgent(ctx, org.ID, slug, h.ID, pub)
	if err != nil {
		t.Fatalf("CreateAgent: %v", err)
	}
	_ = svc.GrantScope(ctx, a.ID, "repo:write", h.ID)

	_, signKey, _ := ed25519.GenerateKey(nil)
	srv := httptest.NewServer(nil)
	t.Cleanup(srv.Close)
	p, _ := herald.NewProvider(herald.Config{Issuer: srv.URL + "/", SigningKey: signKey})
	ag := herald.NewAgentGrant(p, svc, nil)
	p.SetTokenHandler(ag)
	p.SetIdentityHandler(http.HandlerFunc(ag.ServeIdentity))
	srv.Config.Handler = p.Handler()

	// Agent self-signs a proof-of-possession assertion (aud = identity endpoint).
	signer, _ := jose.NewSigner(jose.SigningKey{Algorithm: jose.EdDSA, Key: priv},
		(&jose.SignerOptions{}).WithType("JWT"))
	payload, _ := json.Marshal(map[string]any{
		"iss": a.ID, "sub": a.ID, "aud": p.IdentityURL(),
		"iat": time.Now().Unix(), "exp": time.Now().Add(2 * time.Minute).Unix(),
	})
	obj, _ := signer.Sign(payload)
	assertion, _ := obj.CompactSerialize()

	resp, _ := http.PostForm(srv.URL+"/agent/identity", url.Values{
		"type":      {"identity_assertion"},
		"assertion": {assertion},
		"audience":  {audience},
	})
	var body map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&body)
	resp.Body.Close()
	tok, _ := body["access_token"].(string)
	if tok == "" {
		t.Fatalf("failed to mint id-jag: %+v", body)
	}
	return srv.URL + "/", tok, a.ID, h.ID
}

func TestIDJAG_E2E_MatchingAudience_Accepted(t *testing.T) {
	ctx := context.Background()
	issuer, idjag, agentID, humanID := liveHeraldIDJAG(t, "ledger")
	v, err := heraldauth.New(ctx, heraldauth.Config{Issuer: issuer, Audience: "ledger"})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	id, err := v.Verify(ctx, idjag)
	if err != nil {
		t.Fatalf("Verify: %v", err)
	}
	if id.Subject != agentID {
		t.Fatalf("subject = %q, want %q", id.Subject, agentID)
	}
	if id.ResponsibleHuman != humanID {
		t.Fatalf("responsible human = %q, want %q", id.ResponsibleHuman, humanID)
	}
}

func TestIDJAG_E2E_WrongAudience_Rejected(t *testing.T) {
	ctx := context.Background()
	issuer, idjag, _, _ := liveHeraldIDJAG(t, "ledger")
	v, _ := heraldauth.New(ctx, heraldauth.Config{Issuer: issuer, Audience: "cairn"})
	if _, err := v.Verify(ctx, idjag); err == nil {
		t.Fatal("an ID-JAG scoped to ledger must be rejected by a cairn verifier")
	}
}

func TestIDJAG_E2E_Replay_Rejected(t *testing.T) {
	ctx := context.Background()
	issuer, idjag, _, _ := liveHeraldIDJAG(t, "ledger")
	v, _ := heraldauth.New(ctx, heraldauth.Config{Issuer: issuer, Audience: "ledger"})
	if _, err := v.Verify(ctx, idjag); err != nil {
		t.Fatalf("first use: %v", err)
	}
	if _, err := v.Verify(ctx, idjag); err == nil {
		t.Fatal("re-presenting the same ID-JAG (same jti) must be rejected as replay")
	}
}
```

- [ ] **Step 2: Run test to verify it fails (then passes)**

Run: `go test ./heraldauth/ -run TestIDJAG_E2E -v`
Expected: PASS (Tasks 1–6 already implement both ends). If it fails, the failure pinpoints the integration gap — fix in the relevant earlier file, not here.

> This task is mostly a guard: if Tasks 1–6 are correct it passes immediately. Treat a failure as a signal to revisit the mint (Task 5) or verify (Tasks 1–2) code.

- [ ] **Step 3: Commit**

```bash
git add heraldauth/idjag_e2e_test.go
git commit -m "heraldauth: end-to-end ID-JAG mint+verify integration test"
```

---

## Task 9: conformance — discovery shape assertion (herald-side) + cwb-conformance follow-up

**Files:**
- Modify: `internal/oidc/oidc_test.go` (a focused conformance assertion)
- Follow-up (separate repo, not this plan): `cwb-conformance`

- [ ] **Step 1: Write the conformance assertion test**

The spec's conformance requirement is that the discovery block + token type validate against the auth.md/ID-JAG shape. Add a single assertion test that locks the wire shape so federation interop holds when enabled. Add to `internal/oidc/oidc_test.go`:

```go
func TestProvider_AgentAuth_ConformanceShape(t *testing.T) {
	p := newTestProvider(t)
	srv := httptest.NewServer(p.Handler())
	defer srv.Close()
	resp, _ := http.Get(srv.URL + "/.well-known/oauth-authorization-server")
	defer resp.Body.Close()
	var d map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&d)

	// Required top-level fields for an auth.md authorization server.
	for _, k := range []string{"issuer", "token_endpoint", "jwks_uri", "agent_auth"} {
		if _, ok := d[k]; !ok {
			t.Fatalf("conformance: missing %q in discovery", k)
		}
	}
	// jwt-bearer grant must be advertised (the exchange grant).
	grants := toStringSlice(d["grant_types_supported"])
	hasJWTBearer := false
	for _, g := range grants {
		if g == "urn:ietf:params:oauth:grant-type:jwt-bearer" {
			hasJWTBearer = true
		}
	}
	if !hasJWTBearer {
		t.Fatalf("conformance: grant_types_supported must include jwt-bearer, got %v", grants)
	}
	aa := d["agent_auth"].(map[string]any)
	ia := aa["identity_assertion"].(map[string]any)
	at := toStringSlice(ia["assertion_types_supported"])
	if len(at) != 1 || at[0] != "urn:ietf:params:oauth:token-type:id-jag" {
		t.Fatalf("conformance: assertion_types_supported must be [id-jag], got %v", at)
	}
}
```

(`toStringSlice` already exists in `agent_grant_test.go`, same `oidc_test` package.)

- [ ] **Step 2: Run test to verify it passes**

Run: `go test ./internal/oidc/ -run TestProvider_AgentAuth_ConformanceShape -v`
Expected: PASS.

- [ ] **Step 3: Run the entire module suite one final time**

Run: `go test ./...`
Expected: all PASS.

Run: `go vet ./...`
Expected: clean (watch for lock-copy on any by-value struct — there are none introduced here).

- [ ] **Step 4: Commit**

```bash
git add internal/oidc/oidc_test.go
git commit -m "oidc: conformance assertion for the agent_auth discovery shape"
```

- [ ] **Step 5: File the cwb-conformance follow-up (separate ticket/PR, not this plan)**

The cross-repo `cwb-conformance` suite should gain a live check that hits a deployed herald's `/.well-known/oauth-authorization-server`, asserts the `agent_auth` block + `id-jag` assertion type, mints an ID-JAG against a test agent, and verifies it through `heraldauth` with a matching audience (and rejects a wrong one). This lands as its own PR in `cwb-conformance` referencing this plan — it is **not** part of the herald PR.

---

## Self-review

**Spec coverage:**
- §Components 1 (discovery `agent_auth` block + protected-resource) → Tasks 6 + 3. ✓
- §Components 2 (ID-JAG mint, audience-scoped, `token_type` id-jag, claim set incl. `act.sub`, via `/agent/identity` extending `agent_grant`) → Task 5. ✓
- §Components 3 (service-side verify: JWKS already; `iss` already; `aud`, `exp` already, `jti` replay) → Tasks 1 + 2; ID-JAG-as-bearer short-circuit (no exchange) is exactly what Task 8 verifies. ✓
- §Components 4 (trusted issuers — internal: herald trusts itself) → inherent: `heraldauth.Config.Issuer` is the single trusted issuer; `RegisterIssuer`/federation stays dormant, no task needed (correct for internal-first MVP). ✓
- §Components 5 (`responsible_human`/`act.sub` in every ID-JAG) → reused via `accessClaims`; asserted in Task 5 + Task 8. ✓
- §Components 6 (revocation = short exp) → `idjagTTL` default 5m (Task 5). The `events_endpoint` is advertised in discovery (Task 6) but dormant — matches "events surface comes with federation." ✓
- §Flows internal MVP → Task 8 is exactly that flow end-to-end. ✓
- §Scope "ID-JAG presented directly as the bearer (short-circuit — no second token)" → no token-exchange task; Task 8 verifies the ID-JAG directly. The RFC-7523 jwt-bearer two-step is explicitly deferred (already exists at `/token` for the general-token path; not extended for federation here). ✓
- §Testing unit/integration/conformance → Tasks 5/1/2 (unit), Task 8 (integration), Task 9 (conformance). ✓

**Out-of-scope correctly omitted:** inbound external-IdP onboarding, outbound-to-foreign-service, revocation events surface, human-readable skill manifest — all dormant; no tasks. ✓

**Placeholder scan:** no TBD/TODO; every code step shows complete code; commands have expected output. ✓

**Type consistency:** `idJAGType` constant defined once in `agent_grant.go`, referenced in `provider.go` discovery (same package) — ✓. `heraldauth` uses the literal string in tests (separate module) — ✓. `verifyAssertion` returns `store.User`, consumed by `issue` + `mintIDJAG` + `ServeIdentity` — ✓. `SignShortLived(claims, ttl)`/`signClaims(claims, ttl)` signatures consistent — ✓. `Config.Audience` (Task 1) → `v.audience` (Task 1) → enforced (Task 1) and used by tests in Tasks 1/8 — ✓. `markJTI(jti, exp)` (Task 2) matches its call site — ✓. `SetIdentityHandler` (Task 5 Step 6) ↔ `handleIdentity` ↔ route, used in Task 7 + tests — ✓.

**Build-order note honored:** Task 5 includes the provider-side `SetIdentityHandler`/`handleIdentity`/route so its own tests compile; Task 6 only adds the discovery block; Task 7 wires `main.go`.

---

## Relates

- Spec: `carriedworld-cloud/docs/2026-06-14-herald-idjag-agent-auth-design.md`
- Memory: `project_authmd_herald_agent_auth`, `project_herald_rooted_agent_bootstrap` (realized), `herald_admin_authz`
- Follow-ups (not this plan): cwb-conformance agent_auth check; federation seams (inbound onboarding / outbound); lynxai / auth-as-a-human (separate, non-cooperative outbound).
