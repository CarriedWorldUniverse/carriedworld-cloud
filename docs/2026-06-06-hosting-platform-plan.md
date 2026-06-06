# Hosting Platform v1 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A declarative hosting layer over the dMon k3s cluster where a service is described once and lands fully configured — named, networked, storage-attached, identity-provisioned — assembled from k3s/CoreDNS/Tailscale-operator/custodian, reconciled from `carriedworld-cloud` (no evaporating patches).

**Architecture:** A Helm "hosting convention" chart renders each service (Deployment/StatefulSet + ClusterIP Service + PVC + identity init-container). A single cluster-level `coredns-custom` ConfigMap rewrites each service's tailnet name to its in-cluster Service (the naming keystone — kills per-pod hostAliases). CI renders+applies on merge (push GitOps-lite). Existing services are retrofitted onto the convention.

**Tech Stack:** Helm 3, k3s (CoreDNS via `coredns-custom`, k3s `HelmChart`/auto-apply), the Tailscale Kubernetes operator (already installed), cw + custodian (identity/creds), GitHub Actions (apply-on-merge).

**Spec:** `carriedworld-cloud/docs/2026-06-06-hosting-platform-design.md`.

**Repo:** all work lands in `carriedworld-cloud` (cloned on dMon at `~/carriedworld-cloud`; clone via `gh repo clone` — private). Apply against the dMon cluster with `sudo kubectl` / `sudo helm` (kubeconfig at `/etc/rancher/k3s/k3s.yaml`).

---

## Phase 0 — Spikes (resolve unknowns before building)

These are throwaway verifications. Each ends by recording the result in the plan/PR; nothing is committed except notes.

### Task 0.1: Verify `coredns-custom` rewrite resolves a tailnet name to a ClusterIP in-cluster

**Why:** the entire naming keystone depends on CoreDNS rewriting `<svc>.tail41686e.ts.net` → the in-cluster Service. Confirm the mechanism on *this* k3s before designing the chart around it.

- [ ] **Step 1: Inspect the current CoreDNS setup**

Run: `ssh jacinta@100.91.185.71 'sudo kubectl get cm -n kube-system coredns coredns-custom -o yaml 2>&1 | head -60'`
Expected: the `coredns` ConfigMap exists; `coredns-custom` may or may not exist yet (k3s supports it; keys ending `.server`/`.override` are merged into CoreDNS).

- [ ] **Step 2: Add a test rewrite via `coredns-custom`**

Create `coredns-custom` with an `.override` entry rewriting the live broker name to its Service:
```
ssh jacinta@100.91.185.71 'cat <<EOF | sudo kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata: { name: coredns-custom, namespace: kube-system }
data:
  nexus.override: |
    rewrite name nexus.tail41686e.ts.net nexus-broker.nexus.svc.cluster.local
EOF'
```
Then restart CoreDNS: `ssh ... 'sudo kubectl -n kube-system rollout restart deploy/coredns && sudo kubectl -n kube-system rollout status deploy/coredns --timeout=60s'`

- [ ] **Step 3: Verify a throwaway in-cluster pod resolves the name to the ClusterIP with full TLS**

Run (mirrors the cutover `tlstest`):
```
ssh jacinta@100.91.185.71 'sudo kubectl run dnsspike --rm -i --restart=Never --image=curlimages/curl -n nexus --command -- sh -c "nslookup nexus.tail41686e.ts.net 2>&1 | tail -4; curl -sS -o /dev/null -w \"http=%{http_code} ssl=%{ssl_verify_result}\n\" --max-time 10 https://nexus.tail41686e.ts.net:7888/"'
```
Expected: name resolves to the broker ClusterIP (10.43.138.250), `http=302 ssl=0` (valid cert).

- [ ] **Step 4: Record the result and remove the test rewrite**

If it works → the chart strategy is "single cluster `coredns-custom` ConfigMap, one rewrite per hosted service." If `rewrite` doesn't behave (e.g. needs `answer name` to rewrite the response too), record the exact working directive. Then delete the spike ConfigMap entry (the real one is built in Phase 2): `ssh ... 'sudo kubectl delete cm coredns-custom -n kube-system'`.

### Task 0.2: Determine the identity-provisioning capability gap

**Why:** Phase 5 (identity brokering) needs custodian to serve an aspect's keyfile to the cw init-container. Confirm what exists vs what must be built, so Phase 5 is scoped honestly.

