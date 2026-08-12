#!/usr/bin/env bash
# Fetch GitHub's Sigstore trusted root and load it into a ConfigMap that the
# Kyverno ImageValidatingPolicies reference via `cosign.trustedRoot`.
#
# `gh attestation trusted-root` emits JSONL: one trusted root per line. It
# contains BOTH the Sigstore Public Good root and GitHub's own instance root.
# Kyverno's `trustedRoot.value` takes a single TrustedRoot JSON document, so we
# select the GitHub one (certificate authorities under *.githubapp.com).
#
# Usage: ./fetch-trusted-root.sh [KYVERNO_NAMESPACE]
set -euo pipefail

NAMESPACE="${1:-kyverno}"
OUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/trusted-root"
OUT_FILE="${OUT_DIR}/github-trusted-root.json"

for cmd in gh jq kubectl; do
  command -v "$cmd" >/dev/null || { echo "error: '$cmd' is required" >&2; exit 1; }
done

mkdir -p "$OUT_DIR"

echo "==> Fetching trusted roots via 'gh attestation trusted-root'"
gh attestation trusted-root \
  | jq -c 'select([.certificateAuthorities[]?.uri] | any(test("githubapp\\.com")))' \
  > "$OUT_FILE"

LINES=$(wc -l < "$OUT_FILE" | tr -d ' ')
if [ "$LINES" != "1" ]; then
  echo "error: expected exactly 1 GitHub trusted root, got ${LINES}." >&2
  echo "       Inspect 'gh attestation trusted-root' output manually." >&2
  exit 1
fi

echo "==> Validating trusted root shape"
jq -e '
  .mediaType == "application/vnd.dev.sigstore.trustedroot+json;version=0.1"
  and ((.certificateAuthorities | length) > 0)
  and ((.timestampAuthorities // []) | length) > 0
' "$OUT_FILE" >/dev/null || {
  echo "error: unexpected trusted root contents in ${OUT_FILE}" >&2
  exit 1
}

jq -r '
  "    media type : \(.mediaType)",
  "    fulcio CAs : \([.certificateAuthorities[].uri] | unique | join(", ")) (\(.certificateAuthorities|length))",
  "    TSAs       : \([.timestampAuthorities[].uri] | unique | join(", ")) (\(.timestampAuthorities|length))",
  "    rekor logs : \((.tlogs // []) | length)   ct logs: \((.ctlogs // []) | length)"
' "$OUT_FILE"

echo "==> Writing ConfigMap 'github-trusted-root' in namespace '${NAMESPACE}'"
kubectl create configmap github-trusted-root \
  --namespace "$NAMESPACE" \
  --from-file=trusted_root.json="$OUT_FILE" \
  --dry-run=client -o yaml | kubectl apply -f -

echo
echo "Done. Saved to ${OUT_FILE}"
echo "NOTE: GitHub rotates this key material a few times per year."
echo "      Re-run this script after a rotation, or verification will start failing."
