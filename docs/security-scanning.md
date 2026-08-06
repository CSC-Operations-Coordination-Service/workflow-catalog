# Security scanning & signing (Gitleaks, Grype & Cosign)

Four complementary scanners — plus **Cosign** image signing — in the catalog,
across the lifecycle. The first four *detect* problems; Cosign is not a scanner,
it *proves provenance*: a signature that says "this CI built this exact image".

| Tool | Catches / provides | Where it runs | Turn it on with | Composite action |
| --- | --- | --- | --- | --- |
| **Gitleaks** | Secrets/credentials committed to git | On every push/PR (and locally, pre-commit) | [gitleaks.yml](../.github/workflows/gitleaks.yml) | [`gitleaks-scan`](../.github/actions/gitleaks-scan/action.yml) |
| **Checkov** | Dockerfile misconfigurations (source) | Before the image is built | [docker-build.yml](../.github/workflows/docker-build.yml) (`scan-dockerfile: true`) | [`checkov-scan`](../.github/actions/checkov-scan/action.yml) |
| **Grype** | Known CVEs in the built image | After an image is built & pushed | [docker-build.yml](../.github/workflows/docker-build.yml) (`scan-image: true`) | [`grype-scan`](../.github/actions/grype-scan/action.yml) |
| **Dockle** | CIS / hardening issues in image layers | After an image is built & pushed | [docker-build.yml](../.github/workflows/docker-build.yml) (`lint-image: true`) | — (inline) |
| **Cosign** | Image provenance / tamper-evidence (signature) | After push, on the release digest | [docker-build.yml](../.github/workflows/docker-build.yml) (`sign-image: true`) | [`cosign-sign`](../.github/actions/cosign-sign/action.yml) |

