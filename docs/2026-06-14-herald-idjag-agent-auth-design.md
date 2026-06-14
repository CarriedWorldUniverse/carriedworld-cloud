# herald ID-JAG agent-auth model — design

**Date:** 2026-06-14
**Status:** design (operator-approved sections). The way agents authenticate across CWB.

## Goal

Define how agents authenticate to CWB services: **herald is the agents' identity provider**; an agent proves its identity to herald, herald mints an **audience-scoped identity-assertion grant (ID-JAG)**, the agent presents it to the target service, and the service verifies it against herald's JWKS. Conform to the open **auth.md / ID-JAG** interoperability spec (not a bespoke scheme) so the same model extends to federation (external IdPs inbound, foreign auth.md services outbound) later. This realizes `project_herald_rooted_agent_bootstrap` via the open standard.

## Background / decisions (operator, 2026-06-14)

- auth.md is an **interoperability spec, not a tool** — we *conform to it* (like OAuth), we don't rebrand it. The "writ" own-name idea is retired: interop requires speaking the standard's wire.
- **ID-JAG = an audience-scoped, IdP-signed assertion.** This largely *formalizes what herald already does* — herald already issues audience-scoped EdDSA JWTs, publishes JWKS, and CWB services verify via `heraldauth` through interchange. So this is mostly: shape the existing agent token as the standard ID-JAG + add the discovery block + keep the wire conformant.
- **Internal-first:** herald is both IdP *and* verifier for our agents (closed loop, dogfoodable now). Federation seams are present but **dormant**.
- **Distinct from auth-as-a-human / lynxai** (separate spec): that handles *non-cooperative, human-only* external services (codex→OpenAI, SaaS) via a blind browser session. This spec is the *cooperative* agent↔CWB path and never involves browser-form-filling.

## Architecture

```
agent (herald identity) ──auth──▶ herald ──mints──▶ ID-JAG (aud-scoped, signed)
                                                        │ agent presents
                                                        ▼
                          CWB service (via interchange) ──verify vs herald JWKS──▶ authz
```

Three commitments: **(1) conform to the ID-JAG/auth.md wire** (token type `urn:ietf:params:oauth:token-type:id-jag`, well-known discovery, RFC-7523 jwt-bearer exchange); **(2) internal-first** (herald = IdP + verifier, reuse existing code); **(3) the shape buys federation for free, later** (same verb works inbound + outbound).

## Components (extend herald's existing pieces)

