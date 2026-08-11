# CI/CD Workflow Catalog

A catalog of **composable GitHub Actions building blocks** — reusable workflows
and composite actions — shared across projects. It is consumed two ways:

- **In-repo**: the [`python-demo`](../python-demo) package is built by a thin
  caller ([`python-demo.yml`](../.github/workflows/python-demo.yml)) that wires
  the building blocks together — a working example of the catalog in use.
- **Cross-repo**: other repositories reference the reusable workflows directly,
  e.g. `uses: CSC-Operations-Coordination-Service/workflow-catalog/.github/workflows/node-workflow.yml@develop`.

## Architecture

Three layers, from fine-grained to coarse:

```text
callers (triggers)          python-demo.yml          <your-app>.yml (in your repo)
        │  uses:                  │                         │
        ▼                         ▼                         ▼
reusable workflows  python-ci.yml  sbom.yml  docker-build.yml  gitleaks.yml  node-workflow.yml
(jobs)                     │           │            │              │              │
        │  uses:           ▼           ▼            ▼              ▼              ▼
composite actions      nexus-context   dependency-track-upload   cosign-sign
(steps)                gitleaks-scan   checkov-scan   syft-sbom   grype-scan
```

One tool per action, on purpose: each scanner/signer is a composite action that
owns its pinned SHA, its input validation and its report handling, and the
reusable workflows only wire them together. A job that already exists in your
own repo can therefore drop in a single scanner step without adopting a whole
workflow.

- **Composite actions** = single-responsibility *steps* you drop into any job.
- **Reusable workflows** = whole *jobs* (`on: workflow_call`) you call with `uses:`.
- **Callers** = thin per-project workflows that own the *triggers* and delegate
  all the work.

## Catalog reference

### Composite actions (`.github/actions/`)

| Action | Purpose | Key inputs |
| --- | --- | --- |
| [`nexus-context`](../.github/actions/nexus-context/action.yml) | Configure pip + twine for a Nexus `dev`/`prod` context (writes `pip.conf` / `.pypirc`, exports `PIP_CONFIG_FILE` + `TWINE_REPOSITORY`). | `context` (dev/prod), `config-dir` |
| [`dependency-track-upload`](../.github/actions/dependency-track-upload/action.yml) | Upload a CycloneDX SBOM to Dependency-Track (`POST /api/v1/bom`). Language/tool-agnostic. | `bom-file`, `project-name`, `project-version`, `server-url`, `api-key` |
| [`cosign-sign`](../.github/actions/cosign-sign/action.yml) | Install Cosign and sign pushed image references by digest (key-based). Reuses the runner's registry logins. | `images`, `digest`, `private-key`, `password` |
| [`gitleaks-scan`](../.github/actions/gitleaks-scan/action.yml) | **Gitleaks** secret scan of the checked-out repo, scoped from the triggering event. Needs `fetch-depth: 0`. | `github-token`, `license` |
| [`checkov-scan`](../.github/actions/checkov-scan/action.yml) | **Checkov** IaC misconfiguration lint (Dockerfile, Kubernetes, Terraform, …). Wraps a *container* action — gate it at **job** level, not step level. | `file` / `directory`, `framework`, `soft-fail` |
| [`syft-sbom`](../.github/actions/syft-sbom/action.yml) | **Syft** SBOM of an image, directory or file, in CycloneDX by default. Outputs `bom-file` for `dependency-track-upload`. | `image` / `path` / `file`, `format`, `output-file`, `artifact-name` |
| [`grype-scan`](../.github/actions/grype-scan/action.yml) | **Grype** CVE gate on an image, directory or SBOM. Keeps the report even when the gate trips. | `image` / `path` / `sbom`, `severity-cutoff`, `fail-build`, `artifact-name` |

### Reusable workflows (`.github/workflows/`)

| Workflow | Type | Purpose |
| --- | --- | --- |
| [`python-ci.yml`](../.github/workflows/python-ci.yml) | primitive | Python **test → build → publish** to Nexus. Outputs `version`. |
| [`sbom.yml`](../.github/workflows/sbom.yml) | primitive | Package **CycloneDX SBOM → Dependency-Track** (consumes the `dist` artifact). |
| [`docker-build.yml`](../.github/workflows/docker-build.yml) | primitive | Language-agnostic **image build + push** (Nexus / GHCR / Docker Hub) with optional image SBOM → Dependency-Track, optional **Checkov** Dockerfile lint (`scan-dockerfile`), **Grype** CVE gate (`scan-image`), **Dockle** image-hardening lint (`lint-image`), and **Cosign** image signing (`sign-image`, release builds). |
| [`gitleaks.yml`](../.github/workflows/gitleaks.yml) | primitive | **Secret scanning** with Gitleaks. Dual-triggered: `workflow_call` (reusable) **and** `push`/`pull_request` (guards this repo). |
| [`node-workflow.yml`](../.github/workflows/node-workflow.yml) | all-in-one | Node/React **install → lint → build → test**, with optional npm SBOM and image build via toggles. |

### Callers

| Caller | Triggers | Purpose |
| --- | --- | --- |
| [`python-demo.yml`](../.github/workflows/python-demo.yml) | push `develop`, tags `x.y.z`, manual | Builds the in-repo `python-demo` project; the reference example. |

## Two composition styles

The catalog deliberately offers both — pick per project complexity:

**A. Composed primitives** (used by `python-demo.yml`). The caller wires several
small reusable workflows. Most flexible; best when the pipeline has bespoke
shape (e.g. `python-demo`'s two Docker modes — local-from-artifact on `develop`,
registry-from-Nexus on tags).

