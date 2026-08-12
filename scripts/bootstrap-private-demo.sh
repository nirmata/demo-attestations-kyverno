#!/usr/bin/env bash
# Create a small PRIVATE repo in the nirmata org that calls this repo's central
# reusable workflow. That repo's images get attestations from GitHub's private
# Sigstore instance, giving the private-sigstore demo something real to verify.
#
# Why this works with NO policy changes — which is the whole point of the
# central reusable workflow:
#   * signer identity (SAN) = reusable-build-attest.yml in THIS repo, already
#     matched by the policy's subjectRegExp
#   * caller pinning passes: owner id 7470644, caller repo under nirmata/,
#     github-hosted runner
#   * attestations route to GitHub's PRIVATE Sigstore instance because the
#     CALLER repo is private (GHEC required — nirmata is on the enterprise plan)
#
# This creates a repo and pushes to it. Review before running.
#
# Usage: ./scripts/bootstrap-private-demo.sh [REPO_NAME]
set -euo pipefail

REPO_NAME="${1:-demo-private-attestations}"
ORG=nirmata
FULL="${ORG}/${REPO_NAME}"
SOURCE_WORKFLOW="nirmata/demo-attestations-kyverno/.github/workflows/reusable-build-attest.yml@main"

command -v gh >/dev/null || { echo "error: 'gh' is required" >&2; exit 1; }

# PRECONDITION: the central reusable workflow must already be pushed to main of
# the public repo. GitHub resolves `uses: ...@main` against the remote, not your
# working tree — if it is only committed locally, the caller run fails instantly
# (0s, "workflow not found") with a log that is hard to interpret.
REF_PATH=".github/workflows/reusable-build-attest.yml"
if ! gh api "repos/nirmata/demo-attestations-kyverno/contents/${REF_PATH}?ref=main" >/dev/null 2>&1; then
  cat >&2 <<EOF
error: ${REF_PATH} is not on main of nirmata/demo-attestations-kyverno.

  The caller workflow references it as:
    ${SOURCE_WORKFLOW}

  GitHub resolves that against the pushed branch, so the run would fail
  immediately. Commit and push the reusable workflow first:

    git add -A && git commit -m "Add central reusable build-and-attest workflow"
    git push origin main

  Then re-run this script.
EOF
  exit 1
fi

if gh repo view "$FULL" >/dev/null 2>&1; then
  echo "error: $FULL already exists. Pass a different name or delete it first." >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/.github/workflows"

cat > "$WORK/Dockerfile" <<'EOF'
FROM alpine:3.20
ARG IMAGE_TYPE=attested
ENV IMAGE_TYPE=${IMAGE_TYPE}
WORKDIR /app
CMD ["sh", "-c", "echo 'private GHCR demo image (type: $IMAGE_TYPE)'"]
EOF

cat > "$WORK/.github/workflows/ci.yml" <<EOF
# The ENTIRE pipeline for this repo. No build steps, no attest steps — the
# central reusable workflow owns both, and therefore owns the signer identity.
name: CI

on:
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: read
  packages: write
  id-token: write
  attestations: write

jobs:
  build:
    uses: ${SOURCE_WORKFLOW}
    permissions:
      contents: read
      packages: write
      id-token: write
      attestations: write
    with:
      image-name: ${REPO_NAME}
      image-tag: attested
      context: .
      attest-sbom: true

  # Same image with NO attestations, so the policy has something to reject.
  build-unattested:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd  # v6
      - uses: docker/login-action@c94ce9fb468520275223c153574b00df6fe4bcc9  # v3
        with:
          registry: ghcr.io
          username: \${{ github.actor }}
          password: \${{ secrets.GITHUB_TOKEN }}
      - uses: docker/setup-buildx-action@8d2750c68a42422c14e847fe6c8ac0403b4cbd6f  # v3
      - uses: docker/build-push-action@10e90e3645eae34f1e60eeb005ba3a3d33f178e8  # v6
        with:
          context: .
          push: true
          platforms: linux/amd64,linux/arm64
          tags: ghcr.io/${ORG}/${REPO_NAME}:unattested
          build-args: |
            IMAGE_TYPE=unattested
EOF

cat > "$WORK/README.md" <<EOF
# ${REPO_NAME}

Private test repo for the [demo-attestations-kyverno](https://github.com/nirmata/demo-attestations-kyverno)
private-Sigstore demo. Its whole pipeline is a call to that repo's central
reusable workflow; because this repo is private, GitHub routes the attestations
to its private Sigstore instance.
EOF

echo "==> Creating private repo ${FULL}"
gh repo create "$FULL" --private --description "Private test image for the Kyverno private-Sigstore demo" >/dev/null

cd "$WORK"
git init -q -b main
git add -A
git -c user.email=noreply@nirmata.com -c user.name="demo bootstrap" \
  commit -qm "Add private attestation demo calling the central reusable workflow"
git remote add origin "https://github.com/${FULL}.git"
git push -q -u origin main

echo "==> Pushed. Watch the run:"
echo "    gh run watch -R ${FULL}"
echo
echo "Once green, verify the identity is the CENTRAL workflow (not this repo):"
cat <<EOF
    gh attestation verify oci://ghcr.io/${ORG}/${REPO_NAME}:attested -R ${FULL} --format json \\
      | jq -r '.[0].verificationResult.signature.certificate
               | {san: .subjectAlternativeName, buildSignerURI, buildConfigURI}'
EOF
echo
echo "buildSignerURI should be reusable-build-attest.yml; buildConfigURI this repo's ci.yml."
echo
echo "Then point the policy glob at it and test admission:"
echo "    demos/private-sigstore/policies/verify-github-attestations-private.yaml"
echo "    matchImageReferences: ghcr.io/${ORG}/${REPO_NAME}*"
