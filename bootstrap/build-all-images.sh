#!/usr/bin/env bash
# build-all-images — build every Strata service image from source and import
# into k3s containerd. The platform uses local images (localhost/<svc>:dev,
# imagePullPolicy: Never) — there is no registry, so a fresh host has empty
# containerd and MUST run this before any workload will start.
#
# Run ON the k3s host (dMon), from anywhere. Assumes the service repos are
# cloned under $SRC (default ~/src) and `podman` + `k3s` are installed.
# Each image: podman build -f <containerfile> -t localhost/<img>:dev <repo>,
# then `podman save | k3s ctr images import -`.
#
# Reproducibility note (NEX-625 / Layer 2): publishing these to a registry
# (GHCR) in CI would turn this from "build 14 images" into "pull 14 images".
# Until then, this script is the canonical build path.
set -euo pipefail
SRC="${SRC:-$HOME/src}"
CTR="${CTR:-sudo k3s ctr}"
# podman needs a registries.conf that resolves docker.io for the FROM lines
REG_CONF="$(mktemp)"; printf 'unqualified-search-registries = ["docker.io"]\n' > "$REG_CONF"
export CONTAINERS_REGISTRIES_CONF="$REG_CONF"

# image | repo (under $SRC) | containerfile (relative to repo root)
IMAGES=(
  # --- CWB platform pillars ---
  "herald|herald|cmd/herald/Containerfile"
  "almanac|almanac|cmd/almanac/Containerfile"
  "custodian|custodian|cmd/custodian/Containerfile"
  "cairn|cairn|cmd/cairn-server/Containerfile"
  "commonplace|commonplace|cmd/commonplace/Containerfile"
  "ledger|ledger|cmd/ledger/Containerfile"
  "mason|mason|cmd/mason/Containerfile"
  "interchange-gateway|interchange|cmd/interchange-gateway/Containerfile"
  "porter-backup|porter|cmd/porter-backup/Containerfile"
  # --- apps / workloads ---
  "lynxai|lynxai|Dockerfile"
  "nexus-broker|nexus|deploy/broker/Dockerfile"
  "nexus-builder|nexus|deploy/worker/Dockerfile"
  "nexus-maren|nexus|deploy/maren/Dockerfile"
  "nexus-shadow|nexus|deploy/shadow/Dockerfile"
  "loki-alert-bridge|nexus|deploy/loki-alert-bridge/Dockerfile"
)
# sqld is NOT built here — it is a pulled public image
# (ghcr.io/tursodatabase/libsql-server:latest); gemma images are ollama-pulled.

ONLY="${1:-}"   # optional: build just one image by name
for entry in "${IMAGES[@]}"; do
  IFS='|' read -r img repo cf <<<"$entry"
  [ -n "$ONLY" ] && [ "$ONLY" != "$img" ] && continue
  repo_dir="$SRC/$repo"
  if [ ! -d "$repo_dir" ]; then echo "SKIP $img: $repo_dir not cloned"; continue; fi
  if [ ! -f "$repo_dir/$cf" ]; then echo "SKIP $img: $cf missing in $repo"; continue; fi
  echo "==> building localhost/$img:dev  ($repo / $cf)"
  podman build -q -f "$repo_dir/$cf" -t "localhost/$img:dev" "$repo_dir"
  podman save "localhost/$img:dev" | $CTR images import - >/dev/null
  echo "    imported localhost/$img:dev"
done
rm -f "$REG_CONF"
echo "done. verify: $CTR images ls | grep localhost"
