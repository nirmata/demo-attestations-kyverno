# One central workflow, one org-wide policy

This repo demonstrates **supply-chain controls at org scale**: a single
**central reusable GitHub Actions workflow** builds and attests images for every
repo in the org, so a **single Kyverno `ImageValidatingPolicy`** can admit them
all — for public images and for private ones.

```
 repo-a ─┐
 repo-b ─┼─► .github/workflows/reusable-build-attest.yml ─► same signer identity ─► 1 Kyverno attestor
 repo-c ─┘         (builds + attests)
```

## Why centralize the workflow

Not for DRY. Sigstore's Fulcio sets the signing certificate's SAN from the OIDC
**`job_workflow_ref`** claim — *the workflow that actually ran the signing step*,
not the one that triggered it. Move the attest steps into a reusable workflow
and every calling repo produces attestations under the **same** identity:

```
https://github.com/nirmata/demo-attestations-kyverno/.github/workflows/reusable-build-attest.yml@refs/heads/main
```

That is what makes one policy possible for N repos. It is also the only shape
that works at all:

> Kyverno's Sigstore **bundle** verification path accepts exactly **one**
> identity per attestor. A second entry fails with `unsupported: multiple
> identities are not supported at this time` — and the policy then verifies
> nothing while still passing schema validation and the admission webhook.

**The catch:** a shared identity is shared by everyone who can call the
workflow, and a workflow in a *public* repo can be called by anyone on GitHub.
Pinning the signer proves *which workflow signed*, not *which repo asked*. Both
policies here therefore also pin the caller — org owner ID, caller repo, and
runner type — read from the verified provenance predicate.

## The two demos

| | [`demos/public-sigstore/`](demos/public-sigstore/) | [`demos/private-sigstore/`](demos/private-sigstore/README.md) |
|---|---|---|
| Repo visibility | public | private / internal (**GHEC**) |
| Signed by | Sigstore Public Good | GitHub's private instance |
| Fulcio CA | `fulcio.sigstore.dev` | `fulcio.githubapp.com` |
| Trust material | Sigstore TUF | `cosign.trustedRoot` (**Kyverno 1.19+**) |
| Freshness proof | Rekor | TSA (`timestamp.githubapp.com`) |
| Registry auth | none | `spec.credentials.secrets` |
| Kyverno | 1.17+ | **1.19+** |

The two policies are deliberately near-identical — the diff between them *is*
the diff between the two Sigstore instances. Everything else is shared.

## Layout

```
.github/workflows/
  reusable-build-attest.yml   ★ central: builds + attests, owns the identity
  ci-public.yml                 caller → public demo
  ci-private.yml                caller → private demo
  cleanup.yml
app/Dockerfile                one image source, both demos
demos/
  public-sigstore/            policies + test pod
  private-sigstore/           policies + test pod + trusted-root & credential scripts
docs/DEVELOPMENT.md           cosign key-based signing reference (separate flow)
scripts/cleanup-ghcr.sh
legacy/                       superseded cosign-key demo files, kept for reference
```

In production the reusable workflow belongs in its own repo (e.g.
`nirmata/shared-workflows`) so it versions independently of any product. It
lives here to keep the demo in one piece — **if you move it, update the
`subjectRegExp` in both policies.**

## Quick start

```bash
# public demo
kubectl apply -f demos/public-sigstore/policies/verify-github-attestations.yaml
kubectl apply -f demos/public-sigstore/resources/pod.yaml          # admitted
kubectl run nope --image=ghcr.io/nirmata/demo-github-attestations-sbom:unattested --restart=Never   # denied
```

For the private demo — trusted root, GHCR credentials, and the GHEC
requirement — see [`demos/private-sigstore/README.md`](demos/private-sigstore/README.md).

## Onboarding another repo

That is the payoff. In any other repo in the org, the whole pipeline is:

```yaml
jobs:
  build:
    uses: nirmata/demo-attestations-kyverno/.github/workflows/reusable-build-attest.yml@main
    permissions: {contents: read, packages: write, id-token: write, attestations: write}
    with:
      image-name: my-service
```

Widen the policy's `matchImageReferences` glob to `ghcr.io/nirmata/*`. No new
attestor, no new identity, no per-repo policy edit.

## Reference

- [Fulcio: OIDC and the `job_workflow_ref` SAN](https://github.com/sigstore/fulcio/blob/main/docs/oidc.md)
- [Reusable workflow identity is reusable by anyone](https://blog.richardfan.xyz/2024/08/02/reusable-workflow-is-good-until-you-realize-your-identity-is-also-reusable-by-anyone.html)
- [GitHub: Artifact attestations](https://docs.github.com/en/actions/concepts/security/artifact-attestations)
- [Nirmata: Supply chain security with GitHub Artifact Attestations and Kyverno](https://nirmata.com/2026/03/16/supply-chain-security-with-github-artifact-attestations-and-kyverno/)
