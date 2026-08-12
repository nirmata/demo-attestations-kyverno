# Demo: one central reusable workflow, one org-wide Kyverno policy

**The point of this demo:** a single **central reusable GitHub Actions workflow**
builds and attests images for every repo in the org, which lets a **single
Kyverno policy** admit them all — including images in **private GHCR** whose
attestations come from GitHub's **private Sigstore instance**, verified with the
`cosign.trustedRoot` field added in **Kyverno 1.19**.

Those two halves are not independent. The reusable workflow is what makes the
one-policy story possible, for a reason that is easy to miss.

## Why a reusable workflow is load-bearing, not just DRY

Sigstore's Fulcio sets the signing certificate's SAN from the OIDC
**`job_workflow_ref`** claim — *the workflow that actually ran the signing step*,
not the workflow that triggered it. So when the attest steps live in a reusable
workflow, every calling repo produces attestations bearing the **same** signer
identity:

```
https://github.com/nirmata/demo-attestations-kyverno/.github/workflows/reusable-build-attest.yml@refs/heads/main
```

That collapses N repos into 1 policy identity. It is also the only workable
shape, because of a constraint that took a live cluster to discover:

> Kyverno's Sigstore **bundle** verification path accepts exactly **one**
> identity per attestor. Two entries fail with
> `unsupported: multiple identities are not supported at this time` —
> the policy then never verifies anything, while still passing schema
> validation and the admission webhook.

Per-repo identities would need one entry per repo. You cannot have them. A
central workflow gives you one identity that is correct for the whole org.

```
 repo-a ─┐
 repo-b ─┼─► reusable-build-attest.yml ─► attestation SAN = reusable workflow ─► 1 Kyverno attestor
 repo-c ─┘        (runs attest steps)
```

## ⚠ The trap: a shared identity is shared by everyone

Pinning only the SAN proves **which workflow signed**, not **which repo asked it
to**. Anyone who can call the reusable workflow inherits the identity. Pin the
signer alone and a rogue repo's image satisfies your policy.

So the policy also pins the **caller**, read from the verified provenance
predicate:

```yaml
variables:
  - name: slsaPayload
    expression: >-
      images.containers.map(image,
        verifyAttestationSignatures(image, attestations.slsa, [attestors.github]) > 0
          ? extractPayload(image, attestations.slsa)
          : dyn(null))
validations:
  - expression: variables.slsaPayload.all(p, p != null)
    message: "Failed to verify SLSA provenance attestation"
  - expression: >-
      variables.slsaPayload.all(p, p != null &&
        p.predicate.buildDefinition.internalParameters.github.repository_owner_id == "7470644")
    message: "Provenance was not produced by a repository owned by the nirmata org"
```

`repository_owner_id` (nirmata = `7470644`) is an **immutable numeric ID**. The
org *name* is not: rename or transfer it and a new account could claim
`github.com/nirmata`. The policy checks the ID, the owner URL prefix, and that
the build ran on a GitHub-hosted runner.

### Why the payload is a variable

`extractPayload` can only read an attestation that was verified **in the same
evaluation**. Verification state does not carry from one `validations` entry to
the next — so the obvious layout, signature checks first and payload checks
after, does not work. It fails with:

```
failed to evaluate policy: failed to get payload: intoto attestation payload
cannot be fetch before verifying intoto attestation
```

and under `failurePolicy: Fail` that error denies the image.

A `variables` entry is a single evaluation shared by every validation. Verify
and extract together there, once, and each validation can then assert one thing
and carry its own message. Confirmed from the admission log: each attestation is
verified exactly **once** per request even though four validations read the
provenance payload.

The alternative — chaining every assertion off one
`verifyAttestationSignatures(...) > 0 &&` inside a single expression — also
works, but collapses every distinct failure into one message.

`dyn(null)` is what makes the ternary type-check. A null payload means the
signature did not verify, which the first validation reports; every later
validation re-checks `p != null` so a signature failure surfaces as that clean
message instead of an evaluation error on a null.

## Why private repos need `trustedRoot`

