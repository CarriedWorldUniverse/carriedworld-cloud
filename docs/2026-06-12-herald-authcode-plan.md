# Herald Authorization-Code Flow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the OAuth2 authorization-code flow (+PKCE, herald-hosted login page, env-registered clients) to herald, so browser apps (first consumer: atlas) log humans in with redirect-based OIDC instead of ROPC.

**Architecture:** Everything lands in herald's existing `internal/oidc` package, following its established seams: a `ClientRegistry` (env-configured, public clients, PKCE-required), an in-memory single-use `CodeStore`, a `GET/POST /authorize` handler that renders a herald-hosted login form and mints codes, and a `CodeGrant` wired into the existing `GrantMux` as a fourth grant type. Auth codes are 60s ephemeral — in-memory is correct (herald is single-replica; a restart aborts pending logins, the user just retries). Tokens issued are the same EdDSA access+refresh tokens every other grant issues — zero changes to token format or verification.

**Tech Stack:** Go, go-jose/v4 (already herald's), stdlib `net/http` + `html/template`. No new dependencies.

**Repo:** `/home/operator/src/herald` (work on a branch: `feat/oidc-authorization-code`)

**Worth knowing before you start:**
- Herald's OIDC core is deliberately NOT a full IdP library — narrow, hand-rolled on go-jose (`internal/oidc/provider.go:1-9` explains why). Follow that taste: no new frameworks.
- `Provider.Handler()` (`internal/oidc/provider.go:178`) is the HTTP mux for OIDC routes; `cmd/herald/main.go:95-99` mounts it per-path. New routes get added in both places.
- `GrantMux` (`internal/oidc/grantmux.go`) dispatches POST /token by `grant_type`. The new grant is one more case.
- Humans verify via `HumanResolver.VerifyHumanPassword(ctx, userID, plaintext) (store.User, error)` — username IS the user id (genesis logs "login username = id ...").
- Claims for a user come from `accessClaims(ctx, resolver, user)` (`internal/oidc/claims.go`) — the code grant reuses it, identical to `human_grant.go:57`.
- `oauthError(w, status, code, desc)` is the package's error helper — use it.
- Run tests: `cd /home/operator/src/herald && go test ./...`

---

### Task A1: Client registry (env-configured public clients)

**Files:**
- Create: `internal/oidc/clients.go`
- Test: `internal/oidc/clients_test.go`

OIDC clients are deployment config, not runtime data: a `HERALD_OIDC_CLIENTS` env var, format `clientID|redirectURI[,clientID|redirectURI...]` (one redirect URI per client — YAGNI; add more when a client needs them). Public clients only (PKCE replaces the secret).

- [ ] **Step 1: Write the failing test**

```go
package oidc

import "testing"

func TestParseClients(t *testing.T) {
	tests := []struct {
		name    string
		in      string
		wantErr bool
		check   func(t *testing.T, r *ClientRegistry)
	}{
		{name: "empty yields empty registry", in: "", check: func(t *testing.T, r *ClientRegistry) {
			if _, ok := r.Lookup("atlas"); ok {
				t.Fatal("empty registry should have no clients")
			}
		}},
		{name: "single client", in: "atlas|https://atlas.tail41686e.ts.net/oauth/callback", check: func(t *testing.T, r *ClientRegistry) {
			c, ok := r.Lookup("atlas")
			if !ok || c.RedirectURI != "https://atlas.tail41686e.ts.net/oauth/callback" {
				t.Fatalf("got %+v ok=%v", c, ok)
			}
		}},
		{name: "two clients", in: "atlas|https://a/cb,other|https://b/cb", check: func(t *testing.T, r *ClientRegistry) {
			if _, ok := r.Lookup("other"); !ok {
				t.Fatal("missing second client")
			}
		}},
		{name: "malformed entry", in: "atlas-no-pipe", wantErr: true},
		{name: "non-https redirect rejected", in: "atlas|http://evil/cb", wantErr: true},
		{name: "localhost http allowed for dev", in: "dev|http://localhost:8443/cb", check: func(t *testing.T, r *ClientRegistry) {
			if _, ok := r.Lookup("dev"); !ok {
				t.Fatal("localhost http should be allowed")
			}
		}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r, err := ParseClients(tt.in)
			if tt.wantErr {
				if err == nil {
					t.Fatal("want error")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			tt.check(t, r)
		})
	}
}

func TestValidateRedirect(t *testing.T) {
	r, _ := ParseClients("atlas|https://a/cb")
	if err := r.ValidateRedirect("atlas", "https://a/cb"); err != nil {
		t.Fatalf("exact match should pass: %v", err)
	}
	if err := r.ValidateRedirect("atlas", "https://a/cb?extra=1"); err == nil {
		t.Fatal("non-exact redirect must be rejected")
	}
	if err := r.ValidateRedirect("ghost", "https://a/cb"); err == nil {
		t.Fatal("unknown client must be rejected")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/oidc/ -run 'TestParseClients|TestValidateRedirect' -v`
Expected: FAIL — `undefined: ParseClients`

- [ ] **Step 3: Implement**

```go
package oidc

import (
	"fmt"
	"net/url"
	"strings"
)

// Client is one registered OAuth2 client. All herald clients are PUBLIC
// (browser apps): PKCE is the proof-of-possession, there is no client secret.
type Client struct {
	ID          string
	RedirectURI string
}

// ClientRegistry holds the statically-registered OAuth2 clients. Clients are
// deployment config (HERALD_OIDC_CLIENTS), not runtime data — registering a
// client IS a deploy, which matches the platform's declarations-are-truth
// posture.
type ClientRegistry struct {
	clients map[string]Client
}

// ParseClients parses "id|redirectURI[,id|redirectURI...]" into a registry.
// Redirect URIs must be https, except localhost (dev). Empty input is a valid
// empty registry (the authorize endpoint then rejects everything).
func ParseClients(s string) (*ClientRegistry, error) {
	r := &ClientRegistry{clients: map[string]Client{}}
	if strings.TrimSpace(s) == "" {
		return r, nil
	}
	for _, entry := range strings.Split(s, ",") {
		id, redirect, ok := strings.Cut(strings.TrimSpace(entry), "|")
		if !ok || id == "" || redirect == "" {
			return nil, fmt.Errorf("oidc: malformed client entry %q (want id|redirectURI)", entry)
		}
		u, err := url.Parse(redirect)
		if err != nil {
			return nil, fmt.Errorf("oidc: client %s: bad redirect %q: %w", id, redirect, err)
		}
		if u.Scheme != "https" && u.Hostname() != "localhost" {
			return nil, fmt.Errorf("oidc: client %s: redirect must be https (or localhost for dev), got %q", id, redirect)
		}
		r.clients[id] = Client{ID: id, RedirectURI: redirect}
	}
	return r, nil
}

// Lookup returns the client by id.
func (r *ClientRegistry) Lookup(id string) (Client, bool) {
	c, ok := r.clients[id]
	return c, ok
}

// ValidateRedirect requires an EXACT redirect-URI match (no prefix logic —
// exact match is the only safe comparison for redirect URIs).
func (r *ClientRegistry) ValidateRedirect(clientID, redirect string) error {
	c, ok := r.clients[clientID]
	if !ok {
		return fmt.Errorf("oidc: unknown client %q", clientID)
	}
	if c.RedirectURI != redirect {
		return fmt.Errorf("oidc: redirect %q not registered for client %q", redirect, clientID)
	}
	return nil
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/oidc/ -run 'TestParseClients|TestValidateRedirect' -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add internal/oidc/clients.go internal/oidc/clients_test.go
git commit -m "feat(oidc): env-configured client registry for the auth-code flow"
```

---

### Task A2: Auth-code store (in-memory, single-use, TTL) + PKCE

**Files:**
- Create: `internal/oidc/authcode.go`
- Test: `internal/oidc/authcode_test.go`

- [ ] **Step 1: Write the failing test**

```go
package oidc

import (
	"crypto/sha256"
	"encoding/base64"
	"testing"
	"time"
)

func TestCodeStoreIssueRedeem(t *testing.T) {
	now := time.Now()
	cs := NewCodeStore(func() time.Time { return now })
	code := cs.Issue(PendingAuth{ClientID: "atlas", RedirectURI: "https://a/cb", UserID: "u1", CodeChallenge: "ch"})
	if code == "" {
		t.Fatal("empty code")
	}
	pa, ok := cs.Redeem(code)
	if !ok || pa.UserID != "u1" || pa.ClientID != "atlas" {
		t.Fatalf("redeem: %+v ok=%v", pa, ok)
	}
	if _, ok := cs.Redeem(code); ok {
		t.Fatal("code must be single-use")
	}
}

func TestCodeStoreExpiry(t *testing.T) {
	now := time.Now()
	cs := NewCodeStore(func() time.Time { return now })
	code := cs.Issue(PendingAuth{UserID: "u1"})
	now = now.Add(61 * time.Second)
	if _, ok := cs.Redeem(code); ok {
		t.Fatal("expired code must not redeem")
	}
}

func TestVerifyPKCE(t *testing.T) {
	verifier := "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
	sum := sha256.Sum256([]byte(verifier))
	challenge := base64.RawURLEncoding.EncodeToString(sum[:])
	if !VerifyPKCE(challenge, verifier) {
		t.Fatal("valid S256 verifier rejected")
	}
	if VerifyPKCE(challenge, "wrong-verifier") {
		t.Fatal("wrong verifier accepted")
	}
	if VerifyPKCE("", "anything") {
		t.Fatal("empty challenge must never verify")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/oidc/ -run 'TestCodeStore|TestVerifyPKCE' -v`
Expected: FAIL — `undefined: NewCodeStore`

- [ ] **Step 3: Implement**

```go
package oidc

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"sync"
	"time"
)

// codeTTL bounds how long an authorization code is redeemable. 60s is
// generous for one redirect hop.
const codeTTL = 60 * time.Second

// PendingAuth is what an authorization code stands for: the validated
// authorize request plus the authenticated user, waiting for the token
// exchange.
type PendingAuth struct {
	ClientID      string
	RedirectURI   string
	UserID        string
	CodeChallenge string // PKCE S256 challenge, required
	expires       time.Time
}

// CodeStore holds pending authorization codes in memory. Codes are 60s,
// single-use, and herald is single-replica — losing them on restart only
// aborts in-flight logins (the user retries), so no persistence by design.
type CodeStore struct {
	mu    sync.Mutex
	codes map[string]PendingAuth
	now   func() time.Time
}

// NewCodeStore builds a CodeStore; now is injectable for tests (nil = time.Now).
func NewCodeStore(now func() time.Time) *CodeStore {
	if now == nil {
		now = time.Now
	}
	return &CodeStore{codes: map[string]PendingAuth{}, now: now}
}

// Issue mints a single-use code for the pending auth.
func (s *CodeStore) Issue(pa PendingAuth) string {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		panic("oidc: crypto/rand failed: " + err.Error()) // unreachable in practice
	}
	code := base64.RawURLEncoding.EncodeToString(b)
	pa.expires = s.now().Add(codeTTL)
	s.mu.Lock()
	defer s.mu.Unlock()
	// Opportunistic sweep: the map only ever holds in-flight logins, so a
	// linear sweep on issue keeps it bounded without a background goroutine.
	for k, v := range s.codes {
		if s.now().After(v.expires) {
			delete(s.codes, k)
		}
	}
	s.codes[code] = pa
	return code
}

// Redeem returns and deletes the pending auth for code. Expired or unknown
// codes return ok=false.
func (s *CodeStore) Redeem(code string) (PendingAuth, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	pa, ok := s.codes[code]
	if !ok {
		return PendingAuth{}, false
	}
	delete(s.codes, code) // single-use regardless of expiry outcome
	if s.now().After(pa.expires) {
		return PendingAuth{}, false
	}
	return pa, true
}

// VerifyPKCE checks an S256 code_verifier against the stored challenge
// (RFC 7636). Empty challenges never verify — PKCE is mandatory.
func VerifyPKCE(challenge, verifier string) bool {
	if challenge == "" || verifier == "" {
		return false
	}
	sum := sha256.Sum256([]byte(verifier))
	want := base64.RawURLEncoding.EncodeToString(sum[:])
	return subtle.ConstantTimeCompare([]byte(want), []byte(challenge)) == 1
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/oidc/ -run 'TestCodeStore|TestVerifyPKCE' -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add internal/oidc/authcode.go internal/oidc/authcode_test.go
git commit -m "feat(oidc): in-memory single-use auth-code store + mandatory S256 PKCE"
```

---

### Task A3: GET/POST /authorize — herald-hosted login

**Files:**
- Create: `internal/oidc/authorize.go`
- Create: `internal/oidc/login.html`
- Test: `internal/oidc/authorize_test.go`

GET renders the login form (carrying the OAuth params through hidden fields); POST verifies the password, mints a code, 302s back to the client. Invalid client/redirect NEVER redirects (that's an open-redirect) — it renders a 400. Bad credentials re-render the form with an error.

- [ ] **Step 1: Write the failing test**

```go
package oidc

import (
	"context"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"github.com/CarriedWorldUniverse/herald/internal/store"
)

// stubHumans satisfies HumanResolver for handler tests.
type stubHumans struct{ IdentityResolver }

func (stubHumans) VerifyHumanPassword(_ context.Context, userID, pw string) (store.User, error) {
	if userID == "u-good" && pw == "pw" {
		return store.User{ID: "u-good", Kind: store.KindHuman}, nil
	}
	return store.User{}, errStubBadLogin
}

var errStubBadLogin = errEnumStub("bad login")

type errEnumStub string

func (e errEnumStub) Error() string { return string(e) }

func newAuthorizeForTest(t *testing.T) *Authorize {
	t.Helper()
	clients, err := ParseClients("atlas|https://a/cb")
	if err != nil {
		t.Fatal(err)
	}
	return NewAuthorize(clients, NewCodeStore(nil), stubHumans{})
}

const authzQuery = "client_id=atlas&redirect_uri=https%3A%2F%2Fa%2Fcb&response_type=code&state=xyz&code_challenge=abc123&code_challenge_method=S256"

func TestAuthorizeGetRendersForm(t *testing.T) {
	a := newAuthorizeForTest(t)
	rec := httptest.NewRecorder()
	a.ServeHTTP(rec, httptest.NewRequest("GET", "/authorize?"+authzQuery, nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d body %s", rec.Code, rec.Body.String())
	}
	body := rec.Body.String()
	for _, want := range []string{`name="username"`, `name="password"`, `value="xyz"`, `value="abc123"`} {
		if !strings.Contains(body, want) {
			t.Errorf("form missing %s", want)
		}
	}
}

func TestAuthorizeGetRejectsBadClientWithoutRedirect(t *testing.T) {
	a := newAuthorizeForTest(t)
	for _, q := range []string{
		"client_id=ghost&redirect_uri=https%3A%2F%2Fa%2Fcb&response_type=code&code_challenge=c&code_challenge_method=S256",
		"client_id=atlas&redirect_uri=https%3A%2F%2Fevil%2Fcb&response_type=code&code_challenge=c&code_challenge_method=S256",
		"client_id=atlas&redirect_uri=https%3A%2F%2Fa%2Fcb&response_type=token&code_challenge=c&code_challenge_method=S256",
		"client_id=atlas&redirect_uri=https%3A%2F%2Fa%2Fcb&response_type=code", // missing PKCE
		"client_id=atlas&redirect_uri=https%3A%2F%2Fa%2Fcb&response_type=code&code_challenge=c&code_challenge_method=plain", // S256 only
	} {
		rec := httptest.NewRecorder()
		a.ServeHTTP(rec, httptest.NewRequest("GET", "/authorize?"+q, nil))
		if rec.Code != http.StatusBadRequest {
			t.Errorf("query %q: want 400, got %d", q, rec.Code)
		}
		if loc := rec.Header().Get("Location"); loc != "" {
			t.Errorf("query %q: must not redirect on validation failure, got Location %s", q, loc)
		}
	}
}

func TestAuthorizePostGoodLoginRedirectsWithCode(t *testing.T) {
	a := newAuthorizeForTest(t)
	form := url.Values{
		"client_id": {"atlas"}, "redirect_uri": {"https://a/cb"}, "response_type": {"code"},
		"state": {"xyz"}, "code_challenge": {"abc123"}, "code_challenge_method": {"S256"},
		"username": {"u-good"}, "password": {"pw"},
	}
	req := httptest.NewRequest("POST", "/authorize", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	rec := httptest.NewRecorder()
	a.ServeHTTP(rec, req)
	if rec.Code != http.StatusFound {
		t.Fatalf("status %d body %s", rec.Code, rec.Body.String())
	}
	loc, err := url.Parse(rec.Header().Get("Location"))
	if err != nil || loc.Host != "a" {
		t.Fatalf("bad Location %q", rec.Header().Get("Location"))
	}
	if loc.Query().Get("state") != "xyz" {
		t.Error("state not round-tripped")
	}
	code := loc.Query().Get("code")
	if code == "" {
		t.Fatal("no code in redirect")
	}
	pa, ok := a.codes.Redeem(code)
	if !ok || pa.UserID != "u-good" || pa.CodeChallenge != "abc123" {
		t.Fatalf("stored pending auth wrong: %+v ok=%v", pa, ok)
	}
}

func TestAuthorizePostBadLoginRerendersForm(t *testing.T) {
	a := newAuthorizeForTest(t)
	form := url.Values{
		"client_id": {"atlas"}, "redirect_uri": {"https://a/cb"}, "response_type": {"code"},
		"code_challenge": {"abc123"}, "code_challenge_method": {"S256"},
		"username": {"u-good"}, "password": {"WRONG"},
	}
	req := httptest.NewRequest("POST", "/authorize", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	rec := httptest.NewRecorder()
	a.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("want 401 re-render, got %d", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "login failed") {
		t.Error("error message missing from re-rendered form")
	}
	if loc := rec.Header().Get("Location"); loc != "" {
		t.Error("must not redirect on bad login")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/oidc/ -run TestAuthorize -v`
Expected: FAIL — `undefined: NewAuthorize`

Note: `IdentityResolver` is the existing interface embedded by `HumanResolver` (see `human_grant.go:19`); the stub embeds it nil — only `VerifyHumanPassword` is called by /authorize. If the compiler complains about unused embedding, check the actual `IdentityResolver` definition in `claims.go` and stub its methods minimally.

- [ ] **Step 3: Create the login template**

Create `internal/oidc/login.html` (herald-voiced, dependency-free, dark):

```html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>herald — sign in</title>
<style>
  body { background:#14161a; color:#e8e6e3; font:16px/1.5 system-ui, sans-serif;
         display:grid; place-items:center; min-height:100vh; margin:0; }
  form { background:#1c1f26; border:1px solid #2a2e37; border-radius:10px;
         padding:2rem 2.5rem; width:20rem; }
  h1 { font-size:1.1rem; margin:0 0 .25rem; }
  p.sub { color:#8a8f98; font-size:.85rem; margin:0 0 1.25rem; }
  label { display:block; font-size:.8rem; color:#8a8f98; margin:.75rem 0 .25rem; }
  input[type=text], input[type=password] {
    width:100%; box-sizing:border-box; background:#14161a; color:#e8e6e3;
    border:1px solid #2a2e37; border-radius:6px; padding:.5rem .6rem; font-size:1rem; }
  button { margin-top:1.25rem; width:100%; padding:.55rem; border:0; border-radius:6px;
           background:#4a7dcf; color:#fff; font-size:1rem; cursor:pointer; }
  .err { background:#3a2026; border:1px solid #5c2e36; color:#e8b4bc;
         border-radius:6px; padding:.5rem .6rem; font-size:.85rem; margin-bottom:.5rem; }
</style>
</head>
<body>
<form method="post" action="/authorize">
  <h1>herald</h1>
  <p class="sub">sign in to continue to {{.ClientID}}</p>
  {{if .Error}}<div class="err">{{.Error}}</div>{{end}}
  <label for="username">user id</label>
  <input type="text" id="username" name="username" autocomplete="username" autofocus required>
  <label for="password">password</label>
  <input type="password" id="password" name="password" autocomplete="current-password" required>
  <input type="hidden" name="client_id" value="{{.ClientID}}">
  <input type="hidden" name="redirect_uri" value="{{.RedirectURI}}">
  <input type="hidden" name="response_type" value="code">
  <input type="hidden" name="state" value="{{.State}}">
  <input type="hidden" name="code_challenge" value="{{.CodeChallenge}}">
  <input type="hidden" name="code_challenge_method" value="S256">
  <button type="submit">sign in</button>
</form>
</body>
</html>
```

- [ ] **Step 4: Implement the handler**

```go
package oidc

import (
	_ "embed"
	"html/template"
	"net/http"
	"net/url"
)

//go:embed login.html
var loginHTML string

var loginTmpl = template.Must(template.New("login").Parse(loginHTML))

// Authorize implements the OAuth2 authorization endpoint (RFC 6749 §3.1) with
// mandatory S256 PKCE: GET renders the herald-hosted login form; POST verifies
// the password and redirects back to the client with a single-use code.
type Authorize struct {
	clients *ClientRegistry
	codes   *CodeStore
	humans  HumanResolver
}

// NewAuthorize wires the authorization endpoint.
func NewAuthorize(clients *ClientRegistry, codes *CodeStore, humans HumanResolver) *Authorize {
	return &Authorize{clients: clients, codes: codes, humans: humans}
}

type loginPage struct {
	ClientID, RedirectURI, State, CodeChallenge, Error string
}

// validate checks the OAuth params shared by GET and POST. Failures return a
// human-readable message and MUST render 400 — never redirect: an unvalidated
// redirect_uri is an open redirect.
func (a *Authorize) validate(q url.Values) (loginPage, string) {
	p := loginPage{
		ClientID:      q.Get("client_id"),
		RedirectURI:   q.Get("redirect_uri"),
		State:         q.Get("state"),
		CodeChallenge: q.Get("code_challenge"),
	}
	if q.Get("response_type") != "code" {
		return p, "response_type must be 'code'"
	}
	if err := a.clients.ValidateRedirect(p.ClientID, p.RedirectURI); err != nil {
		return p, "unknown client or unregistered redirect_uri"
	}
	if p.CodeChallenge == "" || q.Get("code_challenge_method") != "S256" {
		return p, "PKCE required: code_challenge + code_challenge_method=S256"
	}
	return p, ""
}

func (a *Authorize) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		p, msg := a.validate(r.URL.Query())
		if msg != "" {
			http.Error(w, "invalid authorization request: "+msg, http.StatusBadRequest)
			return
		}
		a.render(w, http.StatusOK, p)
	case http.MethodPost:
		if err := r.ParseForm(); err != nil {
			http.Error(w, "unparseable form", http.StatusBadRequest)
			return
		}
		p, msg := a.validate(r.Form)
		if msg != "" {
			http.Error(w, "invalid authorization request: "+msg, http.StatusBadRequest)
			return
		}
		u, err := a.humans.VerifyHumanPassword(r.Context(), r.Form.Get("username"), r.Form.Get("password"))
		if err != nil {
			p.Error = "login failed — check your user id and password"
			a.render(w, http.StatusUnauthorized, p)
			return
		}
		code := a.codes.Issue(PendingAuth{
			ClientID: p.ClientID, RedirectURI: p.RedirectURI,
			UserID: u.ID, CodeChallenge: p.CodeChallenge,
		})
		redirect, _ := url.Parse(p.RedirectURI) // validated above
		q := redirect.Query()
		q.Set("code", code)
		if p.State != "" {
			q.Set("state", p.State)
		}
		redirect.RawQuery = q.Encode()
		http.Redirect(w, r, redirect.String(), http.StatusFound)
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func (a *Authorize) render(w http.ResponseWriter, status int, p loginPage) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = loginTmpl.Execute(w, p)
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `go test ./internal/oidc/ -run TestAuthorize -v`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add internal/oidc/authorize.go internal/oidc/login.html internal/oidc/authorize_test.go
git commit -m "feat(oidc): /authorize endpoint with herald-hosted login (mandatory PKCE, no open redirects)"
```

---

### Task A4: authorization_code grant in the token endpoint

**Files:**
- Create: `internal/oidc/code_grant.go`
- Modify: `internal/oidc/grantmux.go` (add the grant_type case)
- Test: `internal/oidc/code_grant_test.go`

Mirrors `human_grant.go`'s shape exactly: resolve user → `accessClaims` → `SignToken` → optional refresh. Look at `internal/oidc/human_grant.go:38-78` while writing — the response assembly must be identical.

- [ ] **Step 1: Write the failing test**

```go
package oidc

import (
	"crypto/sha256"
	"encoding/base64"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

// newCodeGrantForTest wires a CodeGrant against a real provider + stub humans.
// testProvider(t) is the existing helper used across this package's tests —
// if the name differs, find how human_grant_test.go constructs its Provider
// and IdentityResolver stubs and reuse that exact pattern, including how it
// resolves accessClaims (the resolver needs Org/scope lookups for "u-good").
func newCodeGrantForTest(t *testing.T) (*CodeGrant, *CodeStore) {
	t.Helper()
	p := testProvider(t)
	cs := NewCodeStore(nil)
	return NewCodeGrant(p, testIdentityResolver(t), cs, nil), cs
}

func postToken(t *testing.T, g *CodeGrant, form url.Values) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest("POST", "/token", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	rec := httptest.NewRecorder()
	g.ServeToken(rec, req)
	return rec
}

func TestCodeGrantHappyPath(t *testing.T) {
	g, cs := newCodeGrantForTest(t)
	verifier := "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
	sum := sha256.Sum256([]byte(verifier))
	challenge := base64.RawURLEncoding.EncodeToString(sum[:])
	code := cs.Issue(PendingAuth{ClientID: "atlas", RedirectURI: "https://a/cb", UserID: "u-good", CodeChallenge: challenge})

	rec := postToken(t, g, url.Values{
		"grant_type": {"authorization_code"}, "code": {code},
		"redirect_uri": {"https://a/cb"}, "client_id": {"atlas"},
		"code_verifier": {verifier},
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d: %s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "access_token") {
		t.Fatal("no access_token in response")
	}
}

func TestCodeGrantRejects(t *testing.T) {
	g, cs := newCodeGrantForTest(t)
	verifier := "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
	sum := sha256.Sum256([]byte(verifier))
	challenge := base64.RawURLEncoding.EncodeToString(sum[:])
	issue := func() string {
		return cs.Issue(PendingAuth{ClientID: "atlas", RedirectURI: "https://a/cb", UserID: "u-good", CodeChallenge: challenge})
	}
	base := func(code string) url.Values {
		return url.Values{
			"grant_type": {"authorization_code"}, "code": {code},
			"redirect_uri": {"https://a/cb"}, "client_id": {"atlas"},
			"code_verifier": {verifier},
		}
	}

	tests := []struct {
		name   string
		mutate func(url.Values) url.Values
	}{
		{"unknown code", func(f url.Values) url.Values { f.Set("code", "nope"); return f }},
		{"wrong verifier", func(f url.Values) url.Values { f.Set("code_verifier", "wrong"); return f }},
		{"wrong client_id", func(f url.Values) url.Values { f.Set("client_id", "ghost"); return f }},
		{"wrong redirect_uri", func(f url.Values) url.Values { f.Set("redirect_uri", "https://evil/cb"); return f }},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rec := postToken(t, g, tt.mutate(base(issue())))
			if rec.Code == http.StatusOK {
				t.Fatalf("%s: must be rejected, got 200", tt.name)
			}
		})
	}
	// replay: same code twice
	code := issue()
	if rec := postToken(t, g, base(code)); rec.Code != http.StatusOK {
		t.Fatalf("first redeem should pass: %d", rec.Code)
	}
	if rec := postToken(t, g, base(code)); rec.Code == http.StatusOK {
		t.Fatal("replayed code must be rejected")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/oidc/ -run TestCodeGrant -v`
Expected: FAIL — `undefined: NewCodeGrant` (and possibly `testProvider`/`testIdentityResolver` — adapt those two helper names to whatever `human_grant_test.go`/`agent_grant_test.go` actually use; the stubs must resolve user "u-good" through `accessClaims` without error)

- [ ] **Step 3: Implement**

```go
package oidc

import (
	"context"
	"log"
	"net/http"

	"github.com/CarriedWorldUniverse/herald/internal/store"
)

// authorizationCodeGrant is the RFC 6749 §4.1 grant_type value.
const authorizationCodeGrant = "authorization_code"

// CodeResolver is the slice of identity the code grant needs: load the user
// the /authorize step authenticated, plus the shared claim resolver.
type CodeResolver interface {
	GetUser(ctx context.Context, id string) (store.User, error)
	IdentityResolver
}

// CodeGrant implements the authorization_code token exchange: redeem the
// single-use code, verify PKCE + client/redirect binding, and issue the same
// access(+refresh) tokens the password grant issues. Mirrors HumanGrant's shape.
type CodeGrant struct {
	p       *Provider
	id      CodeResolver
	codes   *CodeStore
	refresh *RefreshIssuer
}

// NewCodeGrant wires the grant.
func NewCodeGrant(p *Provider, id CodeResolver, codes *CodeStore, refresh *RefreshIssuer) *CodeGrant {
	return &CodeGrant{p: p, id: id, codes: codes, refresh: refresh}
}

// ServeToken handles POST /token for grant_type=authorization_code.
func (g *CodeGrant) ServeToken(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		oauthError(w, http.StatusBadRequest, "invalid_request", "unparseable form")
		return
	}
	pa, ok := g.codes.Redeem(r.Form.Get("code"))
	if !ok {
		oauthError(w, http.StatusUnauthorized, "invalid_grant", "code rejected")
		return
	}
	// RFC 6749 §4.1.3: the exchange must present the same client + redirect
	// the code was issued to, and (RFC 7636) the PKCE verifier.
	if r.Form.Get("client_id") != pa.ClientID ||
		r.Form.Get("redirect_uri") != pa.RedirectURI ||
		!VerifyPKCE(pa.CodeChallenge, r.Form.Get("code_verifier")) {
		oauthError(w, http.StatusUnauthorized, "invalid_grant", "code rejected")
		return
	}
	u, err := g.id.GetUser(r.Context(), pa.UserID)
	if err != nil {
		oauthError(w, http.StatusUnauthorized, "invalid_grant", "code rejected")
		return
	}
	claims, err := accessClaims(r.Context(), g.id, u)
	if err != nil {
		oauthError(w, http.StatusUnauthorized, "invalid_grant", "code rejected")
		return
	}
	tok, err := g.p.SignToken(claims)
	if err != nil {
		oauthError(w, http.StatusInternalServerError, "server_error", "token signing failed")
		return
	}
	resp := map[string]any{
		"access_token": tok,
		"token_type":   "Bearer",
		"expires_in":   int(g.p.TTL().Seconds()),
	}
	if g.refresh != nil {
		// Best-effort, same posture as HumanGrant: a refresh failure still
		// returns a usable access token, but log it.
		if rtok, err := g.refresh.Issue(r.Context(), u.ID); err != nil {
			log.Printf("oidc: refresh.Issue for human %s: %v", u.ID, err)
		} else {
			resp["refresh_token"] = rtok
		}
	}
	writeJSON(w, http.StatusOK, resp)
}
```

NOTE: if `IdentityResolver` (see `claims.go`) already includes a `GetUser`-equivalent (it may be named differently, e.g. part of the resolver the grants share), drop the extra method from `CodeResolver` and use the existing one — do NOT duplicate an existing lookup. Check `internal/identity/identity.go` for the canonical user-by-id method name and use that.

- [ ] **Step 4: Add the GrantMux case**

In `internal/oidc/grantmux.go`: add a `code TokenHandler` field, a parameter in `NewGrantMux` (insert before the variadic federated — update ALL existing callers: `cmd/herald/main.go` and any test constructing GrantMux), and a switch case:

```go
	case authorizationCodeGrant:
		if m.code != nil {
			m.code.ServeToken(w, r)
			return
		}
		oauthError(w, http.StatusBadRequest, "unsupported_grant_type", "grant_type not supported")
```

- [ ] **Step 5: Run the full package test suite**

Run: `go test ./internal/oidc/ -v`
Expected: PASS (including all pre-existing tests — the GrantMux signature change must not break them)

- [ ] **Step 6: Commit**

```bash
git add internal/oidc/code_grant.go internal/oidc/code_grant_test.go internal/oidc/grantmux.go
git commit -m "feat(oidc): authorization_code grant — redeem code, verify PKCE, issue standard tokens"
```

---

### Task A5: Discovery doc + main.go wiring

**Files:**
- Modify: `internal/oidc/provider.go` (Handler routes + discovery fields)
- Modify: `cmd/herald/main.go` (mount /authorize, env, wire CodeGrant)
- Test: extend the existing discovery test (find it: `grep -rn "openid-configuration" internal/oidc/*_test.go`)

- [ ] **Step 1: Write the failing test** — extend the existing discovery test to assert the new fields:

```go
// Add to the existing discovery test's expectations:
//   "authorization_endpoint": issuer + "/authorize"
//   "response_types_supported" contains "code"
//   "grant_types_supported" contains "authorization_code"
//   "code_challenge_methods_supported": ["S256"]
```

Find the discovery handler (`handleDiscovery` in provider.go or a sibling file) and its test; add assertions for the four fields above to the test first.

- [ ] **Step 2: Run to verify it fails**

Run: `go test ./internal/oidc/ -run Discovery -v`
Expected: FAIL on the new fields

- [ ] **Step 3: Implement discovery + routes**

In the discovery response map add:

```go
	"authorization_endpoint":              strings.TrimRight(p.issuer, "/") + "/authorize",
	"code_challenge_methods_supported":    []string{"S256"},
```

and append `"code"` to `response_types_supported`, `"authorization_code"` to `grant_types_supported`.

In `Provider`, add (following the SetTokenHandler pattern at `provider.go:96`):

```go
// SetAuthorizeHandler wires GET/POST /authorize (the auth-code flow task).
func (p *Provider) SetAuthorizeHandler(h http.Handler) { p.authorizeEP = h }
```

plus the `authorizeEP http.Handler` field, and in `Handler()`:

```go
	mux.HandleFunc("/authorize", func(w http.ResponseWriter, r *http.Request) {
		if p.authorizeEP == nil {
			http.Error(w, "authorization endpoint not configured", http.StatusNotImplemented)
			return
		}
		p.authorizeEP.ServeHTTP(w, r)
	})
```

- [ ] **Step 4: Wire main.go**

In `cmd/herald/main.go` (around line 67-80, next to the existing grant wiring):

```go
	oidcClients, err := oidc.ParseClients(os.Getenv("HERALD_OIDC_CLIENTS"))
	if err != nil {
		log.Fatalf("herald: HERALD_OIDC_CLIENTS: %v", err)
	}
	codes := oidc.NewCodeStore(nil)
	provider.SetAuthorizeHandler(oidc.NewAuthorize(oidcClients, codes, idsvc))
	provider.SetTokenHandler(oidc.NewGrantMux(
		oidc.NewAgentGrant(provider, idsvc, refresh),
		oidc.NewHumanGrant(provider, idsvc, refresh),
		oidc.NewRefreshGrant(provider, idsvc, refresh),
		oidc.NewCodeGrant(provider, idsvc, codes, refresh),
		oidc.NewFederatedGrant(provider, idsvc, st, issuerRegistry, refresh),
	))
```

(adapt to the final `NewGrantMux` signature from Task A4) and mount the route next to the other OIDC paths (`main.go:95-99`):

```go
	mux.Handle("/authorize", provider.Handler())
```

`idsvc` (identity.Service) must satisfy `CodeResolver` — it already has the user-by-id method (verify the name in `internal/identity/identity.go` per the Task A4 note).

- [ ] **Step 5: Build + full test suite**

Run: `go build ./... && go test ./...`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add internal/oidc/provider.go cmd/herald/main.go internal/oidc/
git commit -m "feat(oidc): advertise + mount /authorize; wire code grant and client registry"
```

---

### Task A6: End-to-end flow test

**Files:**
- Create: `internal/oidc/authcode_e2e_test.go`

One test that walks the whole dance over httptest, proving the pieces compose: GET /authorize → POST login → follow redirect → exchange code → verify token claims with `provider.VerifyToken`.

- [ ] **Step 1: Write the test**

```go
package oidc

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

func TestAuthorizationCodeFlowEndToEnd(t *testing.T) {
	// Assemble a full provider exactly as main.go does (reuse the package's
	// existing provider+resolver test helpers, per Task A4 note).
	p := testProvider(t)
	id := testIdentityResolver(t)
	clients, _ := ParseClients("atlas|https://a/cb")
	codes := NewCodeStore(nil)
	p.SetAuthorizeHandler(NewAuthorize(clients, codes, id))
	p.SetTokenHandler(NewGrantMux(
		nil, nil, nil, // agent/human/refresh not exercised here — adapt to final signature
		NewCodeGrant(p, id, codes, nil),
	))
	srv := httptest.NewServer(p.Handler())
	defer srv.Close()

	verifier := "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
	sum := sha256.Sum256([]byte(verifier))
	challenge := base64.RawURLEncoding.EncodeToString(sum[:])

	// 1. GET /authorize renders the form
	authzURL := srv.URL + "/authorize?client_id=atlas&redirect_uri=" + url.QueryEscape("https://a/cb") +
		"&response_type=code&state=st8&code_challenge=" + challenge + "&code_challenge_method=S256"
	resp, err := http.Get(authzURL)
	if err != nil || resp.StatusCode != 200 {
		t.Fatalf("GET /authorize: %v %d", err, resp.StatusCode)
	}

	// 2. POST credentials; don't follow the redirect — inspect it
	noRedirect := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	form := url.Values{
		"client_id": {"atlas"}, "redirect_uri": {"https://a/cb"}, "response_type": {"code"},
		"state": {"st8"}, "code_challenge": {challenge}, "code_challenge_method": {"S256"},
		"username": {"u-good"}, "password": {"pw"},
	}
	resp, err = noRedirect.Post(srv.URL+"/authorize", "application/x-www-form-urlencoded", strings.NewReader(form.Encode()))
	if err != nil || resp.StatusCode != http.StatusFound {
		t.Fatalf("POST /authorize: %v %d", err, resp.StatusCode)
	}
	loc, _ := url.Parse(resp.Header.Get("Location"))
	if loc.Query().Get("state") != "st8" {
		t.Fatal("state lost")
	}

	// 3. Exchange the code
	resp, err = http.PostForm(srv.URL+"/token", url.Values{
		"grant_type": {"authorization_code"}, "code": {loc.Query().Get("code")},
		"redirect_uri": {"https://a/cb"}, "client_id": {"atlas"}, "code_verifier": {verifier},
	})
	if err != nil || resp.StatusCode != 200 {
		t.Fatalf("token exchange: %v %d", err, resp.StatusCode)
	}
	var body struct {
		AccessToken string `json:"access_token"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil || body.AccessToken == "" {
		t.Fatalf("token body: %v", err)
	}

	// 4. The token is a normal herald human token
	claims, err := p.VerifyToken(body.AccessToken)
	if err != nil {
		t.Fatal(err)
	}
	if claims["kind"] != "human" || claims["sub"] != "u-good" {
		t.Fatalf("claims: %+v", claims)
	}
}
```

- [ ] **Step 2: Run it**

Run: `go test ./internal/oidc/ -run TestAuthorizationCodeFlowEndToEnd -v`
Expected: PASS (adapt stub-helper names as in Task A4; the resolver must let "u-good"/"pw" authenticate and resolve claims with kind=human)

- [ ] **Step 3: Full suite + vet**

Run: `go vet ./... && go test ./...`
Expected: PASS

- [ ] **Step 4: Commit, push, PR**

```bash
git add internal/oidc/authcode_e2e_test.go
git commit -m "test(oidc): end-to-end authorization-code flow over httptest"
git push -u origin feat/oidc-authorization-code
gh pr create --title "herald: OAuth2 authorization-code flow (+PKCE, hosted login)" \
  --body "Adds /authorize (herald-hosted login form), env-registered public clients (HERALD_OIDC_CLIENTS), mandatory S256 PKCE, and the authorization_code grant. First consumer: atlas (Strata map). Per docs/2026-06-12-atlas-strata-viz-design.md in carriedworld-cloud."
```

---

### Task A7: Deploy herald with the atlas client registered

**Files:**
- Modify: `/home/operator/src/herald/deploy/k3s/20-deployment.yaml` (or wherever the herald Deployment env block lives — `grep -rn HERALD_ISSUER /home/operator/src/herald/deploy/`)

- [ ] **Step 1:** After the PR is CI-green, squash-merge it.
- [ ] **Step 2:** Wait for the GHCR release workflow on main; get the new digest:

```bash
gh run list --repo CarriedWorldUniverse/herald --workflow release-image.yml --limit 1
# then resolve digest for the new sha-<short> tag (crane/skopeo or the GH packages UI)
```

- [ ] **Step 3:** Update the herald Deployment: bump image pin to the new `sha-<short>@sha256:<digest>`, and add the env var:

```yaml
            - name: HERALD_OIDC_CLIENTS
              value: "atlas|https://atlas.tail41686e.ts.net/oauth/callback"
```

- [ ] **Step 4:** Commit the manifest BEFORE applying (the 15-min reconcile CronJob reverts uncommitted live changes), then apply, then verify:

```bash
# from the manifest repo, commit + push first, then:
ssh jacinta@100.91.185.71 'sudo kubectl -n cwb rollout status deploy/herald'
curl -s http://dmonextreme.tail41686e.ts.net:8080/herald/.well-known/openid-configuration | jq .authorization_endpoint
# Expected: ".../authorize"
```

---

## Self-review notes (already applied)

- **GrantMux signature change** touches `cmd/herald/main.go` + any tests constructing it — called out in A4 step 4 explicitly.
- **`testProvider`/`testIdentityResolver`** helper names are this plan's only intentional indirection: the package certainly has provider+resolver test fixtures (agent_grant_test.go builds a full flow), but their exact names must be read from the code, not guessed by the plan. A4/A6 carry explicit instructions to adapt.
- **No store schema change** anywhere — auth codes are deliberately in-memory (documented in code comment, authcode.go).
- **Issuer is plain http on the tailnet today** (`HERALD_ISSUER=http://dmonextreme.tail41686e.ts.net:8080/herald/`). The login form + token exchange ride it. Acceptable inside the tailnet (encrypted underneath by WireGuard); revisit when the edge gets TLS.
