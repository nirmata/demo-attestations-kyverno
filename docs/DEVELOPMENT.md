# Development Guide

This document covers setup, building, and troubleshooting for the cosign testbed repository.

## Setup Instructions

### Prerequisites

- Docker
- cosign (for local testing)
- GitHub CLI (`gh`) - optional, for cleanup

### 1. Generate Cosign Key Pair

Use the provided helper script:

```bash
./setup-cosign-keys.sh
```

Or manually:

```bash
cosign generate-key-pair
```

This creates:
- `cosign.key` (private key) - **NEVER commit this!**
- `cosign.pub` (public key) - safe to commit

You'll be prompted to set a password for the private key.

### 2. Add GitHub Secrets

Add the following secrets to your GitHub repository:

**Settings → Secrets and variables → Actions → New repository secret**

#### `COSIGN_PRIVATE_KEY`
Copy the entire contents of `cosign.key`:

```bash
cat cosign.key
```

Include the full PEM block:
```
-----BEGIN ENCRYPTED COSIGN PRIVATE KEY-----
...
-----END ENCRYPTED COSIGN PRIVATE KEY-----
```

#### `COSIGN_PASSWORD`
The password you set when generating the key pair.

### 3. Commit Public Key (Optional)

```bash
git add cosign.pub
git commit -m "Add cosign public key for verification"
```

### 4. Push and Run Workflow

```bash
git push
```

The CI workflow will:
1. 🗑️ **Clean up** all existing image versions from GHCR
2. 🔨 **Build and push** 7 fresh images in parallel
3. ✍️ **Sign** the images with appropriate cosign versions and methods

## Kyverno Policy Examples

### Key-Based Verification

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-cosign-key-based
spec:
  validationFailureAction: Enforce
  rules:
    - name: verify-v2-traditional
      match:
        any:
        - resources:
            kinds:
            - Pod
      verifyImages:
      - imageReferences:
        - "ghcr.io/nirmata/demo-github-attestations-sbom:v2-traditional"
        attestors:
        - entries:
          - keys:
              publicKeys: |-
                -----BEGIN PUBLIC KEY-----
                <YOUR_COSIGN_PUB_CONTENT>
                -----END PUBLIC KEY-----
    
    - name: verify-v3-bundle
      match:
        any:
        - resources:
            kinds:
            - Pod
      verifyImages:
      - imageReferences:
        - "ghcr.io/nirmata/demo-github-attestations-sbom:v3-bundle"
        attestors:
        - entries:
          - keys:
              publicKeys: |-
                -----BEGIN PUBLIC KEY-----
                <YOUR_COSIGN_PUB_CONTENT>
                -----END PUBLIC KEY-----
```

### Keyless Verification

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-cosign-keyless
spec:
  validationFailureAction: Enforce
  rules:
    - name: verify-v2-keyless
      match:
        any:
        - resources:
            kinds:
            - Pod
      verifyImages:
      - imageReferences:
        - "ghcr.io/nirmata/demo-github-attestations-sbom:v2-keyless"
        attestors:
        - entries:
          - keyless:
              subject: "https://github.com/nirmata/demo-attestations-kyverno/.github/workflows/reusable-build-attest.yml@refs/heads/main"
              issuer: "https://token.actions.githubusercontent.com"
              rekor:
                url: https://rekor.sigstore.dev
    
    - name: verify-v3-keyless
      match:
        any:
        - resources:
            kinds:
            - Pod
      verifyImages:
      - imageReferences:
        - "ghcr.io/nirmata/demo-github-attestations-sbom:v3-keyless"
        attestors:
        - entries:
          - keyless:
              subject: "https://github.com/nirmata/demo-attestations-kyverno/.github/workflows/reusable-build-attest.yml@refs/heads/main"
              issuer: "https://token.actions.githubusercontent.com"
              rekor:
                url: https://rekor.sigstore.dev
```

## Inspecting Signature Artifacts

### View Signature Manifests in Registry

