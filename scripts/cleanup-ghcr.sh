#!/usr/bin/env bash
# Delete ALL versions of a demo package from GHCR.
#
# These are ORGANIZATION packages, so this uses /orgs/{org}/packages/... — the
# /user/packages/... endpoint operates on the authenticated user's own packages
# and silently finds nothing for an org-owned package.
#
# Usage: ./scripts/cleanup-ghcr.sh [PACKAGE] [ORG]
set -euo pipefail

PACKAGE="${1:-demo-github-attestations-sbom}"
ORG="${2:-nirmata}"

command -v gh >/dev/null || { echo "error: 'gh' is required (brew install gh)" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "error: not authenticated — run 'gh auth login'" >&2; exit 1; }

echo "This will DELETE ALL versions of ghcr.io/${ORG}/${PACKAGE}"
read -r -p "Type 'DELETE' to confirm: " CONFIRM
[ "$CONFIRM" = "DELETE" ] || { echo "Cancelled."; exit 0; }

VERSIONS=$(gh api --paginate \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "/orgs/${ORG}/packages/container/${PACKAGE}/versions" \
  --jq '.[].id' 2>/dev/null || echo "")

if [ -z "$VERSIONS" ]; then
  echo "No versions found. Nothing to delete."
  echo "If you expected some, check the package name and that you have"
  echo "'delete:packages' scope: gh auth refresh -s delete:packages"
  exit 0
fi

echo "Found $(echo "$VERSIONS" | wc -l | tr -d ' ') version(s)"
DELETED=0
FAILED=0
for VERSION_ID in $VERSIONS; do
  printf '  %s ... ' "$VERSION_ID"
  if gh api --method DELETE \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "/orgs/${ORG}/packages/container/${PACKAGE}/versions/${VERSION_ID}" >/dev/null 2>&1; then
    echo "deleted"; DELETED=$((DELETED + 1))
  else
    echo "FAILED";  FAILED=$((FAILED + 1))
  fi
done

echo "Deleted: ${DELETED}   Failed: ${FAILED}"
[ "$FAILED" -eq 0 ] || exit 1