| | Public repo | Private / internal repo |
|---|---|---|
| Fulcio CA | `fulcio.sigstore.dev` | `fulcio.githubapp.com` |
| Trust material | Sigstore TUF repository | **no TUF server** |
| Transparency log | Rekor | **none** |
| CT log / SCT | yes | **none** |
| Freshness proof | Rekor SET | **TSA** (`timestamp.githubapp.com`) |
| Availability | anyone | GitHub Enterprise Cloud |

A policy trusting the Public Good TUF root cannot verify a private-repo
attestation — the certificate chains to a CA it has never heard of. Before 1.19
the only lever was `cosign.tuf`, which assumes the provider runs a TUF server.
GitHub does not. Kyverno 1.19 adds:

```yaml
cosign:
  trustedRoot:
    expression: variables.githubTrustedRoot   # or an inline `value:`
```

It takes a sigstore-go `TrustedRoot` document and **takes precedence over
`tuf`**. This demo keeps the ~26 KB document in a ConfigMap and reads it with
`resource.get(...)` rather than inlining it.

`insecureIgnoreTlog: true` looks like a downgrade and would be one on a
public-good image. Here it *enables* the right check: when Kyverno sees a
Sigstore bundle with the tlog ignored and trust material present, it switches to
verifying the **signed timestamp** against the TSA in the trusted root. Still
cryptographically bound to a time — by `timestamp.githubapp.com` rather than Rekor.

### Both ignore flags are required, and neither weakens the Fulcio check

Verified by removing each one against a real private image (all three fail):

| Config | Result |
|---|---|
| `insecureIgnoreTlog` + `insecureIgnoreSCT` | **admitted** |
| without `insecureIgnoreTlog` | `failed to verify log inclusion: not enough verified log entries from transparency log: 0 < 1` |
| without `insecureIgnoreSCT` | `failed to verify signed certificate timestamp: only able to verify 0 SCT entries; unable to meet threshold of 1` |
| no `ctlog` block at all | fails (both defaults are `false`) |

Structural, not incidental: GitHub's trusted root contains `tlogs: 0` and
`ctlogs: 0`, so demanding one entry of either can never be satisfied.