- [ ] **Step 1: Check whether cw can fetch an aspect keyfile / identity**

Run: `ssh jacinta@100.91.185.71 'ls /usr/local/bin/cw && /usr/local/bin/cw --help 2>&1 | grep -iE "keyfile|identity|credential|bootstrap"; /tmp/cw-src 2>/dev/null; gh repo clone CarriedWorldUniverse/cw /tmp/cw-inspect 2>/dev/null; grep -rniE "keyfile|DeriveAgentKey|bootstrap|mint" /tmp/cw-inspect --include=*.go 2>/dev/null | grep -vi test | head'`
Expected: discover whether cw exposes any keyfile/identity fetch. Likely **no** — keyfiles are minted out-of-band (`nexus aspect mint`) and mounted as `aspect-keyfile-*` secrets.

- [ ] **Step 2: Record the decision**

If cw cannot fetch/derive a keyfile today → Phase 5 is gated on new custodian/herald work (the herald-rooted bootstrap). Record: **v1 ships with platform-declared keyfile secrets (Phase 4); identity-brokering (Phase 5) is a separate increment** unless the operator wants the custodian work pulled in now. Note the gap in the PR and stop Phase 5 at the keyfile-secret boundary.

---

## Phase 1 — The hosting convention chart (no cluster changes yet)

Build and unit-test the Helm chart in isolation. Model the rendered objects on the proven `nexus/deploy/broker/deployment.yaml` (3-container pod, PVC, secret env) and `nexus/deploy/dispatch-controller/deployment.yaml`.

### Task 1.1: Scaffold the chart

**Files:**
- Create: `carriedworld-cloud/hosting/chart/Chart.yaml`
- Create: `carriedworld-cloud/hosting/chart/values.yaml`
- Create: `carriedworld-cloud/hosting/chart/templates/_helpers.tpl`

- [ ] **Step 1: Write `Chart.yaml`**
```yaml
apiVersion: v2
name: hosted-service
description: Carried World hosting convention — one service, hosted right.
type: application
version: 0.1.0
```

- [ ] **Step 2: Write `values.yaml` (the declaration surface + safe defaults)**
```yaml
# Identity of the hosted service.
name: ""                 # required; becomes the Deployment/Service name
namespace: nexus
kind: Deployment         # Deployment | StatefulSet
image: ""                # required
imagePullPolicy: Never   # images are k3s-ctr-imported, not pulled
command: []
args: []
env: []                  # list of {name,value} or {name,valueFrom}
envFromSecret: ""        # optional: name of a Secret to envFrom
replicas: 1
port: 0                  # 0 = no Service/port

# Block storage (k8s-native). Empty = none.
storage:
  size: ""               # e.g. "5Gi"; empty disables the PVC
  mountPath: ""

# Tailnet edge (Tailscale operator). When true, the service is exposed on
# the tailnet AND a coredns rewrite is expected (see clusters/dmon/coredns-custom).
tailnetEdge: false
tailnetName: ""          # e.g. nexus.tail41686e.ts.net

# Identity: how the pod gets its keyfile + scoped creds.
# v1: "secret" (mount aspect-keyfile-<name>, platform-declared).
# later: "custodian" (cw init-container fetches at startup).
identity:
  mode: secret           # secret | custodian
  keyfileSecret: ""      # used when mode=secret
  setupGitHost: ""       # "github" => init runs `cw setup-git github`
```

- [ ] **Step 3: Write `_helpers.tpl` (name + label helpers)**
```yaml
{{- define "hosted.fullname" -}}{{ required "name is required" .Values.name }}{{- end -}}
{{- define "hosted.labels" -}}
app.kubernetes.io/name: {{ include "hosted.fullname" . }}
app.kubernetes.io/managed-by: hosting-platform
app: {{ include "hosted.fullname" . }}
{{- end -}}
```

- [ ] **Step 4: Verify the chart lints**

Run: `ssh jacinta@100.91.185.71 'cd ~/carriedworld-cloud && helm lint hosting/chart --set name=spike --set image=busybox 2>&1 | tail -5'`
Expected: `1 chart(s) linted, 0 chart(s) failed`.

- [ ] **Step 5: Commit**
```bash
git add hosting/chart/Chart.yaml hosting/chart/values.yaml hosting/chart/templates/_helpers.tpl
git commit -m "hosting: scaffold the hosted-service convention chart"
```

