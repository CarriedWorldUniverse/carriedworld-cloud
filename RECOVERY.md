# Strata — Disaster Recovery Runbook

**Audience:** a capable AI agent (or engineer) rebuilding the entire Strata
personal cloud onto fresh hardware, from nothing but: this repo set, a porter
backup on Google Drive, and the recovery keys.

**The bar:** follow this top to bottom and you get a working, conformance-green
platform. Where a step needs a human secret or a human-presence ceremony, it is
marked **[HUMAN]**. Everything else, the agent executes.

**Proven primitives** (don't re-derive): the porter restore was drilled live on
2026-06-12 — all 9 sources recovered from the recovery key alone, SHA-256
verified, DBs `integrity_check` ok. The mason/edge/pillar deploys are all
captured as manifests in this repo.

---

## 0. What you need before starting

- **A fresh host** (the reference is dMon: Fedora, single box; any Linux that
  runs k3s works). Internet access. `sudo`.
- **[HUMAN] GitHub access** to `github.com/CarriedWorldUniverse/*` (a PAT or
  `gh auth login`). Needed to clone repos and (later) for `hosting-git-token`.
- **[HUMAN] The porter recovery key** — the X25519 private key held off-machine
  (LastPass entry; value ~45 chars base64). This is the ONLY thing that
  decrypts the backups without the cluster. Write it to `~/recovery.key`
  (one line, `chmod 600`). Verify it derives the recipient baked into the
  backups (pub must equal what's in `hosting/services/porter-backup.yaml`
  `PORTER_RECIPIENTS`).
- **[HUMAN] Google Drive access** to the backup folder `CarriedWorld-Porter/`.
  Either (a) re-run the device-flow consent (§A) to mint a fresh refresh token,
  or (b) supply a previously-kept oauth bundle. Drive read is required to pull
  the backup.
- **Tooling on the host:** `git`, `go` (1.26+), `podman`, `kubectl`/`k3s`,
  `python3`, `sqlite3`.

```sh
sudo dnf install -y git golang podman python3 sqlite jq    # or apt equivalent
mkdir -p ~/src && cd ~/src
for r in carriedworld-cloud herald almanac custodian cairn commonplace ledger \
         mason porter interchange nexus lynxai cw cwb-proto cwb-conformance casket-go; do
  gh repo clone CarriedWorldUniverse/$r 2>/dev/null || \
    git clone https://github.com/CarriedWorldUniverse/$r.git
done
```

---

## 1. k3s

```sh
curl -sfL https://get.k3s.io | sudo sh -s - --disable traefik
sudo k3s kubectl get nodes            # 1 node, Ready
mkdir -p ~/.kube && sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config && sudo chown $USER ~/.kube/config
kubectl get nodes
```

(Traefik is disabled — Strata uses its own interchange edge + a LoadBalancer
service, not Traefik ingress.)

---

## 2. cert-manager (pinned)

```sh
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.2/cert-manager.yaml
kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=180s
```

Pinned to **v1.16.2** (the version the platform was built against). The static
manifest install needs no Helm.

---

## 3. Namespaces, DNS, and the CA trust root

Everything's mTLS chains to `cwb-ca`, so this comes before any pillar.

```sh
kubectl create namespace cwb
kubectl apply -f ~/src/carriedworld-cloud/clusters/dmon/coredns-custom.yaml   # CoreDNS naming
kubectl apply -f ~/src/carriedworld-cloud/bootstrap/cwb-ca-issuers.yaml       # cwb-selfsigned -> cwb-internal-ca -> cwb-ca
kubectl -n cwb wait certificate/cwb-internal-ca --for=condition=Ready --timeout=120s
kubectl -n cwb get issuer    # cwb-selfsigned + cwb-ca, both Ready
```

A **fresh CA is correct** — every service cert re-mints from it together.
porter restores seeds/DBs/herald-signing-key, NOT certs (they regenerate).

---

## 4. Restore the irreplaceable state FROM porter (before deploying pillars)

The unlock proven on 2026-06-12: **porter restore is standalone** — it needs
only the recovery key + Drive access, NOT a running custodian/almanac. So
restore first, then bring pillars up already holding their real seeds + data.

```sh
cd ~/src/porter && go build -o /tmp/porter-backup ./cmd/porter-backup
# [HUMAN] supply the Drive oauth bundle (§A re-auth, or a kept copy):
#   /tmp/oauth.json = {"client_id","client_secret","refresh_token","token_uri","scope"}
export PORTER_DRIVE_OAUTH_FILE=/tmp/oauth.json
export PORTER_DRIVE_FOLDER="CarriedWorld-Porter/backups"
# find the latest manifest timestamp (printed by restore --help guidance; or
# list the backups/manifests/ folder in Drive). Then:
/tmp/porter-backup restore --key ~/recovery.key --out /tmp/restore <TIMESTAMP>
ls /tmp/restore     # secrets.yaml + per-source .db / .tar.gz, all SHA-verified
```

### 4a. Recreate the k8s secrets from the restored bundle

`/tmp/restore/secrets.yaml` is a multi-doc of every backed-up Secret. Apply the
ones each layer needs (it is safe to apply all — they land in their namespaces):

```sh
# ensure the target namespaces exist first
for ns in croft nexus porter; do kubectl create namespace $ns 2>/dev/null || true; done
# the restored secrets.yaml carries namespace on each item; apply directly:
kubectl apply -f /tmp/restore/secrets.yaml
# CRITICAL ones this brings back: almanac-org-seed, custodian-org-seed,
# herald-secrets (incl. signing_key — without it all old JWTs die),
# cairn-secrets (ssh host key), aspect keyfiles, nexus-broker-env,
# porter-cluster-key, lynxai-env.
```

**[HUMAN] external creds NOT in the backup** — re-supply these (they expire, so
even a backup copy would be stale):
```sh
# GitHub PAT for CI reconcile + croft git:
kubectl -n nexus create secret generic hosting-git-token --from-literal=GH_TOKEN=<PAT>
kubectl -n croft create secret generic croft-gh-token   --from-literal=GH_TOKEN=<PAT>
# Claude Code OAuth (croft orchestrator): claude setup-token, then:
kubectl -n croft create secret generic croft-claude-auth --from-literal=CLAUDE_CODE_OAUTH_TOKEN=<token>
# Tailscale auth key (croft + broker tailscale sidecars):
kubectl -n nexus create secret generic tailscale-auth --from-literal=TS_AUTHKEY=<tskey>
# GHCR pull secret (cluster pulls the service images) — a GitHub token with
# read:packages. Create in every namespace that runs platform images, and
# attach to the default SA so pods pull without per-manifest config:
for ns in cwb nexus croft; do
  kubectl -n $ns create secret docker-registry ghcr-pull \
    --docker-server=ghcr.io --docker-username=<gh-user> --docker-password=<token>
  kubectl -n $ns patch serviceaccount default -p '{"imagePullSecrets":[{"name":"ghcr-pull"}]}'
done
# custom-SA pillars also need it:
for sa in mason porter-backup; do kubectl -n cwb patch serviceaccount $sa -p '{"imagePullSecrets":[{"name":"ghcr-pull"}]}'; done
# Google Drive oauth bundle into custodian (after custodian is up, §6) — see §A.
```

---

## 5. Images — PULL from GHCR (primary)

The platform images publish to GHCR automatically on every merge to main
(each repo's `.github/workflows/release-image.yml`). With the `ghcr-pull`
secret in place (§4a) the cluster pulls them — NO local build needed. The
manifests already reference `ghcr.io/carriedworlduniverse/<svc>:main`, so
there is nothing to do here except confirm the pull works:

```sh
sudo podman login ghcr.io -u <gh-user> -p <token>
sudo podman pull ghcr.io/carriedworlduniverse/herald:main   # smoke one
```

**Fallback (no internet / building a fork / pre-release):** build locally —
```sh
SRC=~/src bash ~/src/carriedworld-cloud/bootstrap/build-all-images.sh
```
then temporarily set the manifests' images to `localhost/<svc>:dev` +
`imagePullPolicy: Never`. The GHCR pull path is the default; this is the
escape hatch.

---

## 6. Deploy the pillars — IN ORDER

Order matters (the hard knots, §8). Wait for each layer's readiness before the
next.

```sh
cd ~/src
# 6.1 herald (identity) — everything authenticates against it
kubectl apply -f herald/deploy/k3s/
kubectl -n cwb rollout status deploy/herald --timeout=180s
# 6.2 sqld (data layer) + the config/secret pillars
kubectl apply -f carriedworld-cloud/clusters/dmon/cwb/sqld.yaml
kubectl apply -f carriedworld-cloud/hosting/services/almanac.yaml
kubectl apply -f carriedworld-cloud/hosting/services/custodian.yaml
kubectl -n cwb rollout status deploy/almanac deploy/custodian --timeout=180s
# 6.3 the remaining pillars (now committed — were cluster-state-only pre-2026-06-12)
kubectl apply -f carriedworld-cloud/hosting/services/cairn.yaml
kubectl apply -f carriedworld-cloud/hosting/services/commonplace.yaml
kubectl apply -f carriedworld-cloud/hosting/services/ledger.yaml
# 6.4 the edge (fronts herald + pillars for outside access)
kubectl apply -f interchange/deploy/k3s/
kubectl -n cwb rollout status deploy/interchange-gateway --timeout=180s
# 6.5 the deployment engine + backups
kubectl apply -f carriedworld-cloud/hosting/services/mason.yaml
kubectl apply -f carriedworld-cloud/hosting/services/porter-backup.yaml
```

### 6a. Restore the databases into the pillars

The pillars came up with empty DBs. Stop each, drop the restored sqlite file
into its PVC, restart. (PVC host paths: `kubectl get pv` → `.spec.hostPath`.)

```sh
restore_db() {  # <deploy> <restored-file> <db-filename-in-pvc>
  kubectl -n cwb scale deploy/$1 --replicas=0
  PV=$(kubectl -n cwb get pvc ${1}-data -o jsonpath='{.spec.volumeName}')
  DIR=$(kubectl get pv $PV -o jsonpath='{.spec.hostPath.path}{.spec.local.path}')
  sudo cp /tmp/restore/$2 "$DIR/$3"
  kubectl -n cwb scale deploy/$1 --replicas=1
  kubectl -n cwb rollout status deploy/$1 --timeout=120s
}
restore_db almanac    almanac.db    almanac.db
restore_db custodian  custodian.db  custodian.db
restore_db herald     herald.db     herald.db
restore_db ledger     ledger.db     ledger.db
restore_db cairn      cairn-db.db   cairn.db
# sqld + cairn-repos are tar.gz — extract into their PVC dirs similarly.
# commonplace: restore its DB the same way if it was in the backup set.
```

---

## 7. Orchestration + apps

```sh
# broker + aspects
kubectl apply -f carriedworld-cloud/hosting/services/nexus-broker.yaml
kubectl apply -f carriedworld-cloud/hosting/services/nexus-broker-custodian-client.yaml
kubectl apply -f carriedworld-cloud/hosting/services/nexus-broker-dispatch-rbac.yaml
kubectl apply -f carriedworld-cloud/hosting/services/shadow-aspect-rbac.yaml
# chart-templated aspects + lynxai
cd carriedworld-cloud && bash hosting/apply.sh    # renders + applies *.values.yaml
# croft (operator workspace) — StatefulSet
kubectl apply -f hosting/services/croft.yaml
```

`hosting/apply.sh` is the idempotent reconcile (renders the convention chart for
the `*.values.yaml` services + applies the raw manifests). The
`bootstrap/hosting-reconcile-cronjob.yaml` re-runs it every 15 min once
`hosting-git-token` exists.

---

## 8. The hard knots (why the order above)

- **mason needs almanac, but mason is a pillar** → mason is deployed by a
  *static manifest* here (step 6.5), not by itself. It then reconciles any
  almanac-declared apps. (M2/NEX-624 will migrate the pillars themselves into
  almanac declarations; until then, the manifests in this repo are authoritative.)
- **interchange fronts herald, but reaches it internally** → herald is a
  ClusterIP; interchange dials `herald.cwb.svc`. herald must be Ready first
  (step 6.1 before 6.4).
- **porter restore needs custodian/almanac, but those are what you're restoring**
  → resolved: restore is **standalone** (recovery key + Drive only, §4), run
  before the pillars. The org seeds come from the backup's `secrets` source,
  which is sealed to the recovery key independently.
- **herald signing_key** → restored from the backup (§4a). If lost entirely,
  generate a new one (`openssl rand -base64 32`) and accept that all
  previously-issued JWTs are invalid.

---

## 9. Verify — conformance green = the rebuild is correct

```sh
cd ~/src/cwb-conformance && go build -o /tmp/cwb-conform ./cmd/cwb-conform
export CWB_HERALD_ADMIN_URL=http://$(kubectl -n cwb get svc herald -o jsonpath='{.spec.clusterIP}'):8099
export CWB_ADMIN_TOKEN=$(kubectl -n cwb get secret herald-secrets -o jsonpath='{.data.admin_token}' | base64 -d 2>/dev/null)
/tmp/cwb-conform -target dmon -layers all      # all layers GREEN = success
```

Plus a quick liveness sweep: `kubectl get deploy,sts -A` — everything
Ready==Desired, no CrashLoopBackOff.

---

## A. Google Drive consent (device flow) — re-mint Drive access

Google blocks automated browser login, so use the **device flow** (a human
approves a short code on their phone). One-time per recovery:

```sh
# uses the device OAuth client (TV/Limited-Input type) — client id/secret:
python3 - <<'PY'
import json,urllib.request,urllib.parse
c=json.load(open("/path/to/device_client.json"))  # {client_id, client_secret}
b=urllib.parse.urlencode({"client_id":c["client_id"],
  "scope":"https://www.googleapis.com/auth/drive.file"}).encode()
r=json.load(urllib.request.urlopen("https://oauth2.googleapis.com/device/code",b))
print("URL:",r["verification_url"],"CODE:",r["user_code"]); open("/tmp/dev.json","w").write(json.dumps({**r,**c}))
PY
# [HUMAN] open the URL on a phone, enter CODE, approve as the Drive-owning account.
# then poll for the refresh token (grant_type=urn:ietf:params:oauth:grant-type:device_code)
# -> write {client_id,client_secret,refresh_token,token_uri,scope} to /tmp/oauth.json
```

Store the bundle into custodian once it's up:
`cw credential` / grpcurl `CredentialService/SetCredential kind=oauth name=google-drive`.

**Note:** the OAuth app must be **Published** (not Testing) in the Google
console, else the refresh token expires every ~7 days. `drive.file` scope is
non-sensitive, so publishing needs no Google verification.

---

## Reproducibility gaps still open (Layer 2/3)

- ~~Images local-build-only~~ **DONE (Layer 2, 2026-06-12):** all 10 platform
  images publish to GHCR in CI; cluster pulls them. `build-all-images.sh` is
  now the fallback. (nexus broker/aspect images still local-build — follow-up.)
- **Logging stack** (loki/alertmanager) install is not yet captured here.
- **This runbook is not yet end-to-end tested** on a throwaway cluster — that
  drill (Layer 3) is what turns it from "should work" to "watched it work."
  Until then, treat untested steps as needing care.
