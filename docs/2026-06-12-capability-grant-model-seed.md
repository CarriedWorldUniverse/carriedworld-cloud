# Capability / grant-tree model — design seed

**Date:** 2026-06-12 (late)
**Status:** seed for a proper brainstorm; operator wants a structured grant
tree of functionality across org + cwb, analogous to the capabilities GitHub
encodes into PAT tokens.

## Where we are

An organically-grown FLAT scope list, strings-sprinkled-in-code: app:read/
write, config:read/write, repo:read/write, issue:read/write/claim/admin,
knowledge:read/write, agent:create, herald:org-admin, herald:platform-admin.
Implicit `<resource>:<action>` structure, but no canonical definition, no
hierarchy, no bundling, no fine-graining. Enforcement is decentralized (each
pillar checks its own scope strings).

## The GitHub lessons

- Classic PATs (coarse: repo, admin:org) → they HAD to build fine-grained
  PATs (per-resource × per-permission × level) for least privilege. Lesson:
  **don't paint into the coarse corner — make the grammar fine-grained-ready
  from day one even if grants start coarse.**
- They got right: a CENTRAL documented permission vocabulary, with each API
  enforcing its own. Vocabulary central, enforcement distributed.

## Design axes

1. **Grammar, extensible to fine-grained.** Today pillar:level. Add a
   resource dimension later — cairn:write (all repos) → cairn:repo/<id>:write
   (one) — without a migration. Choose the string grammar NOW to allow this.
2. **Canonical registry = the tree.** One source of truth (shared lib /
   cwb-proto) defining every capability: id, pillar, level, description,
   org-scoped vs platform, and IMPLICATION (write ⊇ read, admin ⊇ write).
   Enforcement stays per-pillar; vocabulary is central. Kills magic strings.
3. **Roles / bundles.** Named bundles expand to scope sets (developer =
   repo:write + issue:write + knowledge:read; owner = org-admin + functional)
   so you grant a role, not twelve scopes. The tree composes.
4. **Two roots.** org-FUNCTIONAL (repo:write — what I do IN my org) vs
   platform-GOVERNANCE (herald:platform-admin — what I do TO the platform).
   The croft=normal-user / cwadmin=break-glass principle is a statement about
   which root an identity draws from.
5. **Transitivity invariant, enforced at grant time.** Can't grant what you
   don't hold (effective = parent AND self, never more — the established
   cairn-aspect-perms rule). The grant verb validates the requested scope
   against the granter's holdings AND the registry.
6. **Discoverability.** cw caps / an endpoint listing the tree; atlas/UI can
   render it; the grant verb validates against it.

## Set at the service, resolved through herald identity (operator 2026-06-12)

**CORRECTION to an earlier over-centralized framing.** Herald does NOT stamp
every grant into the token. The split (the GitHub / Kubernetes / AWS-IAM
pattern — identity central + travels; authorization set at the resource):

- **Herald carries IDENTITY** (verified subject, org, kind=ai, owner) **and
  owns the capability VOCABULARY** — the standardized permission language so
  every pillar means the same thing by read/write/admin.
- **The service HOLDS the grants and RESOLVES them against the herald
  identity.** Custodian knows who created/may-read each credential; cairn
  knows who has write on a repo; ledger who admins a project. Grant state
  lives with the resource's owning service; at check time the service asks
  "what can THIS herald identity do HERE" against its own records. The token
  answers WHO; the service answers WHAT-HERE. Tokens stay small; herald is
  never an omniscient permission DB.

This makes the custodian rules (prior section) fall out naturally rather than
being special-cased.

**The line to draw — DECIDED (operator 2026-06-12, forced by JWT size: a
token is ~4-8KB and rides every request, so it CANNOT carry the world).**
Metaphor: the token is a PASSPORT; each service runs its own border control
with its own guest list keyed by passport.
- **In the token (bounded identity envelope):** sub, org, kind (human/ai/
  service), owner, the COARSE governance roles (platform-admin, org-admin),
  org/product membership. A handful of claims; stable; herald-owned. Token
  size is a function of WHO YOU ARE, never of WHAT EXISTS — a thousand repos
  add zero bytes.
- **Service-resolved (unbounded, per-resource, ownership):** everything else
  — cairn repo collaborators, custodian per-credential owner+read lists,
  ledger project roles — resolved at the owning service against the token
  identity, from the service's own grant store.
- **Revocation:** fine-grained (service-resolved) is INSTANT (next call hits
  the live store); coarse (token-carried) is bounded by the 10-min TTL —
  fine, governance roles change rarely. Another reason fine-grained must NOT
  be token-baked.

**Grant verbs become per-service** (refines NEX-637): "grant croft
org-admin" is a herald op; "grant alice write on repo X" is a CAIRN op — uses
herald's vocabulary, addresses the grantee BY herald identity, but the grant
is stored in cairn. Not one `cw human grant` — herald-grants for governance +
per-service grants (`cw cairn grant`, `cw custodian share`) that all resolve
grantees through herald.

**The cwb-client interceptor (NEX-634) is the seam**: verify token →
establish herald identity in ctx → service's own authz resolves against it.
Interceptor does IDENTITY; service does AUTHORIZATION.

## Two access models, not one (operator 2026-06-12, via custodian)

The tree needs BOTH axes; effective = max of them:
- **Scope-based** — what the org grants you over ORG resources.
- **Ownership-based** — what you made, you control, regardless of scope.

Custodian is the worked example:
- Member gets **custodian:read** over **org-created** credentials — USE the
  shared Meshy key / Drive token / DB connection, cannot mutate.
- Creator always has **create/read/delete** over credentials THEY created.
This is the satchel-vs-vault split made concrete: self-created = personal bag
(full CRUD, yours); org-created = shared vault (members read). Same shape as
GitHub (own your repos outright; org repos follow org role).

OPEN (decide at spec): org-credential lifecycle (create/delete of SHARED org
creds) is neither member-read nor self-ownership — it's an org-admin /
custodian:write|admin capability. And shared org creds should be OWNED BY THE
ORG (org-admin manages), not the individual who ran the command, so they
survive that person leaving.

## Step zero

Inventory every scope actually CHECKED in code today (grep the pillars),
rationalize the flat list into the tree, THEN design forward. (Distinct from
NEX-631's identity-mechanism audit — this is the capability VOCABULARY.)

## Threads it underpins

- NEX-635 (machine scope matrix) becomes "assign tree nodes to services".
- NEX-637 (grant/revoke verb) assigns tree nodes to humans; validates
  against the registry + transitivity.
- NEX-638 (owned-AI tag) is ORTHOGONAL — classification, not capability.
- Per-org crypto isolation + multi-cloud slice delegation are the
  fine-grained resource dimension showing up elsewhere.

Spike: NEX-639.
