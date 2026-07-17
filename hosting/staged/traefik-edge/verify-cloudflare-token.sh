#!/usr/bin/env bash
# Verify a Cloudflare API token before it goes anywhere near the cluster.
# Usage: ./verify-cloudflare-token.sh /path/to/token-file   (or set CF_TOKEN)
# Read-only. Changes nothing.
#
# Note: account-owned tokens (cfat_ prefix) are NOT accepted by
# /user/tokens/verify (401 there is expected) — the zone check below is the
# authoritative test either way.
set -euo pipefail

TOKEN="${CF_TOKEN:-$(cat "${1:?usage: $0 <token-file> (or CF_TOKEN=...)}")}"
API="https://api.cloudflare.com/client/v4"
auth=(-H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json")

echo "== token validity =="
vr=$(curl -s "${auth[@]}" "$API/user/tokens/verify" || true)
if echo "$vr" | grep -q '"success":true'; then
  echo "$vr" | python3 -c 'import json,sys; r=json.load(sys.stdin)["result"]; print("status:", r["status"], " expires:", r.get("expires_on","never"))'
else
  echo "user-token verify N/A (account-owned token?) — zone check below is authoritative"
fi

echo "== zones + permissions visible to this token =="
curl -sf "${auth[@]}" "$API/zones?per_page=50" \
  | python3 -c '
import json,sys
zones = json.load(sys.stdin)["result"]
for z in zones:
    print("  %-24s id=%s  status=%s" % (z["name"], z["id"], z["status"]))
    print("    perms: " + ", ".join(z.get("permissions", [])))
names = {z["name"] for z in zones}
if "carriedworld.dev" not in names:
    print("MISSING required zone: carriedworld.dev"); sys.exit(1)
z = next(z for z in zones if z["name"] == "carriedworld.dev")
need = {"#dns_records:edit", "#zone:read"}
missing = need - set(z.get("permissions", []))
if missing:
    print("MISSING permissions on carriedworld.dev:", ", ".join(sorted(missing))); sys.exit(1)
print("OK: carriedworld.dev visible with dns_records:edit + zone:read")
'
echo "== verify passed =="