These flags skip **only** the transparency log and SCT. The Fulcio certificate
chain is still fully verified against GitHub's private CA — demonstrated by
swapping in a hybrid trusted root (GitHub's TSA, public-good Fulcio CA) with the
same flags:

```
error: failed to verify leaf certificate: leaf certificate verification failed
```

If the CA check were being skipped, that would have passed.

## Requirements

- **Kyverno v1.19.0+** (`cosign.trustedRoot`)
- A **private or internal** repo on **GitHub Enterprise Cloud** (private-repo
  Artifact Attestations are a GHEC feature)
- `gh`, `jq`, `kubectl`; cluster egress to `ghcr.io`

## Layout

```
.github/workflows/
├── reusable-build-attest.yml   ★ central: builds + attests (owns the identity)
└── ci-private.yml                caller: inputs only, no attest steps

demos/private-sigstore/
├── Dockerfile
├── policies/
│   ├── kyverno-rbac.yaml            lets Kyverno read the ConfigMap
│   ├── verify-provenance.yaml       SLSA provenance + caller pinning
│   ├── verify-sbom.yaml             SPDX SBOM
│   ├── verify-vuln-scan.yaml        Trivy scan — signature AND payload content
│   ├── verify-build-metadata.yaml   fully custom predicate
│   └── verify-code-review.yaml      real approval count, 2+ required
├── exceptions/
│   └── skip-code-review.yaml        waives ONE policy, keeps the other four
├── resources/private-pod.yaml
├── scripts/
│   ├── fetch-trusted-root.sh                    trusted root → ConfigMap
│   └── setup-ghcr-secrets.sh                    GHCR pull secrets
└── trusted-root/                                generated, gitignored
```

In production the reusable workflow belongs in its own repo (e.g.
`nirmata/shared-workflows`) so it versions independently. It lives here to keep
the demo in one piece — **if you move it, update `subjectRegExp` in every policy.**

### Why five policies and not one

A Kyverno `PolicyException` is all-or-nothing at the **policy** level for an
`ImageValidatingPolicy`: the IVP evaluator returns early the moment an exception
matches, and the IVP CEL environment exposes no `exceptions` variable (the
`exceptions.allowedValues` escape hatch exists only for Validating, Mutating and
Generating policies). You therefore cannot waive one validation inside a policy.

**Exception granularity equals policy granularity.** One attestation per policy
is what makes `exceptions/skip-code-review.yaml` able to waive the code-review
requirement while provenance, SBOM, vulnerability scan and build metadata stay
enforced. The public-Sigstore demo keeps a single combined policy on purpose —
it is the simpler on-ramp and has no exception to demonstrate.

## Walkthrough

### 1. Put this in a private repo

Private-Sigstore routing only happens for private/internal GHEC repos. Copy
`demos/private-sigstore/` and both workflows into one.

### 2. Build and attest

Push to `main`, or **Actions → CI (private attestations) → Run workflow**:

- `ghcr.io/nirmata/demo-private-attestations:attested` — provenance **and** SBOM
- `ghcr.io/nirmata/demo-private-attestations:unattested` — negative test
  (only if your caller workflow builds it; `bootstrap-private-demo.sh` does)

Confirm the packages are **private** under *Packages → Package settings*.

### Verifying with `gh` — pass `--signer-workflow`

```bash
gh attestation verify oci://ghcr.io/nirmata/demo-private-attestations:attested \
  -R nirmata/demo-private-attestations \
  --signer-workflow nirmata/demo-attestations-kyverno/.github/workflows/reusable-build-attest.yml \
  --predicate-type https://slsa.dev/provenance/v1 --format json \
  | jq -r '.[0].verificationResult.signature.certificate
           | {buildSignerURI, buildConfigURI}'
```

```
buildSignerURI: .../demo-attestations-kyverno/.../reusable-build-attest.yml@refs/heads/main   ← central
buildConfigURI: .../demo-private-attestations/.github/workflows/ci.yml@refs/heads/main        ← caller
```

**`--signer-workflow` is mandatory here, and the reason is the whole point of
this demo.** By default `gh` expects the signing identity to live in the repo
given by `-R`. With a central reusable workflow the signer lives in a *different*
repo, so the default policy rejects it. Without the flag you get:

```
Error: verifying with issuer "GitHub, Inc."
```

which is unhelpful because `gh` discards the underlying error
([`sigstore.go`](https://github.com/cli/cli/blob/trunk/pkg/cmd/attestation/verification/sigstore.go):
`return nil, fmt.Errorf("verifying with issuer \"%s\"", issuer)`). It is not an
auth problem and not a private-instance limitation — `gh` fetches the bundles
from the API with plain `repo` scope and handles GitHub's Sigstore instance fine.

`gh` also has `--signer-repo` and `--deny-self-hosted-runners`, which are its
built-in equivalents of this policy's caller-pinning validations.

### Verifying with cosign

Useful because the flags map 1:1 onto what the Kyverno policy encodes — pinned
trusted root, no tlog, signed timestamps:

```bash
# GitHub's trusted root only (the JSONL also contains the Public Good root)
gh attestation trusted-root \
  | jq -c 'select([.certificateAuthorities[]?.uri] | any(test("githubapp\\.com")))' \
  > /tmp/gh-root.json

cosign verify-attestation \
  --new-bundle-format \
  --trusted-root /tmp/gh-root.json \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity "https://github.com/nirmata/demo-attestations-kyverno/.github/workflows/reusable-build-attest.yml@refs/heads/main" \
  --type slsaprovenance1 \
  --insecure-ignore-tlog --use-signed-timestamps --insecure-ignore-sct \
  ghcr.io/nirmata/demo-private-attestations:attested
```

Passing `--certificate-identity` = the **reusable** workflow is itself the proof
that the SAN is the central workflow: cosign fails the identity check otherwise.

Now confirm signer and caller genuinely diverge:

```bash
cosign verify-attestation ... --type slsaprovenance1 [flags above] \
  ghcr.io/nirmata/demo-private-attestations:attested \
  | jq -r '.payload' | base64 -d \
  | jq -r '.predicate.buildDefinition
           | {caller: .externalParameters.workflow.repository,
              owner_id: .internalParameters.github.repository_owner_id,
              runner: .internalParameters.github.runner_environment}'
```

`caller` should be the **calling** repo while the certificate identity is the
**central** workflow. If they name the same workflow, the attest steps ran in the
caller and the org-wide identity story does not hold. Those three fields are
exactly what the policy's caller-pinning validations assert.

### 3. Load the trusted root and credentials

```bash
./scripts/fetch-trusted-root.sh kyverno

export GITHUB_USER=<your-github-username>
export GITHUB_TOKEN=<PAT with read:packages>
./scripts/setup-ghcr-secrets.sh default kyverno
```

`fetch-trusted-root.sh` picks GitHub's root out of the JSONL that
`gh attestation trusted-root` emits (it also contains the Public Good root) and
checks it: `githubapp.com` CAs present, TSAs present, zero Rekor and CT logs.

Both scripts use your **ambient kubectl context** — confirm it with
`kubectl config current-context` first.

### 4. Apply and test

Values are already `nirmata`, so these run as-is:

```bash
kubectl apply -f policies/kyverno-rbac.yaml
kubectl apply -f policies/            # all five ImageValidatingPolicies
kubectl apply -f resources/private-pod.yaml
```

With all five enforced the pod is **denied**, and that is the intended result:
the demo image is built by a direct push to `main`, the code-review attestation
records the true approval count (zero), and `verify-code-review` requires two.

```
Image requires at least 2 approving code reviews
```

Waive that one policy and re-apply:

```bash
kubectl apply -f exceptions/skip-code-review.yaml
kubectl apply -f resources/private-pod.yaml    # admitted
```

### Two Kyverno flags this demo needs

**1. PolicyExceptions must be switched on.** The chart ships them off, and
`--enablePolicyException=true` alone is not enough — without a namespace the
controller logs `the flag --exceptionNamespace cannot be empty` at startup and
exceptions are silently never loaded:

```bash
helm upgrade kyverno kyverno/kyverno -n kyverno --reuse-values \
  --set features.policyExceptions.enabled=true \
  --set features.policyExceptions.namespace=kyverno
```

**2. The image-verification cache must be off** — `--imageVerifyCacheEnabled=false`.

This is a real bug in the Kyverno `main` build used here, not a preference. The
cache is keyed by image, so a repeat `verifyAttestationSignatures` for an image
already verified in this process returns the cached count **without
repopulating the attestation payload store**. Every `extractPayload` after that
first verification then fails:

```
Policy verify-build-metadata error: failed to evaluate policy: failed to get
payload: intoto attestation payload cannot be fetch before verifying intoto
attestation
```

It is reproducible and order-dependent: with the cache on, the first admission
after a controller restart passes and every later one fails, naming whichever
policy happened to evaluate second. Because `failurePolicy: Fail` turns an
evaluation error into a denial, this looks exactly like a real policy violation.

```bash
kubectl -n kyverno set args deploy/kyverno-admission-controller \
  --imageVerifyCacheEnabled=false   # illustrative; use the chart value
```

Signature-only policies (`verify-sbom`) are unaffected — this only bites
policies that read a payload.

### `polex` does not mean what you think

`kubectl get polex` resolves to the **legacy `kyverno.io/v2`** PolicyException.
The exception here is `policies.kyverno.io/v1`, so the short name silently lists
and deletes the wrong resource — `kubectl delete polex …` reports success while
leaving the exception in force. Always spell out the group:

```bash
kubectl get policyexceptions.policies.kyverno.io -A
```

Negative test — an image with no attestations:

```bash
kubectl run should-fail \
  --image=ghcr.io/nirmata/demo-private-attestations:unattested \
  --restart=Never --overrides='{"spec":{"imagePullSecrets":[{"name":"ghcr-pull-secret"}]}}'
```

Negative tests for the **payload** checks — these are the ones worth running,
because they prove the validations actually evaluate rather than passing
vacuously. Flip an expected value and the image must be denied:

```bash
sed 's|"7470644"|"99999999"|' policies/verify-provenance.yaml | kubectl apply -f -
sleep 30 && kubectl delete pod private-attestation-demo --ignore-not-found
kubectl apply -f resources/private-pod.yaml     # → denied
kubectl apply -f policies/verify-provenance.yaml

sed 's|builder == "github-hosted"|builder == "self-hosted-nope"|' \
  policies/verify-build-metadata.yaml | kubectl apply -f -
sleep 30 && kubectl delete pod private-attestation-demo --ignore-not-found
kubectl apply -f resources/private-pod.yaml     # → denied
kubectl apply -f policies/verify-build-metadata.yaml
```

Give webhook re-registration ~30s after any policy change. Test too soon and
the pod is admitted because the webhook is not registered yet — which reads
exactly like a policy that passed.

### 5. Onboard a second repo (the actual payoff)

In another private repo in the org, that is the whole pipeline:

```yaml
jobs:
  build:
    uses: nirmata/demo-attestations-kyverno/.github/workflows/reusable-build-attest.yml@main
    permissions: {contents: read, packages: write, id-token: write, attestations: write}
    with:
      image-name: my-service
```

Widen the policy's `matchImageReferences` glob to `ghcr.io/nirmata/*`. **No new
attestor, no new identity, no policy edit per repo** — that is the payoff.

## Trusted root rotation

Pinned roots do not expire, but GitHub rotates key material a few times a year.
After a rotation, refresh the ConfigMap:

```bash
./scripts/fetch-trusted-root.sh kyverno
```

Nothing else changes — the policy reads the ConfigMap per admission request, so
no restart and no policy edit. Worth running on a schedule. The trade-off of
pinning is that revocations are invisible until you refresh.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `multiple identities are not supported at this time` | More than one `keyless.identities` entry. Collapse to one anchored regex. |
| `threshold not met for verified signed timestamps: 0 < 1` | Image was signed by Public Good (no GitHub TSA timestamp) but checked against the GitHub root — i.e. the repo is public. |
| `parsing inline trustedRoot JSON` | ConfigMap holds JSONL (both roots) instead of the single GitHub root. Re-run `fetch-trusted-root.sh`. |
| `configmaps "github-trusted-root" is forbidden` | `policies/kyverno-rbac.yaml` not applied. |
| `MANIFEST_UNKNOWN` / `401` from Kyverno | `ghcr-pull-secret` missing from the **Kyverno** namespace, or PAT lacks `read:packages`. |
| `no matching signatures` with the right root | Identity mismatch. Check SAN with `--format json`; if it names the caller, the attest steps are in the wrong workflow. |
| Caller-pinning validations fail | Image built by a repo outside the org, or on a self-hosted runner. |
| `failed to evaluate policy: no such key: buildDefinition` | Wrong `extractPayload` path. It returns the **full in-toto Statement**, so predicate fields need `.predicate.` — `extractPayload(...).predicate.buildDefinition...`. (The docs' `extractPayload(...).bomFormat` example is a *referrer* attestation, a different code path.) With `failurePolicy: Fail` a bad path denies everything, looking just like a real violation. |
| `Error: verifying with issuer "GitHub, Inc."` from `gh` | Missing `--signer-workflow`. The signer lives in the central repo, not the `-R` repo, and `gh` swallows the real error. Not an auth or private-instance problem. |
| `trustedRoot` rejected by the API server | Kyverno older than 1.19 — or, commonly, a **stale CRD**: `helm upgrade` does not update CRDs. Check with `kubectl get crd imagevalidatingpolicies.policies.kyverno.io -o json \| grep -c trustedRoot`. |
| `kyverno apply` reports `Applying 0 policy rule(s)` | The CLI **silently skips** policies it cannot parse, with `error: 0` and exit 0. Re-run with `-v 6` to see the reason. |

## Reference

- [Kyverno: ImageValidatingPolicy](https://kyverno.io/docs/policy-types/image-validating-policy/)
- [Fulcio: OIDC and the `job_workflow_ref` SAN](https://github.com/sigstore/fulcio/blob/main/docs/oidc.md)
- [Reusable workflow identity is reusable by anyone](https://blog.richardfan.xyz/2024/08/02/reusable-workflow-is-good-until-you-realize-your-identity-is-also-reusable-by-anyone.html)
- [GitHub: Artifact attestations](https://docs.github.com/en/actions/concepts/security/artifact-attestations)
- [GitHub: Verifying attestations offline](https://docs.github.com/en/actions/security-for-github-actions/using-artifact-attestations/verifying-attestations-offline)