### Task 1.2: Workload + Service + PVC templates

**Files:**
- Create: `carriedworld-cloud/hosting/chart/templates/workload.yaml`
- Create: `carriedworld-cloud/hosting/chart/templates/service.yaml`
- Create: `carriedworld-cloud/hosting/chart/templates/pvc.yaml`

- [ ] **Step 1: Write `workload.yaml`** — a Deployment or StatefulSet (per `.Values.kind`) with the main container (image/command/args/env/envFromSecret), the data volume mount when `storage.size` is set, and the keyfile secret mount when `identity.mode=secret`. Mirror `nexus/deploy/broker/deployment.yaml`'s container/volume shape. Use `{{- if eq .Values.kind "StatefulSet" }}` to branch. Include the identity init-container only when `identity.mode=custodian` (Phase 5 fills its body; render an empty/no-op guard for now).

- [ ] **Step 2: Write `service.yaml`** — render a ClusterIP Service only when `.Values.port > 0`:
```yaml
{{- if gt (int .Values.port) 0 }}
apiVersion: v1
kind: Service
metadata: { name: {{ include "hosted.fullname" . }}, namespace: {{ .Values.namespace }}, labels: {{- include "hosted.labels" . | nindent 4 }} }
spec:
  type: ClusterIP
  selector: { app: {{ include "hosted.fullname" . }} }
  ports: [ { name: svc, port: {{ .Values.port }}, targetPort: {{ .Values.port }} } ]
{{- end }}
```

- [ ] **Step 3: Write `pvc.yaml`** — render a PVC only when `.Values.storage.size` is set (ReadWriteOnce, the declared size).

- [ ] **Step 4: Render-test against a sample**

Run: `ssh jacinta@100.91.185.71 'cd ~/carriedworld-cloud && helm template t hosting/chart --set name=sample --set image=busybox --set port=8080 --set storage.size=1Gi --set storage.mountPath=/data 2>&1 | grep -E "kind:|name:|claimName:|port:" | head -20'`
Expected: a Deployment, a Service (port 8080), and a PVC are rendered; no template errors.

- [ ] **Step 5: Commit**
```bash
git add hosting/chart/templates/workload.yaml hosting/chart/templates/service.yaml hosting/chart/templates/pvc.yaml
git commit -m "hosting: workload + service + pvc templates"
```

### Task 1.3: Tailnet-edge exposure template

**Files:**
- Create: `carriedworld-cloud/hosting/chart/templates/tailscale.yaml`

- [ ] **Step 1: Write `tailscale.yaml`** — when `.Values.tailnetEdge`, render the Tailscale operator exposure for the Service (per the operator's current API: a `Service` annotation `tailscale.com/expose: "true"` + `tailscale.com/hostname`, or an `Ingress` with `ingressClassName: tailscale` — confirm the installed operator's supported form with `ssh ... 'sudo kubectl get crd | grep tailscale'` and the operator docs, and use whichever the installed version supports). Guard the whole file behind `{{- if .Values.tailnetEdge }}`.

- [ ] **Step 2: Render-test** with `--set tailnetEdge=true --set tailnetName=sample.tail41686e.ts.net`; assert the exposure object renders. Run helm template and grep for the tailscale annotation/ingress.

- [ ] **Step 3: Commit** `hosting: optional tailnet-edge exposure template`.

---

## Phase 2 — Naming keystone (cluster `coredns-custom`)

### Task 2.1: Establish the cluster coredns-custom ConfigMap

**Files:**
- Create: `carriedworld-cloud/clusters/dmon/coredns-custom.yaml`

- [ ] **Step 1: Write the ConfigMap** using the directive form validated in Task 0.1 — one rewrite per hosted service that has a tailnet name. Start with the broker (already live):
```yaml
apiVersion: v1
kind: ConfigMap
metadata: { name: coredns-custom, namespace: kube-system }
data:
  hosting.override: |
    rewrite name nexus.tail41686e.ts.net nexus-broker.nexus.svc.cluster.local
```

- [ ] **Step 2: Apply + restart CoreDNS**

Run: `ssh jacinta@100.91.185.71 'cd ~/carriedworld-cloud && sudo kubectl apply -f clusters/dmon/coredns-custom.yaml && sudo kubectl -n kube-system rollout restart deploy/coredns && sudo kubectl -n kube-system rollout status deploy/coredns --timeout=60s'`

