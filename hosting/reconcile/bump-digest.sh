#!/usr/bin/env bash
# Update one image's digest-pinned reference in the manifest that declares
# it, per hosting/reconcile/images.txt. Used by
# .github/workflows/digest-bump.yml -- never pushes directly, the workflow
# opens a PR with whatever this script changes.
#
# Usage: bump-digest.sh <image-name> <new-ref>
#   <image-name>  must match column 1 of images.txt (e.g. "porter-backup")
#   <new-ref>     the full new reference after "ghcr.io/carriedworlduniverse/<image-name>:",
#                 e.g. "sha-1a2b3c4@sha256:deadbeef...64hex"
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
images_file="$repo_root/hosting/reconcile/images.txt"

usage() {
  echo "usage: $(basename "$0") <image-name> <new-ref>" >&2
  exit 2
}

[ $# -eq 2 ] || usage
image_name="$1"
new_ref="$2"

[ -r "$images_file" ] || { echo "bump-digest: missing $images_file" >&2; exit 1; }

target_file=""
while IFS=' ' read -r name file || [ -n "$name" ]; do
  case "$name" in ''|'#'*) continue ;; esac
  if [ "$name" = "$image_name" ]; then
    target_file="$file"
    break
  fi
done <"$images_file"

if [ -z "$target_file" ]; then
  echo "bump-digest: '$image_name' is not in hosting/reconcile/images.txt (add it there first)" >&2
  exit 1
fi

manifest_path="$repo_root/$target_file"
[ -r "$manifest_path" ] || { echo "bump-digest: $manifest_path not found" >&2; exit 1; }

pattern="ghcr\.io/carriedworlduniverse/${image_name}:[^[:space:]\"]*"
if ! grep -Eq "$pattern" "$manifest_path"; then
  echo "bump-digest: no existing 'ghcr.io/carriedworlduniverse/${image_name}:...' reference found in $manifest_path" >&2
  exit 1
fi

replacement="ghcr.io/carriedworlduniverse/${image_name}:${new_ref}"
tmp_file="$(mktemp)"
trap 'rm -f "$tmp_file"' EXIT
sed -E "s#${pattern}#${replacement}#" "$manifest_path" >"$tmp_file"
mv "$tmp_file" "$manifest_path"

echo "bump-digest: updated $target_file -> $replacement"