```bash
# List all tags including .sig images
crane ls ghcr.io/nirmata/demo-github-attestations-sbom

# Inspect a specific signature manifest
cosign tree ghcr.io/nirmata/demo-github-attestations-sbom:v3-traditional
```

### Check Rekor Transparency Log (for keyless signatures)

```bash
# Search for signatures in Rekor
rekor-cli search --artifact ghcr.io/nirmata/demo-github-attestations-sbom:v2-keyless

# View specific Rekor entry
rekor-cli get --uuid <uuid-from-search>
```

### Inspect Fulcio Certificates (for keyless signatures)

```bash
# Verify and show certificate details
cosign verify \
  --certificate-identity=https://github.com/nirmata/demo-attestations-kyverno/.github/workflows/reusable-build-attest.yml@refs/heads/main \
  --certificate-oidc-issuer=https://token.actions.githubusercontent.com \
  ghcr.io/nirmata/demo-github-attestations-sbom:v2-keyless | jq
```

## Local Testing

### Build Image Locally

For local testing on the native platform:

```bash
docker build -t test-image:local .
```

For multi-platform builds (requires Docker Buildx):

```bash
# Build for both amd64 and arm64
docker buildx build --platform linux/amd64,linux/arm64 -t test-image:local .
```

### Generate Test Key Pair

```bash
cosign generate-key-pair
```

### Sign with Different Formats

```bash
# Traditional key-based signing (by tag)
cosign sign --key cosign.key test-image:local

# Key-based signing by digest (recommended for multi-platform images)
IMAGE_DIGEST=$(docker inspect test-image:local --format='{{index .RepoDigests 0}}' | cut -d'@' -f2)
cosign sign --key cosign.key test-image@${IMAGE_DIGEST}

# Keyless signing (requires OIDC provider)
cosign sign test-image:local
```

### Verify Signatures

```bash
# Key-based verification
cosign verify --key cosign.pub test-image:local

# Keyless verification (requires identity info)
cosign verify \
  --certificate-identity=<your-identity> \
  --certificate-oidc-issuer=<issuer-url> \
  test-image:local
```

## Cleanup

> **Note:** The CI workflow automatically cleans up all images before building new ones. Manual cleanup is only needed if you want to delete images without rebuilding.

### Option 1: GitHub Actions Workflow

Go to **Actions → Cleanup GHCR Images → Run workflow**

1. Click "Run workflow"
2. Type `DELETE` in the confirmation field
3. Click "Run workflow"

This will delete all versions of the image from GHCR.

### Option 2: Local Script

```bash
./cleanup-ghcr.sh
```

**Requirements:**
- GitHub CLI (`gh`) installed and authenticated
- Type `DELETE` when prompted to confirm

**The script will:**
- List all image versions
- Delete each version from GHCR
- Show a summary of deleted/failed versions

## Troubleshooting

### "Error: no signatures found" for v3-bundle

**Cause:** The `--bundle` flag in cosign v3 doesn't work correctly with multi-platform manifest lists.

**Solution:** 
- The `:v3-bundle` image is signed using the image digest instead of the tag to work around this limitation
- This ensures the signature is properly attached to the multi-platform manifest
- Verification by tag still works normally

```bash
# Verification works by tag (recommended)
cosign verify --key cosign.pub ghcr.io/nirmata/demo-github-attestations-sbom:v3-bundle
```

**Note:** Other images (v2-traditional, v3-traditional, etc.) don't have this issue and are signed by tag successfully.

### "Error: signing [image]: getting signer: reading key: no PEM block found"

**Cause:** The `COSIGN_PRIVATE_KEY` secret is incorrectly formatted.

**Solution:** Ensure the secret contains the full PEM block including headers:
```
-----BEGIN ENCRYPTED COSIGN PRIVATE KEY-----
...
-----END ENCRYPTED COSIGN PRIVATE KEY-----
```

### "Error: password required"

**Cause:** The `COSIGN_PASSWORD` secret is missing or incorrect.