```yaml
jobs:
  ci:
    uses: CSC-Operations-Coordination-Service/workflow-catalog/.github/workflows/python-ci.yml@develop
    with: { project-dir: python-demo }
    secrets: inherit
  sbom:
    needs: ci
    if: startsWith(github.ref, 'refs/tags/')
    uses: CSC-Operations-Coordination-Service/workflow-catalog/.github/workflows/sbom.yml@develop
    with: { project-name: python-demo, project-version: ${{ needs.ci.outputs.version }} }
    secrets: inherit
  # ...docker-local / docker-registry call docker-build.yml
```

**B. All-in-one** (`node-workflow.yml`). One `uses:` with feature toggles. Least
wiring; best for the common case.

```yaml
jobs:
  frontend:
    uses: CSC-Operations-Coordination-Service/workflow-catalog/.github/workflows/node-workflow.yml@develop
    with:
      working-directory: frontend
      generate-sbom: true
      build-image: true
      image-name: frontend
      dockerfile: frontend/Dockerfile
    secrets: inherit
```

Either way, the shared building blocks (`docker-build.yml`,
`dependency-track-upload`, `nexus-context`) are the same.

## Use cases

1. **Release a Python package (image + SBOMs).** Push a tag `x.y.z`.
   `python-demo.yml` runs `ci` → `build`, then `sbom` (package SBOM → DT project
   `python-demo`) and `docker-registry` (image to Nexus/GHCR/Docker Hub + image
   SBOM → DT project `python-demo-image`). See
   [sbom-dependency-track.md](sbom-dependency-track.md).
2. **Manually build the develop image.** Actions tab → *python-demo CI/CD* →
   *Run workflow* on `develop`. See
   [manual-docker-build-develop.md](manual-docker-build-develop.md).
3. **Onboard a React/Node app (from another repo).** Add a thin caller that uses
   `node-workflow.yml`. See [node-workflow.md](node-workflow.md).
4. **Add SBOMs to an existing pipeline.** For images, pass `generate-sbom: true`
   (+ `sbom-project-*`) to `docker-build.yml`. For packages, call `sbom.yml`
   (Python) or set `generate-sbom: true` on `node-workflow.yml` (npm).
5. **Add a brand-new project to the catalog.** Drop the project in a
   subdirectory, add its `ci/` Nexus config if Python, and add a thin caller
   workflow. Reuse the existing primitives — no new plumbing.

## Conventions

- **Pinned actions + Dependabot.** All third-party actions are pinned to a full
  commit SHA with a `# vX.Y.Z` comment; [`dependabot.yml`](../.github/dependabot.yml)
  bumps them weekly. Never reintroduce floating `@v4`-style tags.
- **Nexus dev/prod contexts.** Release tags (`refs/tags/*`) use `prod` repos;
  everything else uses `dev`. Resolved by `nexus-context` (Python) and the
  `environment` input (`docker-build.yml`).
- **Dependency-Track project naming.** Keep `projectName` stable, let
  `projectVersion` track the release. Convention: `<name>` for the package,
  `<name>-image` for the image.
- **Secrets** are passed with `secrets: inherit`. Consolidated list:

  | Secret | Used by | For |
  | --- | --- | --- |
  | `NEXUS_USERNAME`, `NEXUS_PASSWORD` | python-ci, docker-build | Nexus PyPI publish + Docker registry auth; also the `netrc` build secret under `mount-pip-index` |
  | `NEXUS_HOST`, `NEXUS_PORT` | python-ci, docker-build (`mount-pip-index`) | pip index location, on the runner and inside image builds |
  | `NEXUS_DOCKER_REGISTRY_DEV`, `NEXUS_DOCKER_REGISTRY_PROD` | docker-build | Which Nexus Docker registry per context |
  | `SONAR_TOKEN`, `SONAR_HOST_URL` | python-ci | SonarQube scan |
  | `DEPENDENCYTRACK_URL`, `DEPENDENCYTRACK_API_KEY` | sbom, docker-build, node-workflow | SBOM upload (`BOM_UPLOAD` + `PROJECT_CREATION_UPLOAD` + `VIEW_PORTFOLIO`) |
  | `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN` | docker-build (`push-to-dockerhub`) | Docker Hub push |
  | `COSIGN_PRIVATE_KEY`, `COSIGN_PASSWORD` | docker-build (`sign-image`) | Cosign image signing (release builds) |
  | `GITLEAKS_LICENSE` | gitleaks | Required by gitleaks-action on organization repos (free for personal) |
  | `GITHUB_TOKEN` (automatic) | docker-build (`push-to-ghcr`), gitleaks | GHCR push; PR annotation |

## Cross-repo consumption caveat

The reusable workflows reference the composite actions by their **full**
`owner/repo/path@ref` form
(`uses: CSC-Operations-Coordination-Service/workflow-catalog/.github/actions/<name>@develop`),
never as `./.github/actions/<name>`. A local `./` path resolves against the
*caller's* checked-out workspace, not the catalog's, so it breaks the moment a
reusable workflow is consumed from another repository. Keep the full form when
you add an action reference, and bump the `@develop` refs together when the
catalog moves to a tag.

In your own jobs you can use either form: reference a catalog action with the
full form above, or check the catalog out and use a local path.

## Detailed docs

- [sbom-dependency-track.md](sbom-dependency-track.md) — SBOM generation & DT integration
- [security-scanning.md](security-scanning.md) — Gitleaks secret scanning, Grype image CVE gate & Cosign image signing
- [node-workflow.md](node-workflow.md) — the Node/React reusable workflow
- [manual-docker-build-develop.md](manual-docker-build-develop.md) — manual image builds on develop
- [docker-build-network.md](docker-build-network.md) — the three network hops of an image build on a runner with no internet egress (builder image, `FROM` resolution, push) and which input covers each