1. **Discovery.** Add an `agent_auth` block to herald's `/.well-known/oauth-authorization-server`: `identity_endpoint`, `events_endpoint`, `identity_types_supported`, `identity_assertion.assertion_types_supported: ["urn:ietf:params:oauth:token-type:id-jag"]`. Add `/.well-known/oauth-protected-resource` on CWB services pointing at herald as the authz server. Reserve the agent-facing skill-manifest URL field (human-readable manifest deferrable for internal-first).
2. **ID-JAG mint** (extends `internal/oidc/agent_grant.go` + `internal/issuer`). Input: an authenticated agent (existing herald agent identity / keyfile) + a requested `audience` (target service). Output: a herald-signed EdDSA JWT — `token_type=urn:ietf:params:oauth:token-type:id-jag`, claims `{iss: herald, sub: <agent-id>, act: {sub: <responsible_human>}, aud: <target>, exp: <short>, iat, jti, client_id}`. Exposed via the `/agent/identity` endpoint (`type: identity_assertion`) for the standard shape.
3. **Service-side verify** (reuses `heraldauth` via interchange). Fetch+cache herald JWKS; verify EdDSA signature; validate `iss ∈ trusted-issuers`, `aud = self`, `exp/iat`, `jti` (replay cache) → identity-derived authz from `sub` + `act.sub`. Service accepts the ID-JAG as bearer, OR exchanges it at herald's token endpoint via `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer` for a service access token (internal path may short-circuit and use the ID-JAG directly).
4. **Trusted issuers** (reuses `RegisterIssuer`). Internal: herald trusts its own issuer/JWKS. Federation seam (dormant): register external IdPs (inbound verify) / herald registered by foreign services (outbound).
5. **responsible_human / act.sub** (reuses herald's `responsible_human`). Every ID-JAG carries the human the agent acts for → accountability chain "agent X acting for human Y", audited. Authz can key off both.
6. **Revocation.** Short `exp` is the primary control. `events_endpoint` + an assertion-revoked event for the longer-lived/federated case. MVP = short exp + herald's existing token revocation; the events surface comes with federation.

## Flows

**Internal agent → CWB (MVP, the everyday path):**
1. Agent (its herald keyfile identity) needs to call a CWB service (e.g. ledger).
2. Agent authenticates to herald and requests an ID-JAG scoped `aud=ledger`.
3. herald mints the ID-JAG (signed, short exp, `act.sub`=responsible_human).
4. Agent calls ledger through interchange, presenting the ID-JAG.
5. interchange/heraldauth verifies (JWKS, aud, exp, jti) → authz → grant/deny. *(Optional two-step: exchange at herald's token endpoint via jwt-bearer; internal short-circuits.)*

**Inbound federation (dormant → new-user onboarding):** an external agent presents *its IdP's* ID-JAG to herald `/agent/identity`; herald checks the issuer is trusted (`RegisterIssuer`), fetches that provider's JWKS, verifies, validates claims → issues a herald assertion / provisions the user → CWB token.

**Outbound (dormant):** a herald-issued ID-JAG presented to a foreign auth.md service that trusts herald's JWKS.

## Error handling

- Invalid / expired ID-JAG → `401` with resource metadata (`/.well-known/oauth-protected-resource`) so the agent can re-mint.
- Untrusted `iss` / `aud` mismatch / `jti` replay / revoked → reject (401/403).
- Bounded clock-skew tolerance on `exp/iat`.

## Scope

**In (MVP, internal-first):** the `agent_auth` discovery block; ID-JAG mint (audience-scoped, conformant claim set) via the `/agent/identity` endpoint extending `agent_grant`; service-side verify via heraldauth (aud/exp/jti/trusted-iss); the **ID-JAG presented directly as the bearer** (short-circuit — no second token, since it's already audience-scoped + herald-verified); `responsible_human` in the assertion; short-exp revocation. herald trusts only itself. *(The RFC-7523 jwt-bearer token-exchange two-step is deferred to the federated path, where the resource server issues its own tokens.)*

**Out (dormant seams, later):** inbound external-IdP trust + new-user onboarding/claim ceremony; outbound to foreign auth.md services; the assertion-revoked events surface; the human-readable skill manifest. (All enabled by the conformant shape — populate when external users/services are on the horizon.)

**Not this spec:** auth-as-a-human / lynxai (non-cooperative human-only services) — separate.

## Reused vs new

- **Reused:** OIDC provider, `issuer`/JWKS/EdDSA, `oidc/agent_grant.go`, `oidc/federated_grant.go`, `RegisterIssuer`, `heraldauth`, `responsible_human`, interchange verification.
- **New/changed:** the ID-JAG token shape (token-type + claim set, spec-conformant); the `agent_auth` discovery block; the `/agent/identity` endpoint; audience-scoping of agent grants; (dormant) revocation events.

## Testing

- **Unit:** ID-JAG mint produces the conformant claim set (type, iss, sub, act.sub, aud, exp, jti); verifier accepts a valid ID-JAG and rejects on bad aud / expired / replayed jti / untrusted iss.
- **Integration:** an agent mints an ID-JAG and calls a real CWB service end-to-end through interchange; the `responsible_human` chain surfaces to the service; a wrong-audience ID-JAG is rejected.
- **Conformance:** the discovery block + token type validate against the auth.md/ID-JAG spec (so federation interop holds when enabled). Add to cwb-conformance.

## Relates

- `project_authmd_herald_agent_auth`, `project_herald_rooted_agent_bootstrap` (realized via this), `herald_admin_authz`.
- auth-as-a-human / lynxai — the complementary *outbound, non-cooperative* tool (separate spec).
- cwb-conformance (add the agent_auth conformance check).
