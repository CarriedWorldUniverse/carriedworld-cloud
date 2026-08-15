# dMon host state (k3s control-plane)

Captured host configuration, mirroring the convention in `hosts/robo-dog/`.
Nothing here is applied by `reconcile.sh` — that loop drives Kubernetes objects
only. These files exist so host state is reviewable in git rather than living
only on one laptop's disk. **Change the host and this directory in the same PR.**

## `k3s-config.yaml`

Capture of `/etc/rancher/k3s/config.yaml`. See the comments in that file for the
2026-08-16 flannel/Tailscale incident and why `flannel-iface: tailscale0` must be
set on both dMon and robo-dog.

## CoreDNS replicas — UNMANAGED, and it will be silently reverted

CoreDNS runs **2 replicas** (one per node) as of 2026-08-16. Before that it was a
single replica on dMon, which is why the flannel partition took DNS away from
robo-dog entirely instead of degrading: every pod there lost name resolution
while the one CoreDNS pod sat unreachable on the other side of a dead tunnel.
With one replica per node, the same partition costs only cross-node lookups.

k3s ships CoreDNS as a **packaged addon** with no `replicas` field, defaulting to
1. A live `kubectl scale` does not survive: the addon controller reconciles the
Deployment back. The replica count was therefore set by editing the packaged
manifest in place on dMon:

```
/var/lib/rancher/k3s/server/manifests/coredns.yaml   # spec.replicas: 2 added
```

Backup of the original: `/root/coredns.yaml.bak` on dMon.

**A k3s upgrade ships a fresh `coredns.yaml` and will overwrite this file,**
dropping you back to one replica with no warning and no drift alert — reconcile
cannot see it, because the file is on the host, not in the cluster. After any k3s
upgrade, re-add under the Deployment's `spec:` and confirm:

```bash
sudo kubectl -n kube-system get deploy coredns -o jsonpath='{.spec.replicas}'   # want 2
sudo kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide                # want 1/node
```

No affinity rules are needed — the shipped CoreDNS Deployment already carries a
`maxSkew: 1` / `DoNotSchedule` topology spread on `kubernetes.io/hostname`, so
the second replica is forced onto the other node.

**Worth fixing properly.** A host-file edit that an upgrade reverts is the same
class of problem as the drift this repo exists to prevent. The durable options
are a `coredns-custom` overlay or self-managing CoreDNS (`--disable coredns` plus
our own manifest under `clusters/dmon/`), which would put the replica count under
reconcile where a revert would be caught. Neither was done here because both
change how a critical cluster component is owned, which deserves its own change.