- [ ] **Step 3: Integration test — in-cluster resolution + valid TLS**

Run the `dnsspike` pod from Task 0.1 Step 3. Expected: `http=302 ssl=0`. This is the keystone acceptance: an in-cluster pod reaches the broker by tailnet name with no hostAlias.

- [ ] **Step 4: Commit** `hosting: cluster coredns-custom — tailnet names resolve in-cluster (naming keystone)`.

---

## Phase 3 — Reconcile (apply-on-merge)

### Task 3.1: Apply script + CI workflow

**Files:**
- Create: `carriedworld-cloud/hosting/apply.sh`
- Create: `carriedworld-cloud/hosting/services/` (dir; per-service values files land here)
- Create: `carriedworld-cloud/.github/workflows/apply.yml`

- [ ] **Step 1: Write `apply.sh`** — for each `hosting/services/*.values.yaml`, `helm template <name> hosting/chart -f <file> | kubectl apply -f -`; then `kubectl apply -f clusters/dmon/`. Idempotent; exits non-zero on any apply error.

- [ ] **Step 2: Verify `apply.sh` locally on dMon** with a sample values file (apply a `sample` service, confirm it comes up, delete it).

- [ ] **Step 3: Write `.github/workflows/apply.yml`** — on push to `main`, run `apply.sh` against the dMon cluster via the self-hosted dMon runner (the nexus repo already uses a self-hosted dMon runner — reuse it; it has cluster access). If no runner is wired for this repo yet, add a task to register one, or fall back to a periodic `apply.sh` CronJob in-cluster (record which).

- [ ] **Step 4: Commit** `hosting: apply-on-merge reconcile (apply.sh + CI)`.

### Task 3.2: Periodic re-apply safety net

**Files:**
- Create: `carriedworld-cloud/clusters/dmon/hosting-reapply-cronjob.yaml`

- [ ] **Step 1: Write a CronJob** (e.g. every 15m) that git-pulls `carriedworld-cloud` and runs `apply.sh` — the drift safety net until Flux. Use a ServiceAccount scoped to apply in `nexus`/`cwb`/`kube-system`.
- [ ] **Step 2: Apply + verify one run succeeds** (`kubectl create job --from=cronjob/...`, check logs).
- [ ] **Step 3: Commit** `hosting: periodic re-apply CronJob (drift safety net)`.

---

## Phase 4 — Retrofit existing services (the big win)

For each service: write `hosting/services/<svc>.values.yaml`, render it, **delete the live hand-applied objects + patches**, apply via the convention, and run the acceptance test (delete + re-apply → identical & connected). Do them in increasing risk order.

### Task 4.1: Retrofit `sqld` (simplest — proves the convention)

**Files:** Create `carriedworld-cloud/hosting/services/sqld.values.yaml`

- [ ] **Step 1:** Write the values capturing sqld's current real config (image, port 8080, the `/var/lib/sqld` PVC, env). Compare against the live Deployment: `ssh ... 'sudo kubectl get deploy sqld -n cwb -o yaml'`.
- [ ] **Step 2:** Render + diff against the live object (`helm template ... | kubectl diff -f -`); reconcile differences into the values until the diff is empty-or-intended.
- [ ] **Step 3:** Apply via `apply.sh`; confirm sqld rolls without disruption (`kubectl rollout status`, broker still reads it).
- [ ] **Step 4 (acceptance):** `kubectl delete deploy sqld -n cwb` → `apply.sh` → assert sqld returns and the broker reconnects (broker logs show storage healthy). Zero manual patches.
- [ ] **Step 5:** Commit `hosting: retrofit sqld onto the convention`.

### Task 4.2: Retrofit `dispatch-controller` (biggest payoff — its config stops evaporating)

**Files:** Create `carriedworld-cloud/hosting/services/dispatch-controller.values.yaml`

