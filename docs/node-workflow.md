# Node.js reusable workflow

[`.github/workflows/node-workflow.yml`](../.github/workflows/node-workflow.yml) is a
generic, project-agnostic Node.js CI workflow — the Node counterpart of the Python
pipeline. It is a **reusable** workflow (`on: workflow_call`) that other
repositories reference with `uses:`, and it packs the whole pipeline behind
feature toggles (the "all-in-one" style). The Python side instead offers
composable primitives ([`python-ci.yml`](../.github/workflows/python-ci.yml),
[`sbom.yml`](../.github/workflows/sbom.yml)) wired by a thin caller
([`python-demo.yml`](../.github/workflows/python-demo.yml)). Both styles share
the same building blocks — see the [catalog overview](README.md).

## Pipeline

```
install → lint → build → test → (optional npm SBOM → Dependency-Track)
                                 → (optional Docker image via docker-build.yml)
```

Each step is individually toggleable via inputs; the image build reuses the same
language-agnostic [`docker-build.yml`](../.github/workflows/docker-build.yml), and the
SBOM upload reuses the [`dependency-track-upload`](../.github/actions/dependency-track-upload/action.yml)
composite action.

## How to consume it from another repo

Add a thin caller workflow. It owns the triggers; the reusable workflow owns the steps.

```yaml
name: my-frontend CI
on:
  push:
    branches: ["develop"]
    tags: ["[0-9]+.[0-9]+.[0-9]+"]
    paths: ["frontend/**"]
  pull_request:
    paths: ["frontend/**"]
  workflow_dispatch:

jobs:
  frontend:
    uses: CSC-Operations-Coordination-Service/workflow-catalog/.github/workflows/node-workflow.yml@develop
    with:
      working-directory: frontend
      node-version: "22"
      run-tests: false
    secrets: inherit
```

> Pin `@develop` for the latest, or a tag (e.g. `@1.2.3`) for reproducibility once the
> catalog is released.

## Inputs

| Input | Default | Purpose |
| --- | --- | --- |
| `working-directory` (required) | — | Directory containing `package.json` |
| `node-version` | `22` | Node major / `node:<v>` container tag |
| `runs-on` | `self-hosted` | Runner label |
| `install-command` | `npm ci` | Dependency install |
| `run-lint` / `lint-command` | `true` / `npm run lint` | Lint step |
| `run-build` / `build-command` | `true` / `npm run build` | Build step |
| `run-tests` / `test-command` | `false` / `npm test` | Test step (off by default) |
| `build-env` | `""` | Newline-separated `KEY=VALUE` exported before build/test (CI build defaults) |
| `generate-sbom` | `false` | CycloneDX npm SBOM → Dependency-Track |
| `sbom-project-name` / `sbom-project-version` | package name / — | DT project identity |
| `build-image` | `false` | Build + push an image via `docker-build.yml` |
| `image-name`, `dockerfile`, `docker-context`, `docker-build-args` | — | Image build params |
| `docker-release`, `push-to-ghcr`, `push-to-dockerhub`, `docker-environment` | `false`/`false`/`false`/`dev` | Registry/tagging behaviour |

## Secrets

Provide with `secrets: inherit`. Consumed only when the matching feature is enabled:
`DEPENDENCYTRACK_URL`, `DEPENDENCYTRACK_API_KEY` (SBOM); `NEXUS_DOCKER_REGISTRY_DEV/_PROD`,
`NEXUS_USERNAME`, `NEXUS_PASSWORD`, `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN` (image).
