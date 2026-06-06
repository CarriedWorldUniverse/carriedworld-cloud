# CWB — Multi-Consumer Identity & Credential Authority (Spec A)

**Status:** design, approved 2026-06-06
**Scope:** the CWB platform capability that lets *any* consumer org authorize its identities' actions without handing those identities raw credentials. Consumer-shape-agnostic. NEX-467 (the nexus consumption) is the dependent follow-on spec (Spec B), not covered here.

## Why

CWB must let an org operate **identities — human or AI — that act under the org's authority without ever holding the org's raw credentials** (git tokens, API keys, provider keys). The `cw credential git-helper` already proves the pattern for git: the identity never holds the token; it's brokered at use-time. Spec A generalizes that into a first-class, multi-tenant capability so the same machinery serves a person and an agent, and serves many consumer orgs in isolation.

## Frame

- **Identity, not AI.** The unit of trust is an *identity* (human or AI). "AI" is a property of the identity, not a separate code path. A human operator and a nexus aspect are the same kind of thing to CWB.
- **Multi-consumer from the ground up.** herald + custodian serve N consumer orgs. Nothing about any consumer's *shape* (k8s, pods, gateways) lives in the CWB layer — that is consumption detail. CWB knows only "an authenticated identity, in an org, authorizing an action, isolated from every other org."
- **Consumers choose their shape.** We funnel all org activity through the nexus (a gateway with an agent fleet behind it). Another org is one human + one AI wired directly. Same two components, different consumption.

## Architecture — two components

### 1. Herald — identity & rights

The org's IAM. It controls **who an identity is** and **what rights it has** in the org.

- The **management org** is the genesis root. **Consumer orgs are tenants**, each granted an **org-scoped authority once at genesis**; autonomous thereafter (survives operator absence and restarts).
- Each org **enrolls its identities per-identity** (human or AI), with rights. Per-identity enrollment is deliberate: explicit principals, per-identity revocation, auditable — not "trust a whole domain."
- An identity authenticates with its enrolled proof; herald asserts **who it is + what it may do**, *only within its own org*.

#### Proof material — federated external attestation

An enrolled identity proves itself with an **ephemeral attestation from a federated issuer**, never a long-lived held secret:

- At genesis the org registers the **issuers it trusts** — a small set (e.g. its k8s cluster's TokenReview for in-cluster AI identities; a passkey/OIDC provider for humans).
- Each identity is enrolled per-identity as a specific **`{issuer, subject}`** — e.g. identity `plumb` = subject `system:serviceaccount:nexus:plumb` at the nexus-cluster issuer; identity `alice` = her passkey subject.
- To authenticate, the identity presents a **short-lived attestation from its issuer**. Herald verifies the issuer is trusted *for that org* **and** the subject matches the enrolled identity, then mints a **short-lived herald-identity session**.
- The identity therefore holds **no long-lived CWB secret**: an AI's proof is its k8s-projected SA token (ephemeral, k8s-rotated); a human's is a device-bound passkey. This extends "no raw credentials" to the identity's *own authenticator*, not only to the external credentials custodian brokers — an AI agent carries nothing forgeable off-box.
- **Casket** is the substrate for the sessions/assertions herald *issues*, and a casket public key is an accepted self-contained `{issuer, subject}` form for offline or edge identities — but it is **not** a held identity key an agent must carry.

### 2. Custodian — credential vault, keyed by herald identity

The broker for **external** credentials granted to identities.

- Custodian **holds the org's external secrets** (git/API/provider creds). These are the "raw credentials" identities must never hold.
- An identity presents its **herald identity as the key**; custodian looks up the credential **granted to that identity** and **brokers its use** — proxying the action or returning a short-lived scoped token — so the **raw secret never reaches the identity**.
- Grants are per-identity; custodian serves only an identity's **own-org** credentials.

### The keyed-vault relationship

The herald identity is the *key*; the raw secret stays in custodian. Authentication and rights are herald's job; secret-holding and brokered use are custodian's. Neither alone hands an identity a raw credential.

## Trust model & isolation

```
management org  ──grant (genesis, once)──▶  consumer org authority
       │                                            │
   (roots herald)                          enrolls identities (herald)
                                                    │
        identity authenticates ──▶ herald identity (who + rights, org-scoped)
                                                    │
                          herald identity = key ──▶ custodian brokers granted external cred
```

- **Org isolation:** herald rejects any identity or right outside its org; custodian serves only own-org grants. A **consumer compromise is bounded to one org** — never the platform, never a sibling tenant.
- **Genesis is the only operator-present step.** The management org grants the consumer org its authority once; everything after is autonomous.

## Data flow

**Genesis (once, operator present):** management org registers the consumer org and grants it an org-scoped authority; the org's herald tenant is established; initial identities + credential grants are seeded.

**Runtime (autonomous):**
1. An identity authenticates with its enrolled proof.
2. Herald asserts the herald identity (who + rights), scoped to the org.
3. To act against an external resource, the identity presents its herald identity to custodian.
4. Custodian resolves the granted credential and **brokers the action** (proxy or short-lived scoped token); the raw secret never leaves custodian.

## Failure modes (fail-closed)

- **Auth fails / proof invalid** → no herald identity → no custodian access. The identity simply can't act; nothing half-authorized.
- **Identity not granted the credential** → custodian refuses. Rights are explicit per-identity.
- **Cross-org attempt** → impossible: herald scopes the identity to its org; custodian holds only own-org grants.
- **Identity/grant revoked** → herald stops asserting it (and/or custodian drops the grant) → in-flight access dies at the next check. Revocation must bite at **assertion/retrieval time**, not only at issue time.
- **Custodian unavailable** → identities can authenticate (herald) but can't *act* on external resources until it returns. Degraded, not breached.
- **Management-org / genesis compromise** → platform-wide; out of scope for a consumer's design (it is the management org's security boundary).

## Consumer shapes (illustrative, not normative)

- **Nexus (ours):** an aspect joins the nexus network (its keyfile — Spec B, *not* part of CWB), then *is* a herald identity and reaches custodian-brokered credentials. A whole agent fleet behind the gateway, zero raw secrets on any pod.
- **One human + one AI:** the same two components, wired directly — the human and the AI are two enrolled identities in their org.

## Scope boundary (NOT in Spec A)

- **The brokering mechanism** (custodian proxies the action vs issues a short-lived scoped token) is a custodian-internal choice to settle in the plan; both honor "no raw secret to the identity."
- **The registered-issuer set + attestation formats** a given org trusts (k8s TokenReview, OIDC, passkey, casket public key) — the proof *model* is fixed (federated external attestation, per-identity `{issuer, subject}`); the concrete issuer adapters herald ships are an implementation list.
- **Nexus's consumption** (keyfile → network → herald identity → custodian; the k8s-SA-vouched fleet) is **Spec B / NEX-467**.

## Open decisions for the implementation plan

1. Custodian brokering shape (proxy vs short-lived scoped token) per credential kind.
2. Revocation enforcement points (assertion-time, retrieval-time, or both).
3. The concrete issuer adapters herald ships first (k8s TokenReview is required for the nexus consumer; OIDC/passkey for humans).
