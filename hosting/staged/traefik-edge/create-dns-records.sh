#!/usr/bin/env bash
# Create the wildcard A records for the tailnet edge (idempotent-ish: skips
# records that already exist with the same name).  RUN AT SWITCH TIME, not before.
#
#   *.core.carriedworld.dev  → dMon tailnet IP (DNS-only, never proxied)
#   *.nexus.carriedworld.dev → dMon tailnet IP (DNS-only, never proxied)
#
# These are public records pointing at a CGNAT 100.x address: outsiders can
# resolve the names but cannot route to them. Only the two wildcard labels leak
# — individual service names appear nowhere public (wildcard cert keeps them
# out of CT logs too). If even that is too much, skip this script and use
# tailnet split-DNS instead (needs an internal resolver; see README).
#
# Usage: ./create-dns-records.sh /path/to/token-file
set -euo pipefail

TOKEN="${CF_TOKEN:-$(cat "${1:?usage: $0 <token-file> (or CF_TOKEN=...)}")}"
DMON_TAILNET_IP="100.91.185.71"
API="https://api.cloudflare.com/client/v4"
auth=(-H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json")

zone_id=$(curl -sf "${auth[@]}" "$API/zones?name=carriedworld.dev" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"][0]["id"])')
echo "zone carriedworld.dev = $zone_id"

for name in '*.core.carriedworld.dev' '*.nexus.carriedworld.dev'; do
  existing=$(curl -sf "${auth[@]}" "$API/zones/$zone_id/dns_records?type=A&name=$name" \
    | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["result"]))')
  if [ "$existing" != "0" ]; then
    echo "SKIP $name (already exists)"; continue
  fi
  curl -sf "${auth[@]}" -X POST "$API/zones/$zone_id/dns_records" \
    --data "{\"type\":\"A\",\"name\":\"$name\",\"content\":\"$DMON_TAILNET_IP\",\"ttl\":300,\"proxied\":false}" \
    | python3 -c 'import json,sys; r=json.load(sys.stdin)["result"]; print("CREATED", r["name"], "→", r["content"])'
done
echo "done"
