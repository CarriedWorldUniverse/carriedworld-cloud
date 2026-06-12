# Satchel & the credential architecture (design amendment)

**Date:** 2026-06-12 (evening, post-atlas-go-live)
**Status:** direction agreed with operator; amends the satchel design (custodian PR #1)
**Provoked by:** retrieving the herald genesis password required ssh + kubectl +
base64 — raw category-2 secret handling, by hand, as the wrong identity.

## The two kinds of secret

1. **Root credentials — human-carried, platform-blind.** The user's
   password/passkey (herald stores only the hash/public half), and the
   platform-resurrection recovery key (off-platform by structural necessity:
   the platform cannot store the credential that resurrects the platform).
   A root cannot be brokered — it is what brokering bottoms out in. You can
   never eliminate the human-carried root, only choose what it unlocks and
   how it recovers.
2. **Everything else — platform-held, identity-brokered.** Custodian secrets,
   API keys, git creds, DB connections, the genesis password. Humans never
   carry or kubectl these; they prove a root and the platform hands over
   exactly what their rights cover, in the moment, audited.

Tonight's incident was a missing **enrollment** (the operator's own human had
no login credential), not primarily a tooling gap.

## satchel = the human's bag · custodian = the org's vault

The satchel is **person-rooted, org-less by construction**: unlocked by a
casket key derived from the holder's personal root (passphrase/passkey). It
carries the holder's credentials — org logins (herald) among them. The chain:

```
human root → satchel (personal, e2e) → org login (herald) → org rights
           → custodian's operational secrets (brokered)
```

The platform stores only **ciphertext** (file-per-secret, casket-encrypted,
synced via git-on-cairn) — cairn cannot read anyone's bag. That e2e contract
is what makes hosting other humans' satchels trustworthy.

## Two retrieval tiers (layered, not peers)

- **Local — the bag itself.** Encrypted files keyed off the personal root,
  decrypted on demand, no platform in the loop. Reads from the LOCAL clone,
  so it works offline and during cluster-down recovery. The local tier holds
  the credential that authorizes the remote tier.
- **Remote — the vault, brokered.** herald-auth'd → custodian, scope-checked,
  audited, lazy-connected (connection per call, no daemon).

**Resolution rule: explicit namespaces, no silent fallthrough.**
`cw cred get personal/<name>` answers from the local bag;
`cw cred get <org>/<name>` answers from custodian. A secret must never come
from a surprising place.

## Rules that keep it honest

- A satchel is never the SOLE path to anything: org admins retain herald's
  independent password-reset flow; a lost bag is an inconvenience, not an
  excommunication.
- The platform owner's tier always keeps one credential off-platform: the
  recovery key (today in LastPass). Everything else can collapse into the
  satchel + passkeys.
- Passkeys are the real fix for daily auth (nothing storable to steal);
  passwords remain bootstrap/fallback. Herald's hardening path (auth-code +
  passkey) stands.
- The genesis owner (cwadmin) shrinks to true break-glass: rotate once the
  operator's own user is enrolled; park behind a platform-admin-only grant.

## Build sequence

1. **Enrollment** (immediate): `cw human password set` verb over herald's
   existing admin API (`POST /api/humans/{id}/password`); enroll the
   operator's croft human so daily login (atlas, future web surfaces) is
   their own identity, not break-glass cwadmin.
2. **satchel M1**: local tier (`cw cred get/put/ls personal/...` — casket
   file store + git-on-cairn sync) + remote tier (`cw cred get <org>/...`
   via herald→custodian). Ingest the genesis password under a
   platform-admin-only grant; rotate it.
3. **satchel M2** (with multi-human tenancy): full personal-vault product —
   multi-recipient envelopes, recovery codes, per-human onboarding. Gated on
   CWB hosting humans beyond the operator.

## Relation to prior design

Custodian PR #1 (satchel as credential on-ramp) keeps its mechanics
(pass-patterned file-per-secret, casket not GPG, git-on-cairn, cw cred CLI,
move-ingest to custodian). This amendment adds the identity model: satchel is
person-rooted not org-rooted; the local tier is the root tier; e2e ciphertext
contract; recovery-independence rules.
