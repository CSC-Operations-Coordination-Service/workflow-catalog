# Required GitHub Secrets

These secrets power [`python-workflow.yml`](workflows/python-workflow.yml) and the
reusable [`docker-build.yml`](workflows/docker-build.yml). Add them under
**Settings → Secrets and variables → Actions → Repository secrets** (or at the
organization level so they're shared across repos).

The workflow picks **dev** vs **prod** automatically from the trigger:

| Trigger | Context |
| --- | --- |
| push to `develop` (and any non-tag ref) | `dev` |
| push of a release tag `x.y.z` | `prod` |

URLs live in committed config files ([`ci/.pypirc`](../python-demo/ci/.pypirc),
[`ci/pip.*.conf`](../python-demo/ci/)); **only credentials and host-specific
values belong in secrets.**

## Nexus — shared credentials

| Secret | Used by | Description |
| --- | --- | --- |
| `NEXUS_USERNAME` | twine publish, Docker login | Nexus account username (same for dev & prod). |
| `NEXUS_PASSWORD` | twine publish, Docker login | Nexus account password / token. |

## Nexus — Docker registry (per context)

| Secret | Used by | Description |
| --- | --- | --- |
| `NEXUS_DOCKER_REGISTRY_DEV` | `docker-local` (develop) | Dev Docker registry `host:port` to push to, e.g. `127.0.0.1:8082`. No scheme, no image path. |
| `NEXUS_DOCKER_REGISTRY_PROD` | `docker-registry` (release tags) | Prod Docker registry `host:port`, e.g. `127.0.0.1:8084`. |

## Nexus — PyPI index for image builds (per context)

Only consumed when a build sets `mount-pip-index: true` (the release/registry
image build installs the published package by version). Passed to BuildKit as a
secret so it never lands in an image layer.

| Secret | Used by | Description |
| --- | --- | --- |
| `NEXUS_PYPI_INDEX_URL_DEV` | `Dockerfile.registry` build (dev) | Full simple index URL **including credentials**, e.g. `http://user:pass@127.0.0.1:2375/repository/pypi-dev-group/simple`. |
| `NEXUS_PYPI_INDEX_URL_PROD` | `Dockerfile.registry` build (prod) | Same for the prod group, e.g. `http://user:pass@127.0.0.1:2375/repository/pypi-prod-group/simple`. |

> The committed `pip.*.conf` files are credential-free and used for the **CI
> job** pulls (`PIP_CONFIG_FILE`). These index-URL secrets are a separate,
> credential-bearing path used **inside the registry image build** only.

## Docker Hub (release only)

Used when `push-to-dockerhub: true` (release tags).

| Secret | Description |
| --- | --- |
| `DOCKERHUB_USERNAME` | Docker Hub username. |
| `DOCKERHUB_TOKEN` | Docker Hub access token (not your password). |

## SonarQube

| Secret | Description |
| --- | --- |
| `SONAR_TOKEN` | SonarQube analysis token. |
| `SONAR_HOST_URL` | SonarQube server URL. |

## Provided automatically — no setup

| Secret | Notes |
| --- | --- |
| `GITHUB_TOKEN` | Injected by GitHub Actions. Used to push to GHCR when `push-to-ghcr: true`. The workflow already requests `packages: write` permission. |

## Quick checklist

- [ ] `NEXUS_USERNAME`
- [ ] `NEXUS_PASSWORD`
- [ ] `NEXUS_DOCKER_REGISTRY_DEV`
- [ ] `NEXUS_DOCKER_REGISTRY_PROD`
- [ ] `NEXUS_PYPI_INDEX_URL_DEV`
- [ ] `NEXUS_PYPI_INDEX_URL_PROD`
- [ ] `DOCKERHUB_USERNAME`
- [ ] `DOCKERHUB_TOKEN`
- [ ] `SONAR_TOKEN`
- [ ] `SONAR_HOST_URL`
