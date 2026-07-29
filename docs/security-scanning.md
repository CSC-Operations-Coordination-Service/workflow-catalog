# Security scanning & signing (Gitleaks, Grype & Cosign)

Four complementary scanners — plus **Cosign** image signing — in the catalog,
across the lifecycle. The first four *detect* problems; Cosign is not a scanner,
it *proves provenance*: a signature that says "this CI built this exact image".

| Tool | Catches / provides | Where it runs | Building block |
| --- | --- | --- | --- |
| **Gitleaks** | Secrets/credentials committed to git | On every push/PR (and locally, pre-commit) | [gitleaks.yml](../.github/workflows/gitleaks.yml) |
| **Checkov** | Dockerfile misconfigurations (source) | Before the image is built | [docker-build.yml](../.github/workflows/docker-build.yml) (`scan-dockerfile: true`) |
| **Grype** | Known CVEs in the built image | After an image is built & pushed | [docker-build.yml](../.github/workflows/docker-build.yml) (`scan-image: true`) |
| **Dockle** | CIS / hardening issues in image layers | After an image is built & pushed | [docker-build.yml](../.github/workflows/docker-build.yml) (`lint-image: true`) |
| **Cosign** | Image provenance / tamper-evidence (signature) | After push, on the release digest | [docker-build.yml](../.github/workflows/docker-build.yml) (`sign-image: true`) |

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

Checkov runs in its own `dockerfile-lint` job that the `docker` build job
depends on — not as a step inside it. `checkov-action` is a *container* action,
and the runner pulls the image of every container action in a job during **Set
up job**, before any step-level `if:` is evaluated. As a step it pulled
`ghcr.io/bridgecrewio/checkov` on every build even with `scan-dockerfile: false`
— fatal on a runner without ghcr.io egress. A job-level `if` skips the job
outright, so nothing is pulled when the lint is off. Keep this in mind before
folding any other container action into the build job.

```yaml
jobs:
  docker:
    uses: ./.github/workflows/docker-build.yml
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
attached to the run as a SARIF artifact (`grype-<image-name>-scan`), pass or fail.

### Composed-primitive caller

```yaml
jobs:
  docker:
    uses: ./.github/workflows/docker-build.yml
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
    uses: ./.github/workflows/docker-build.yml
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
    uses: ./.github/workflows/docker-build.yml
    with:
      image-name: my-app
      dockerfile: Dockerfile
      release: true       # signing only runs on release builds
      sign-image: true    # Cosign — sign the pushed digest
    secrets: inherit
```

`node-workflow.yml` exposes the same `sign-image` toggle and forwards it to
`docker-build.yml`.

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
