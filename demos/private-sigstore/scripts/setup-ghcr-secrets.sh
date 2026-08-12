#!/usr/bin/env bash
# Create the GHCR pull secrets needed for the private-image demo.
#
# Two secrets are needed, in two different places:
#   1. Kyverno's namespace  — so the admission controller can pull the image
#      manifest and its attestations during verification
#      (referenced by spec.credentials.secrets in the policies).
#   2. The workload namespace — so the kubelet can pull the image itself
#      (referenced by pod.spec.imagePullSecrets).
#
# Usage:
#   GITHUB_USER=<your-github-username> GITHUB_TOKEN=<PAT with read:packages> \
#     ./setup-ghcr-secrets.sh [WORKLOAD_NAMESPACE] [KYVERNO_NAMESPACE]
set -euo pipefail

WORKLOAD_NS="${1:-default}"
KYVERNO_NS="${2:-kyverno}"
: "${GITHUB_USER:?set GITHUB_USER to your GitHub username}"
: "${GITHUB_TOKEN:?set GITHUB_TOKEN to a PAT with the read:packages scope}"

command -v kubectl >/dev/null || { echo "error: 'kubectl' is required" >&2; exit 1; }

create_secret() {
  local ns="$1" name="$2"
  echo "==> Creating secret '${name}' in namespace '${ns}'"
  kubectl create secret docker-registry "$name" \
    --namespace "$ns" \
    --docker-server=ghcr.io \
    --docker-username="$GITHUB_USER" \
    --docker-password="$GITHUB_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -
}

create_secret "$KYVERNO_NS"  ghcr-pull-secret
create_secret "$WORKLOAD_NS" ghcr-pull-secret

echo
echo "Done."
echo "  Kyverno reads:  ${KYVERNO_NS}/ghcr-pull-secret   (spec.credentials.secrets)"
echo "  Kubelet reads:  ${WORKLOAD_NS}/ghcr-pull-secret  (pod.spec.imagePullSecrets)"
