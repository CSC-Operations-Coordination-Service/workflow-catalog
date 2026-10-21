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
(optional Nexus registry) → install → lint → build → test
                          → (optional npm SBOM → Dependency-Track)
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
| `runs-on` | `self-hosted` | Runner label (a single label; `containerized` for the container runner pool) |
| `secrets-source` | `github` | `openbao`: read the Nexus / Dependency-Track / Docker Hub / Cosign values from OpenBao instead of `secrets.*`, and only from there (no fallback to `secrets.*`). The caller job then needs `permissions: id-token: write`. Any value other than `github` or `openbao` stops the job. See [openbao-secrets.md](openbao-secrets.md) |
| `openbao-url` / `openbao-role` | `https://openbao:8200` / — | OpenBao address and this repository's JWT role (`secrets-source: openbao`) |
| `openbao-tools` | — | Tools read from the devsecops layout instead of `ocs/ci/shared`, separated by single spaces on one line (`nexus dependency-track`); an unknown name or another separator stops the job. Forwarded to the image build. With `sign-image` on a `docker-release` build it must list `cosign`, which the image build reads alone, right before the signature, on a tag build with `docker-environment: prod` only; otherwise the job stops before the Node build ([the signing key](openbao-secrets.md#the-signing-key-cosign)). See [openbao-secrets.md](openbao-secrets.md#the-devsecops-layout-openbao-tools) |
| `use-nexus-registry` | `false` | Install from the organization's Nexus npm registry instead of registry.npmjs.org. Also forwarded to the image build as `mount-npm-registry` |
| `npm-registry-repo` | `npm-proxy` | Nexus repository serving npm packages (a proxy of registry.npmjs.org, or a group including one) |
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

## Installing through Nexus

`use-nexus-registry: true` routes npm at the organization's Nexus registry — the
same idea as `nexus-context` on the Python side, reading the same organization
secrets, so nothing about the registry is committed to a consuming repo.

It covers **both** halves of the pipeline from one toggle:

- the [`npm-context`](../.github/actions/npm-context/action.yml) action configures
  the `install-command` step on the runner;
- `mount-npm-registry` is forwarded to `docker-build.yml`, so a Dockerfile running
  `npm ci` resolves through Nexus too — provided it mounts the secret:

  ```dockerfile
  RUN --mount=type=secret,id=npmrc,target=/root/.npmrc npm ci
  ```

This is required on runners without direct internet egress, where a `RUN` step
inherits neither BuildKit's mirror nor its proxy — see
[docker-build-network.md](docker-build-network.md), hop 3. It is worth enabling
regardless, so what CI installs cannot drift from what the image installs.

Credentials are optional: a Nexus npm proxy is commonly readable anonymously, and
the auth line is written only when `NEXUS_USERNAME` and `NEXUS_PASSWORD` are both
set. The step logs which mode it used.

## Secrets

Provide with `secrets: inherit` (or, for a private repository, `secrets-source: openbao`: [openbao-secrets.md](openbao-secrets.md)). Consumed only when the matching feature is enabled:
`NEXUS_HOST`, `NEXUS_PORT`, `NEXUS_USERNAME`, `NEXUS_PASSWORD` (`use-nexus-registry`);
`DEPENDENCYTRACK_URL`, `DEPENDENCYTRACK_API_KEY` (SBOM); `NEXUS_DOCKER_REGISTRY_DEV/_PROD`,
`NEXUS_USERNAME`, `NEXUS_PASSWORD`, `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN` (image).