**Solution:** Verify the password matches the one you used when generating the key pair.

### "Bundle signature not found"

**Cause:** Trying to verify a bundle signature with an older cosign version.

**Solution:** The `--bundle` flag in cosign v3 creates a `.sigstore.json` referrer. Use cosign v3.0+ to verify bundle signatures.

### "Failed to verify signature: no matching signatures"

**Cause:** The image may not be signed, or you're using the wrong verification method/key.

**Solution:**
- Verify you're using the correct public key or identity information
- Check the image was actually signed by inspecting the CI logs
- For keyless signatures, ensure the identity and issuer match exactly

### Cleanup fails with "404 Not Found"

**Cause:** The package doesn't exist in GHCR yet, or you don't have permissions.

**Solution:**
- First push should create the package automatically
- Ensure you have `packages: write` permission
- Check the package exists at `https://github.com/orgs/nirmata/packages/container/package/demo-github-attestations-sbom`

## CI Workflow Structure

The workflow consists of 8 jobs:

```
cleanup (runs first)
  ↓
├─ build-push-and-attest (github-attestation)
├─ build-push-and-attest-sbom (github-sbom)
├─ build-push-unsigned (unsigned)
├─ build-sign-v2-traditional (v2-traditional)
├─ build-sign-v2-keyless (v2-keyless)
├─ build-sign-v3-traditional (v3-traditional)
├─ build-sign-v3-keyless (v3-keyless)
└─ build-sign-v3-bundle (v3-bundle)

(All build jobs run in parallel after cleanup completes)
```

**All images are built as multi-platform images supporting:**
- `linux/amd64` (Intel/AMD x86_64)
- `linux/arm64` (ARM64, including Apple Silicon M1/M2/M3)

### Signature Artifact Types

**1. Traditional OCI Signature Manifests (`.sig` images)**
- Used by: All key-based signatures (v2-traditional, v3-traditional, v3-bundle) and as transport for keyless signatures
- Storage: Separate OCI image in registry with `.sig` suffix
- Format: `registry/image:sha256-<digest>.sig`
- Compatibility: Works with all cosign versions (v1, v2, v3)
- Created by: `cosign sign --key cosign.key` (without `--bundle` flag)

**2. Cosign v3 Bundle Format (`.sigstore.json` as OCI referrer)**
- Status: **NOT CURRENTLY USED** in this testbed
- Reason: The `--bundle` flag in cosign v3.0.4 has compatibility issues with multi-platform manifest lists
- Would be created by: `cosign sign --key cosign.key --bundle` (not working with multi-platform)
- Format: `.sigstore.json` attached as OCI referrer using OCI artifacts spec

**3. Keyless Signatures**
- Used by: v2-keyless, v3-keyless
- Storage: Traditional `.sig` image + external Fulcio certificate + Rekor transparency log entry
- No private keys stored; uses short-lived certificates from OIDC identity
- Verification requires checking Rekor transparency log

**4. GitHub Attestations**
- Used by: `:github-attestation` (build provenance), `:github-sbom` (SBOM)
- Storage: GitHub's native attestation store
- Formats:
  - `:github-attestation`: SLSA v1.0 build provenance
  - `:github-sbom`: SPDX format Software Bill of Materials
- Separate from OCI registry signatures
- Both signed with GitHub's signing infrastructure

**Note on v3-bundle:** Originally intended to demonstrate cosign v3's new bundle format, but currently uses traditional signature format with digest-based signing as a workaround for multi-platform compatibility.

### Job Details

