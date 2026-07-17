# traefik-edge — SWITCH EXECUTED 2026-07-17 ✅

Switch completed 2026-07-17: both wildcard certs issued (LE, expire 2026-10-15,
auto-renew ≥30d before via persisted acme.json), edge live on dMon :443/:80.
Execution gotchas (now baked into these files):
1. k3s-bundled chart DROPS ports.websecure.tls.certResolver/domains — use
   additionalArguments (done in traefik-helmchartconfig.yaml).
2. router.tls:"true" annotation on an Ingress SUPPRESSES the entrypoint TLS
   model → default cert + no ACME. Omit it; websecure inherits TLS.
3. Secret token value must have NO trailing newline (invalid Authorization
   header, lego "failed to find zone"): create the k8s secret from a file
   written with printf '%s', or --from-literal="$(cat file)".
4. First helm-install-traefik job crash-loops once racing the CRD chart, then
   completes — benign, ignore.
5. The k3s restart also cleared cert-manager cainjector's CrashLoopBackOff.

Staged 2026-07-16 by shadow. Turns on the k3s-bundled Traefik as the cluster
edge with a Let's Encrypt wildcard cert (Cloudflare DNS-01) for:

- `*.core.carriedworld.dev`  → core pillars (k8s ns `cwb`)
- `*.nexus.carriedworld.dev` → dev platform (k8s ns `nexus`)
- `carriedworld.com` → the game only; never touched by infra.

**This directory is inert.** `hosting/apply.sh` only globs `clusters/dmon/` and
`hosting/services/*.yaml`; `hosting/staged/` is outside both, so neither CI nor
the periodic reconcile will pick these up. Do not move files into
`hosting/services/` until go-time.

## Files

| file | what |
|---|---|
| `traefik-helmchartconfig.yaml` | HelmChartConfig: ACME DNS-01 (cloudflare) + 2 wildcard SANs on websecure + acme.json persistence |
| `cloudflare-dns-token.secret.example.yaml` | token secret TEMPLATE (create the real one imperatively) |
| `verify-cloudflare-token.sh` | read-only token + zone check — run BEFORE anything else |
| `create-dns-records.sh` | creates `*.core` / `*.nexus` wildcard A → dMon tailnet IP (DNS-only) |
| `ingresses/dashboard.yaml` | phase 2: dashboard on the new name (passkey rpId consequences — read its header) |
| `ingresses/TEMPLATE.yaml` | pattern for exposing further services |

## Prerequisite (operator)

Mint a Cloudflare API token: **Zone→DNS→Edit + Zone→Zone→Read, scoped to
carriedworld.dev only**. Drop at `~/shadow/cloudflare_dns_token` on croft (or
hand to shadow). Then: `./verify-cloudflare-token.sh <token-file>`.

## Known conflicts (why this is staged, not applied)

1. **Port 443 on dMon is owned by `tailscale serve`** (proxies 127.0.0.1:8080 =
   interchange-gateway; :8443 serves ~/Projects/carried-world/web — the game web
   build). When Traefik's LoadBalancer lands, ServiceLB's hostPort DNAT on :443
   will intercept traffic ahead of tailscaled. The interchange is **not
   currently in use** (no real-world exposure — operator, 2026-07-16), so just
   turn the :443 serve off (`tailscale serve --https=443 off`); nothing to
   re-home. Leave the :8443 game-web serve alone.
2. **Re-enabling Traefik = k3s restart** (`--disable=traefik` is baked into
   k3s.service ExecStart). Running pods stay up (containerd is untouched) but
   the API server blips ~10–30s. Don't do it mid-build if the build talks to
   the cluster.
3. **ServiceLB runs on all nodes** — svclb pods for Traefik will also claim
   80/443 on robo-dog. Check nothing on robo-dog holds those ports (or pin the
   LB to dMon with node label `svccontroller.k3s.cattle.io/enablelb=true` on
   dMon only) before enabling.

## Switch runbook (go-time, in order)

```bash
# 0. preflight
./verify-cloudflare-token.sh ~/cloudflare_dns_token          # token + zone OK
ssh robo-dog 'sudo ss -tlnp | grep -E ":(80|443)\b"' || true # robo-dog ports free?

# 1. secret + config BEFORE traefik exists (it reads both at first start)
sudo k3s kubectl -n kube-system create secret generic cloudflare-dns-token \
  --from-literal=token="$(cat ~/cloudflare_dns_token)"
sudo k3s kubectl apply -f traefik-helmchartconfig.yaml

# 2. DNS records (public, DNS-only, point at 100.91.185.71)
./create-dns-records.sh ~/cloudflare_dns_token

# 3. free port 443 on dMon (interchange serve unused; :8443 game-web serve kept)
sudo tailscale serve --https=443 off

# 4. re-enable bundled traefik (k3s restart — API blips, pods keep running)
sudo sed -i "s/'--disable=traefik' \\\\//" /etc/systemd/system/k3s.service   # verify with diff first!
sudo systemctl daemon-reload && sudo systemctl restart k3s

# 5. watch it come up + get the wildcard cert
sudo k3s kubectl -n kube-system get pods -w | grep traefik
sudo k3s kubectl -n kube-system logs deploy/traefik | grep -iE "acme|certificate|error"

# 6. smoke test (any name under the wildcards resolves + terminates TLS)
curl -sv https://test.core.carriedworld.dev 2>&1 | grep -E "subject|issuer|HTTP"
# expect: CN=core.carriedworld.dev (or SAN match), issuer Let's Encrypt, HTTP 404 (no Ingress yet — correct)
```

Phase 2 (separately, deliberately): apply `ingresses/dashboard.yaml`, update
`NEXUS_OPERATOR_RPID`, re-register passkeys (see dashboard.yaml header).
Then per-service Ingresses from TEMPLATE.yaml as wanted.

## Rollback

```bash
sudo k3s kubectl delete -f traefik-helmchartconfig.yaml
# re-add '--disable=traefik' to k3s.service ExecStart, then:
sudo systemctl daemon-reload && sudo systemctl restart k3s
sudo k3s kubectl -n kube-system delete helmchart traefik 2>/dev/null || true
# interchange serve was unused — no :443 serve to restore
```
DNS records can stay (they point at an unroutable-from-internet 100.x IP).

## Deliberately NOT done

- No cert-manager changes (it keeps the internal cwb-ca mTLS job; its
  crash-looping cainjector is a separate fix).
- No mTLS-pillar Ingresses (each needs a client-cert ServersTransport and a
  should-this-be-browser-facing decision).
- No split-DNS. Public wildcard A records chosen for zero new components; swap
  to split-DNS later if the two wildcard names leaking is unacceptable.