- [ ] **Step 1:** Capture the *current live-patched* config into values: args `-k /etc/nexus/keyfile.json -namespace nexus -max-concurrent 4 -node-ip 10.43.138.250 -broker-host nexus.tail41686e.ts.net`, env `CW_SEAM_URL=https://nexus.tail41686e.ts.net:7888`, the `aspect-keyfile-dispatch-controller` secret, the RBAC (ServiceAccount/Role/RoleBinding from `nexus/deploy/dispatch-controller/deployment.yaml`). The hostAlias is replaced by the Phase-2 coredns rewrite — drop it.
- [ ] **Step 2:** Render + `kubectl diff`; reconcile.
- [ ] **Step 3:** Apply; confirm the controller reconnects (`wsasp: register acknowledged`).
- [ ] **Step 4 (acceptance):** delete + re-apply → identical & connected, **no `kubectl patch`** — this is the proof the evaporating-config problem is solved.
- [ ] **Step 5:** Commit `hosting: retrofit dispatch-controller (config no longer evaporates)`.

### Task 4.3: Retrofit `broker`

**Files:** Create `carriedworld-cloud/hosting/services/nexus-broker.values.yaml`

- [ ] **Step 1:** Capture the broker's 3-container shape from `nexus/deploy/broker/deployment.yaml` (tailscale sidecar + cert + broker, the `broker-tls`/`nexus-broker-env` secrets, the pinned ClusterIP 10.43.138.250, the `nexus-broker-data` PVC). NOTE: the broker is the multi-container/sidecar case — confirm the convention chart can express the extra containers (it may need a `extraContainers` values passthrough; add it to the chart if so, with a render test). The broker keeps its tailscale sidecar (it owns the `nexus` tailnet identity); `tailnetEdge` here documents that.
- [ ] **Step 2:** Render + `kubectl diff` against live; reconcile (the live broker must keep serving — use `kubectl diff` to ensure no destructive change).
- [ ] **Step 3:** Apply (Recreate strategy already); confirm aspects stay/reconnect.
- [ ] **Step 4 (acceptance):** delete + re-apply at a safe window → broker returns, cert re-provisions, aspects reconnect, `dnsspike` still passes.
- [ ] **Step 5:** Commit `hosting: retrofit broker onto the convention`.

### Task 4.4: Retrofit `keel`

**Files:** Create `carriedworld-cloud/hosting/services/keel.values.yaml`

- [ ] **Step 1:** Capture keel from `nexus/deploy/keel/deployment.yaml` (agentfunnel, gemma env, the `aspect-keyfile-keel` secret, hostAlias→coredns rewrite replacement).
- [ ] **Step 2:** Render + diff; reconcile.
- [ ] **Step 3:** Apply; confirm keel re-registers (`provider=openai model=gemma`).
- [ ] **Step 4 (acceptance):** delete + re-apply → keel returns connected.
- [ ] **Step 5:** Commit `hosting: retrofit keel onto the convention`.

---

## Phase 5 — Identity brokering (gated on Task 0.2)

**Only proceed if Task 0.2 found cw/custodian can serve an aspect keyfile, OR the operator pulls the custodian work in.** Otherwise stop here — v1 ships with Phase-4 declared keyfile secrets, and this phase becomes its own follow-on plan.

### Task 5.1: Extend custodian to broker an aspect keyfile (dependency)

- [ ] Scope + implement (in the relevant repo, likely nexus/custodian + cw): a way for an authenticated pod to fetch *its own* aspect keyfile + scoped creds from custodian at startup (ties to the herald-rooted bootstrap). This is a separate design if non-trivial — flag to the operator before building.

### Task 5.2: The cw identity init-container

**Files:** Modify `carriedworld-cloud/hosting/chart/templates/workload.yaml`

- [ ] **Step 1:** Fill the `identity.mode=custodian` init-container: runs cw to fetch the keyfile + creds into a shared `emptyDir` (`/etc/nexus`), plus `cw setup-git <host>` when `identity.setupGitHost` is set; main container reads from the volume.
- [ ] **Step 2:** Unit/render test: with `identity.mode=custodian`, the init-container renders with the right cw command + shared volume; with `mode=secret`, it does not.
- [ ] **Step 3:** Integration: flip one retrofitted service (keel) to `mode=custodian`; assert it starts with a custodian-fetched identity (init-container logs show the fetch; keel registers). Fail-fast check: break the auth, assert the init-container exits non-zero and the pod doesn't start half-configured.
- [ ] **Step 4:** Commit `hosting: custodian-brokered identity injector`.

---

## Scope boundary (NOT in this plan)

GPU scheduling; brokered DB/object-store connections; Flux/pull-reconcile (CI-on-merge + CronJob stand in); multi-cluster. The dispatch resource-cleanup gap (NEX-461) is orthogonal.