| Job | Image Tag | Cosign Version | Command | Artifacts Created |
|-----|-----------|----------------|---------|-------------------|
| `build-push-and-attest` | `:github-attestation` | N/A | `actions/attest-build-provenance@v3` | SLSA v1.0 build provenance |
| `build-push-and-attest-sbom` | `:github-sbom` | N/A | `anchore/sbom-action@v0` + `actions/attest-sbom@v3` | SPDX SBOM attestation |
| `build-push-unsigned` | `:unsigned` | N/A | None | No signatures |
| `build-sign-v2-traditional` | `:v2-traditional` | v2.4.1 | `cosign sign --key cosign.key --yes :v2-traditional` | Traditional `.sig` image |
| `build-sign-v2-keyless` | `:v2-keyless` | v2.4.1 | `cosign sign --yes :v2-keyless` | `.sig` image + Fulcio cert + Rekor entry |
| `build-sign-v3-traditional` | `:v3-traditional` | v3.0.4 | `cosign sign --key cosign.key --yes :v3-traditional` | Traditional `.sig` image (backward compatible) |
| `build-sign-v3-keyless` | `:v3-keyless` | v3.0.4 | `cosign sign --yes :v3-keyless` | `.sig` image + Fulcio cert + Rekor entry |
| `build-sign-v3-bundle` | `:v3-bundle` | v3.0.4 | `cosign sign --key cosign.key --yes @digest` | Traditional `.sig` image (signed by digest) |

#### Notes:
- **Traditional `.sig` images**: Signatures stored as separate OCI images with `.sig` tag suffix (e.g., `sha256-abc123.sig`)
- **Keyless signatures**: Use OIDC identity from GitHub Actions, verified against Fulcio certificate and Rekor transparency log
- **v3-bundle**: Originally intended for cosign v3's bundle format (`.sigstore.json` as OCI referrer), but the `--bundle` flag is incompatible with multi-platform manifests. Currently demonstrates digest-based signing instead
- **All signed images**: Create backward-compatible traditional OCI signature manifests

## Helper Scripts

### `setup-cosign-keys.sh`

Generates a cosign key pair and provides instructions for adding secrets to GitHub.

```bash
./setup-cosign-keys.sh
```

### `cleanup-ghcr.sh`

Deletes all versions of the kyverno-cosign-testbed image from GHCR.

```bash
./cleanup-ghcr.sh
```

## File Structure

```
.
├── .github/
│   └── workflows/
│       ├── ci.yml           # Main build and sign workflow
│       └── cleanup.yml      # Manual cleanup workflow
├── Dockerfile               # Minimal Alpine-based test image
├── README.md                # User-facing documentation
├── DEVELOPMENT.md           # This file
├── setup-cosign-keys.sh     # Helper script for key generation
├── cleanup-ghcr.sh          # Helper script for cleanup
├── cosign.pub               # Public key (safe to commit)
└── .gitignore               # Protects cosign.key from commits
```

## Environment Variables

The CI workflow uses the following environment variables:

```yaml
env:
  REGISTRY: "ghcr.io/nirmata"
  IMAGE_NAME: "kyverno-cosign-testbed"
```

To use this setup for your own repository, update these values in `.github/workflows/ci.yml`.

## Permissions

The workflow requires the following permissions:

```yaml
permissions:
  contents: read          # Read repository contents
  packages: write         # Push to GHCR and delete versions
  id-token: write         # Keyless signing with OIDC
  attestations: write     # Create GitHub attestations
```

## Security Notes

- ⚠️ **NEVER commit `cosign.key`** - it's in `.gitignore` for protection
- ✅ `cosign.pub` is safe to commit and useful for verification examples
- 🔒 `COSIGN_PRIVATE_KEY` and `COSIGN_PASSWORD` must be stored as GitHub secrets
- 🔑 Keyless signing doesn't require storing any keys - it uses OIDC tokens

## Contributing

When adding new image variants:

1. Add a new job to `.github/workflows/ci.yml`
2. Ensure the job has `needs: cleanup`
3. Update README.md with the new image and verification method
4. Update this document if new setup steps are required

## Resources

- [Cosign Documentation](https://docs.sigstore.dev/cosign/overview/)
- [Kyverno Image Verification](https://kyverno.io/docs/writing-policies/verify-images/)
- [GitHub Attestations](https://docs.github.com/en/actions/security-guides/using-artifact-attestations)
- [Sigstore Public Good Instance](https://www.sigstore.dev/)
