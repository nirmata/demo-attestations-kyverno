# Demo: GitHub attestations + SBOM with Kyverno


This repo demonstrates **supply-chain controls** using GitHub Artifact Attestations (provenance + SBOM) and **Kyverno ImageValidatingPolicy** for cluster enforcement.

- **Pipeline:** GitHub Actions builds images and attaches SLSA provenance and SPDX SBOM attestations  (Uses the [GitHub artifact attestations](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations#generating-build-provenance-for-container-images) flow)
- **Cluster:** Kyverno verifies those attestations at admission time.



## Pipeline

A single **CI** workflow (`.github/workflows/ci.yml`) runs on push and pull requests:

- Builds and pushes images with fixed tags:
  - **`:github-attestation`** — image with SLSA build provenance attestation
  - **`:github-sbom`** — image with SPDX SBOM attestation
- Uses `actions/attest-build-provenance@v3` and `actions/attest-sbom@v3` with `push-to-registry: true`.

## How to run

Push to `main` or open a PR to trigger CI. Or run the workflow manually from **Actions** → **CI** → **Run workflow**.

Images are published to:

- `ghcr.io/YOUR_ORG/demo-github-attestations-sbom:github-attestation`
- `ghcr.io/YOUR_ORG/demo-github-attestations-sbom:github-sbom`

Replace `YOUR_ORG` with your GitHub org or username.

## Verify attestations

**In GitHub:** Open a workflow run → **Attestations**.

**With GitHub CLI:**

```bash
docker login ghcr.io
gh attestation verify oci://ghcr.io/YOUR_ORG/demo-github-attestations-sbom:github-attestation -R YOUR_ORG/demo-github-attestations-sbom
```

Provenance (SLSA):

```bash
gh attestation verify oci://ghcr.io/YOUR_ORG/demo-github-attestations-sbom:github-attestation \
  -R YOUR_ORG/demo-github-attestations-sbom \
  --predicate-type https://slsa.dev/provenance/v1 \
  --format json
```

SBOM (SPDX):

```bash
gh attestation verify oci://ghcr.io/YOUR_ORG/demo-github-attestations-sbom:github-sbom \
  -R YOUR_ORG/demo-github-attestations-sbom \
  --predicate-type https://spdx.dev/Document/v2.3 \
  --format json
```

## Cluster enforcement with Kyverno

Requires **Kyverno v1.17+** and ImageValidatingPolicy support.

Policies (provenance + SBOM) are in **`sample-policies/`**:

- `verify-github-provenance.yaml` — verify SLSA provenance attestation
- `verify-github-sbom.yaml` — verify SPDX SBOM attestation

**Deploy:**

```bash
kubectl apply -f sample-policies/verify-github-provenance.yaml
kubectl apply -f sample-policies/verify-github-sbom.yaml
```


**Test:**

```bash
kubectl run demo-pod --image=ghcr.io/YOUR_ORG/demo-github-attestations-sbom:github-attestation --restart=Never -- /bin/sh -c "sleep 30"
```

If the pod is admitted, provenance verification passed. (SBOM is attested on the `:github-sbom` image; use that tag to exercise the SBOM policy.)

**Note:** Images are built when you push to `main`. If you see `MANIFEST_UNKNOWN`, wait a minute for GHCR to finish publishing, or trigger the workflow from Actions and wait for it to complete.

## Reference

- [GitHub: Generating build provenance for container images](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations#generating-build-provenance-for-container-images)
- [Kyverno: ImageValidatingPolicy](https://kyverno.io/docs/policy-types/image-validating-policy/)
