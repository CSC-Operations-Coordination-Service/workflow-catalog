# workflow-catalog

A catalog of **composable GitHub Actions building blocks** — reusable workflows
and composite actions — shared across projects (Python, Node/React) and consumed
both in this repo and from other repositories.

## Start here

📖 **[docs/README.md](docs/README.md)** — the catalog overview: architecture, the
full building-block reference, composition styles, use cases, and conventions.

## Building blocks at a glance

| Component | Type | Purpose |
| --- | --- | --- |
| [`python-ci.yml`](.github/workflows/python-ci.yml) | reusable workflow | Python test → build → publish (Nexus) |
| [`sbom.yml`](.github/workflows/sbom.yml) | reusable workflow | Package CycloneDX SBOM → Dependency-Track |
| [`docker-build.yml`](.github/workflows/docker-build.yml) | reusable workflow | Image build + push (+ image SBOM, + optional Checkov/Grype/Dockle scans, + optional Cosign signing) |
| [`gitleaks.yml`](.github/workflows/gitleaks.yml) | reusable workflow | Secret scanning (Gitleaks) — reusable + self-triggering |
| [`node-workflow.yml`](.github/workflows/node-workflow.yml) | reusable workflow | Node/React CI (all-in-one, toggleable) |
| [`nexus-context`](.github/actions/nexus-context/action.yml) | composite action | pip/twine config for a Nexus dev/prod context |
| [`dependency-track-upload`](.github/actions/dependency-track-upload/action.yml) | composite action | Upload a CycloneDX SBOM to Dependency-Track |
| [`python-demo.yml`](.github/workflows/python-demo.yml) | caller | Builds the in-repo `python-demo` example |

## Docs

- [CI/CD catalog overview](docs/README.md)
- [Required secrets](.github/SECRETS.md)
- [SBOM & Dependency-Track](docs/sbom-dependency-track.md)
- [Security scanning (Gitleaks & Grype)](docs/security-scanning.md)
- [Node/React reusable workflow](docs/node-workflow.md)
- [Manual develop image builds](docs/manual-docker-build-develop.md)

## `python-demo`

The [`python-demo`](python-demo) package is a PyScaffold-generated example that
exercises the catalog end-to-end. See [PYTHON.md](PYTHON.md) for local setup.