Every tool but Dockle is packaged as a **composite action** that owns its pinned
SHA, its input validation and its report handling; the reusable workflows just
wire them together with the toggles above. Use the workflow toggles for the
common path, and the actions directly when you already have a job of your own —
see [Using the scanners as plain steps](#using-the-scanners-as-plain-steps).
[`syft-sbom`](../.github/actions/syft-sbom/action.yml) rounds out the set on the
SBOM side.

Checkov and Dockle are two halves of the same concern seen from different sides:
Checkov lints the **Dockerfile source** *before* the build; Dockle lints the
**resulting image layers** *after* it — catching what the source can't show
(secrets `COPY`'d in, setuid binaries, leftover package caches, root user).

SBOM generation (**Syft** → CycloneDX → Dependency-Track) is documented
separately in [sbom-dependency-track.md](sbom-dependency-track.md); Grype here is
the *blocking* CVE gate, Dependency-Track is the *continuous* tracking.

---

## Gitleaks — secret scanning

[`gitleaks.yml`](../.github/workflows/gitleaks.yml) is **dual-triggered**:

- **`workflow_call`** — a reusable primitive, like the rest of the catalog.
  Other repos consume it with a thin caller (see below).
- **`push` / `pull_request`** — it also self-triggers, so it guards this repo
  directly. `gitleaks-action` scopes the scan from the event: the pushed commit
  range on `push` and the PR commits on `pull_request`.

### License

`gitleaks-action` requires a **license on organization repositories** (it is
free for personal repos). Get a key at <https://gitleaks.io> and add it as an
**organization** secret named `GITLEAKS_LICENSE` so every repo shares it (see
[.github/SECRETS.md](../.github/SECRETS.md)). A repo-level secret works too and
is handy for testing on a single repo.

### Consuming it from another repo

```yaml
# .github/workflows/security.yml in your repo
name: Security
on: [push, pull_request, workflow_dispatch]
jobs:
  gitleaks:
    uses: CSC-Operations-Coordination-Service/workflow-catalog/.github/workflows/gitleaks.yml@develop
    secrets: inherit   # forwards GITLEAKS_LICENSE (+ GITHUB_TOKEN)
```

### Local pre-commit hook ("shift-left")

Catch secrets *before* they are committed, not after CI flags them. Install
[`pre-commit`](https://pre-commit.com/#install) and enable the hook wired up in
[`.pre-commit-config.yaml`](../.pre-commit-config.yaml):

```sh
pip install pre-commit   # or: brew install pre-commit / apt install pre-commit
pre-commit install
```

From then on, `git commit` scans the staged changes and blocks the commit when a
secret is found:

```text
Detect hardcoded secrets.................................................Failed
- hook id: gitleaks
- exit code: 1
...
Finding:     token: "REDACTED"
RuleID:      generic-api-key
File:        test_sensitive_data.yml
Line:        4
Fingerprint: test_sensitive_data.yml:generic-api-key:4
```

### Allowlisting a false positive

When a finding is a known non-secret (an example value, a test fixture), copy its
**`Fingerprint:`** from the failure output into
[`.gitleaksignore`](../.gitleaksignore), one per line:

```text
README.md:generic-api-key:27
```

Keep the list short and justify each entry — it silences a *real* scanner hit.

---

## Checkov — Dockerfile misconfiguration lint

Enable it on any image build by passing `scan-dockerfile: true` to
[`docker-build.yml`](../.github/workflows/docker-build.yml). Checkov lints the
`dockerfile` input for security misconfigurations — missing `USER` (runs as
root), no `HEALTHCHECK`, unpinned base image, and the rest of its `CKV_DOCKER_*`
policy set — **before** anything is built or pushed, so a bad Dockerfile fails
fast (no wasted build/login). It needs no secret.

| Input | Default | Purpose |
| --- | --- | --- |
| `scan-dockerfile` | `false` | Turn the Checkov lint on. |
| `scan-dockerfile-soft-fail` | `false` | `true` = report findings but don't fail the build. |

Checkov runs through the [`checkov-scan`](../.github/actions/checkov-scan/action.yml)
action, in its own `dockerfile-lint` job that the `docker` build job depends on —
not as a step inside it. The `checkov-action` it wraps is a *container* action,
and the runner pulls the image of every container action in a job during **Set
up job**, before any step-level `if:` is evaluated. As a step it pulled
`ghcr.io/bridgecrewio/checkov` on every build even with `scan-dockerfile: false`
— fatal on a runner without ghcr.io egress. A job-level `if` skips the job
outright, so nothing is pulled when the lint is off. Wrapping it in a composite
action does not change that, which is why `checkov-scan` says so in its own
description: gate it at job level. Keep this in mind before folding any other
container action into the build job.

`checkov-scan` also lints Kubernetes manifests, Terraform, Helm charts and
GitHub Actions workflows — pass `directory` plus the matching `framework`
instead of `file`/`dockerfile`. `docker-build.yml` only wires up the Dockerfile
case.

```yaml
jobs:
  docker:
    uses: CSC-Operations-Coordination-Service/workflow-catalog/.github/workflows/docker-build.yml@develop
    with:
      image-name: my-app
      dockerfile: Dockerfile
      scan-dockerfile: true        # block on Dockerfile misconfigurations
      scan-image: true             # + Grype CVE gate on the built image
    secrets: inherit
```

Two common `CKV_DOCKER_*` findings and their fixes:

```dockerfile
# CKV_DOCKER_2 — declare a HEALTHCHECK
HEALTHCHECK --interval=30s --timeout=5s --retries=3 CMD wget -q -O- http://localhost/ || exit 1

# CKV_DOCKER_3 — run as a non-root user
RUN addgroup -S app && adduser -S app -G app
USER app
```

Suppress a specific rule inline with a `#checkov:skip=<id>:<reason>` comment in
the Dockerfile, or narrow the run with Checkov's `check` / `skip_check` inputs.

**How `python-demo` is configured, and why.** Both of its Dockerfiles pass every
Checkov check except `CKV_DOCKER_2` (no `HEALTHCHECK`) — 46 of 47 on
`Dockerfile.local`, 51 of 52 on `Dockerfile.registry`. The image is a one-shot
CLI (`ENTRYPOINT ["python-demo"]` / `CMD ["10"]`): it runs, prints, and exits, so
there is no long-lived process for a healthcheck to poll and the check is not
meaningful here. The caller therefore runs the lint in **report-only** mode:

```yaml
      scan-dockerfile: true
      scan-dockerfile-soft-fail: true
```

Note what soft-fail does *not* cover on its own: `dockerfile-lint` can fail
during **Set up job**, pulling `ghcr.io/bridgecrewio/checkov`, before Checkov
ever runs. The `docker` job's gate treats `scan-dockerfile-soft-fail` as "never
block" for exactly that reason — otherwise a report-only lint would still stop
the build when the runner cannot reach ghcr.io.

---

## Grype — image vulnerability scanning

Enable it on any image build by passing `scan-image: true` to
[`docker-build.yml`](../.github/workflows/docker-build.yml). Grype pulls the
just-pushed image **by digest** from the Nexus registry (reusing the login
already set up for the push — no extra secret) and fails the job when a
vulnerability at or above the cutoff is found.

| Input | Default | Purpose |
| --- | --- | --- |
| `scan-image` | `false` | Turn the Grype scan on. |
| `scan-severity-cutoff` | `high` | Lowest severity that fails the build: `negligible`\|`low`\|`medium`\|`high`\|`critical`. |
| `scan-fail-build` | `true` | `false` = scan and report only (no gate). |

The scan runs **after** the image SBOM is uploaded to Dependency-Track, so the
inventory is recorded even when the gate trips. The Grype result is always
attached to the run as a SARIF artifact (`grype-<image-name>-scan`), pass or fail
— [`grype-scan`](../.github/actions/grype-scan/action.yml) uploads it under
`!cancelled()`, precisely so the run that failed the gate still tells you which
CVEs to fix.

Outside an image build, the same action scans a `path` or an existing `sbom` —
see [Using the scanners as plain steps](#using-the-scanners-as-plain-steps).

### Composed-primitive caller

```yaml
jobs:
  docker:
    uses: CSC-Operations-Coordination-Service/workflow-catalog/.github/workflows/docker-build.yml@develop
    with:
      image-name: my-app
      dockerfile: Dockerfile
      scan-image: true
      scan-severity-cutoff: high   # gate on High/Critical
    secrets: inherit
```

### All-in-one (Node) caller

`node-workflow.yml` delegates image builds to `docker-build.yml`. To gate the
Node image on CVEs, forward the same inputs from your caller (or add
`scan-image` passthrough to `node-workflow.yml` if you want it as a first-class
toggle there — currently it exposes `build-image` + `generate-sbom`).

### Grype vs Dependency-Track

They are complementary, not redundant:

- **Grype** is a **blocking gate at build time** — a fast pass/fail on the image
  you are about to publish, using Grype's own CVE database.
- **Dependency-Track** (fed by the Syft SBOM) is **continuous** — it keeps
  re-scanning already-released versions as new CVEs are published, without
  re-running CI. See [sbom-dependency-track.md](sbom-dependency-track.md).

Run both: Grype stops a known-vulnerable image from shipping today; DT tells you
when yesterday's image became vulnerable.

---

## Dockle — image hardening lint

Enable it on any image build by passing `lint-image: true` to
[`docker-build.yml`](../.github/workflows/docker-build.yml). Dockle inspects the
**built image's layers** against the CIS Docker Benchmark and best practices:
runs as root, setuid/setgid binaries, credentials/secrets baked into a layer,
uncleared package caches, `sudo`, use of `ADD` over `COPY`, and more. It pulls
the image by digest through the runner's docker socket, reusing the Nexus login
(no extra secret).

| Input | Default | Purpose |
| --- | --- | --- |
| `lint-image` | `false` | Turn the Dockle lint on. |
| `lint-image-failure-threshold` | `WARN` | Lowest level that fails the build: `INFO`\|`WARN`\|`FATAL`. |
| `lint-image-fail-build` | `true` | `false` = report only (no gate). |

The Dockle result is always attached to the run as a SARIF artifact
(`dockle-<image-name>-report`), pass or fail.

```yaml
jobs:
  docker:
    uses: CSC-Operations-Coordination-Service/workflow-catalog/.github/workflows/docker-build.yml@develop
    with:
      image-name: my-app
      dockerfile: Dockerfile
      scan-dockerfile: true   # Checkov — Dockerfile source (pre-build)
      scan-image: true        # Grype   — CVEs in the image (post-build)
      lint-image: true        # Dockle  — CIS/hardening of the image (post-build)
    secrets: inherit
```

### Dockle vs Checkov

Not redundant — they look at different artifacts. Checkov reads the **Dockerfile
source** and can enforce things before a build exists (pinned base image, build
style); Dockle reads the **final image** and catches what the source can't
reveal — a secret file that got `COPY`'d in, a setuid binary pulled by a package,
caches left behind. Run both for full build-time coverage of misconfiguration.
Silence a specific Dockle credential false-positive with the action's
`accept-keywords` / `accept-filenames` inputs, or a check with `DOCKLE_IGNORES`.

---

## Cosign — image signing

Enable it on a release image build by passing `sign-image: true` to
[`docker-build.yml`](../.github/workflows/docker-build.yml). Cosign signs the
just-pushed image **by digest**, at every registry it was pushed to (Nexus, and
GHCR / Docker Hub when enabled), so consumers — or a Kubernetes admission
controller (Kyverno, Connaisseur) — can prove the image was built by this CI and
has not been altered since. Unlike the scanners above, this is **key-based**
(not keyless/OIDC): it needs a Cosign keypair (see below), reuses the registry
logins already established for the push, and is **gated to release builds**
(`release: true`) — develop images are left unsigned even with `sign-image: true`.

| Input | Default | Purpose |
| --- | --- | --- |
| `sign-image` | `false` | Sign the pushed image digest with Cosign. Release builds only; needs the two Cosign secrets. |

Signing needs two secrets, `COSIGN_PRIVATE_KEY` and `COSIGN_PASSWORD` (see
[.github/SECRETS.md](../.github/SECRETS.md)) — unlike the scanners, which need
none. Generate the keypair once with `cosign generate-key-pair`, store
`cosign.key` as `COSIGN_PRIVATE_KEY` and its password as `COSIGN_PASSWORD`, and
publish `cosign.pub` so verifiers can check signatures.

```yaml
jobs:
  docker:
    uses: CSC-Operations-Coordination-Service/workflow-catalog/.github/workflows/docker-build.yml@develop
    with:
      image-name: my-app
      dockerfile: Dockerfile
      release: true       # signing only runs on release builds
      sign-image: true    # Cosign — sign the pushed digest
    secrets: inherit
```

`node-workflow.yml` exposes the same `sign-image` toggle and forwards it to
`docker-build.yml`.

## Using the scanners as plain steps

The toggles above are the easy path, but they assume you are calling
`docker-build.yml` / `gitleaks.yml`. When you already have a job of your own,
reference the composite actions directly — one step each, pinned SHAs and
report handling included. Use the **full** `owner/repo/path@ref` form; a local
`./.github/actions/...` path resolves against your workspace, not the catalog's.

```yaml
jobs:
  security:
    runs-on: self-hosted
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0        # gitleaks needs the history it is asked to scan

      - name: Secrets
        uses: CSC-Operations-Coordination-Service/workflow-catalog/.github/actions/gitleaks-scan@develop
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
          license: ${{ secrets.GITLEAKS_LICENSE }}

      # Dependencies of the source tree, no image required.
      - name: SBOM
        id: sbom
        uses: CSC-Operations-Coordination-Service/workflow-catalog/.github/actions/syft-sbom@develop
        with:
          path: .
          output-file: sbom.cdx.json
          artifact-name: sbom-my-app

      - name: CVE gate
        uses: CSC-Operations-Coordination-Service/workflow-catalog/.github/actions/grype-scan@develop
        with:
          sbom: ${{ steps.sbom.outputs.bom-file }}   # or image: <ref>@<digest>
          severity-cutoff: high
          artifact-name: grype-my-app
```

Two things the actions will not paper over:

- **`checkov-scan` must be gated at job level, never step level.** It wraps a
  *container* action, and the runner pulls the image of every container action
  in a job during **Set up job** — before any step `if:` is evaluated. A step
  `if: false` still costs you the `ghcr.io/bridgecrewio/checkov` pull, which is
  fatal on a runner without ghcr.io egress. Give it its own job with a
  job-level `if`, as [`docker-build.yml`](../.github/workflows/docker-build.yml)
  does with `dockerfile-lint`.
- **Pass images by digest.** `syft-sbom` and `grype-scan` both warn on a
  tag-only reference: a tag can move between the push and the scan, so the gate
  and the published inventory would describe an image you did not build. Use
  `${{ steps.build.outputs.digest }}` from `docker/build-push-action`.

Scanning the SBOM instead of the image (as above) saves the second registry pull
and guarantees the gate and Dependency-Track see the same inventory — at the
cost of the extra file/OS evidence Grype collects when it catalogs an image
itself. Both are supported; `docker-build.yml` scans the image.

## Local usage

Scan an image locally with the same engines CI uses:

```sh
grype <image-ref> --fail-on high        # CVEs;      e.g. registry/host:port/my-app:tag
dockle --exit-level warn <image-ref>    # CIS/hardening lint of the image
```

Verify a signed image against the public key (the consumer side of `sign-image`):

```sh
cosign verify --key cosign.pub <registry>/my-app@<digest>
```

Scan for secrets locally without committing:

```sh
gitleaks detect --source . --verbose
```
