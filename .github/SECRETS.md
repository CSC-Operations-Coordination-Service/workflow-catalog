# Required GitHub Secrets

These secrets power the reusable workflows in this catalog — e.g.
[`python-ci.yml`](workflows/python-ci.yml), [`sbom.yml`](workflows/sbom.yml),
[`docker-build.yml`](workflows/docker-build.yml),
[`node-workflow.yml`](workflows/node-workflow.yml) — and their callers such as
[`python-demo.yml`](workflows/python-demo.yml). Add them under
**Settings → Secrets and variables → Actions → Repository secrets** (or at the
organization level so they're shared across repos). See the
[catalog overview](../docs/README.md) for how the pieces fit together.

The workflow picks **dev** vs **prod** automatically from the trigger:

| Trigger | Context |
| --- | --- |
| push to `develop` (and any non-tag ref) | `dev` |
| push of a release tag `x.y.z` | `prod` |

Repository **paths** live in committed config files
([`ci/.pypirc`](../python-demo/ci/.pypirc), [`ci/pip.*.conf`](../python-demo/ci/)),
which carry `${NEXUS_HOST}` / `${NEXUS_PORT}` placeholders; **the host, port and
all credentials come from secrets.** Neither pip nor twine expands variables
inside its own config file, so the
[`nexus-context`](actions/nexus-context/action.yml) action substitutes the
placeholders while rendering those files into `$HOME`.

## Nexus — location

| Secret | Used by | Description |
| --- | --- | --- |
| `NEXUS_HOST` | `nexus-context` (pip + twine config) | Bare hostname — **no scheme, no port, no path**, e.g. `oep-sysma-mondb-02.ocs.local`. Also becomes the `machine` entry in the generated `~/.netrc`. |
| `NEXUS_PORT` | `nexus-context` (pip + twine config) | Port only, e.g. `8081`. Leave unset for the scheme default (80/443) — the `:<port>` is then dropped from the URL. |

## Nexus — shared credentials

| Secret | Used by | Description |
| --- | --- | --- |
| `NEXUS_USERNAME` | pip (`~/.netrc`), twine publish, Docker login | Nexus account username (same for dev & prod). |
| `NEXUS_PASSWORD` | pip (`~/.netrc`), twine publish, Docker login | Nexus account password / token. |

> pip has no username/password environment variables, so index **reads** are
> authenticated with a `~/.netrc` that `nexus-context` generates at runtime
> (mode `0600`, never committed). The `machine` line holds the bare host with
> **no port** — pip strips the port before looking up the entry, so a
> `machine host:port` line silently never matches.

## Nexus — Docker registry (per context)

| Secret | Used by | Description |
| --- | --- | --- |
| `NEXUS_DOCKER_REGISTRY_DEV` | `docker-local` (develop) | Dev Docker registry `host:port` to push to, e.g. `127.0.0.1:8082`. No scheme, no image path. |
| `NEXUS_DOCKER_REGISTRY_PROD` | `docker-registry` (release tags) | Prod Docker registry `host:port`, e.g. `127.0.0.1:8084`. |

## Nexus — PyPI index for image builds (per context)

Only consumed when a build sets `mount-pip-index: true` (the release/registry
image build installs the published package by version). No dedicated secret is
needed: `docker-build.yml` composes both BuildKit secrets from `NEXUS_HOST`,
`NEXUS_PORT`, `NEXUS_USERNAME` and `NEXUS_PASSWORD` — the same four the
`nexus-context` action uses for CI-job pulls, so the index an image builds
against cannot drift from the one CI installs from.

| BuildKit secret | Contents | Mounted at |
| --- | --- | --- |
| `pip_index_url` | Credential-free simple index, `http://$NEXUS_HOST:$NEXUS_PORT/repository/pypi-<ctx>-group/simple` | read from `/run/secrets/pip_index_url` |
| `netrc` | `machine <host> / login / password` | `/root/.netrc` (0400, root) |

> Credentials stay **out of the URL** deliberately. A password containing `@`,
> `:`, `/` or `#` would need percent-encoding to survive as userinfo, and pip
> redacts only the password when it echoes an index URL. The netrc split avoids
> both problems, and mirrors how the runner already authenticates.
>
> **Retired:** `NEXUS_PYPI_INDEX_URL_DEV` / `NEXUS_PYPI_INDEX_URL_PROD`. They
> are no longer read and can be deleted. A Dockerfile consuming
> `mount-pip-index` must now mount the `netrc` secret:
>
> ```dockerfile
> RUN --mount=type=secret,id=pip_index_url \
>     --mount=type=secret,id=netrc,target=/root/.netrc \
>     ...
> ```

## Docker Hub (release only)

Used when `push-to-dockerhub: true` (release tags).

| Secret | Description |
| --- | --- |
| `DOCKERHUB_USERNAME` | Docker Hub username. |
| `DOCKERHUB_TOKEN` | Docker Hub access token (not your password). |

## Cosign (image signing)

Used by `docker-build.yml` when `sign-image: true` (release builds only). Key-based
signing — generate the keypair once with `cosign generate-key-pair`, then publish
`cosign.pub` so consumers can verify. See
[docs/security-scanning.md](../docs/security-scanning.md).

| Secret | Description |
| --- | --- |
| `COSIGN_PRIVATE_KEY` | Contents of the encrypted `cosign.key` private key. |
| `COSIGN_PASSWORD` | Password that decrypts the Cosign private key. |

## SonarQube

| Secret | Description |
| --- | --- |
| `SONAR_TOKEN` | SonarQube analysis token. |
| `SONAR_HOST_URL` | SonarQube server URL. |

## Dependency-Track (SBOM upload)

Consumed by [`sbom.yml`](workflows/sbom.yml), by `docker-build.yml` when
`generate-sbom: true`, and by `node-workflow.yml` when `generate-sbom: true`.
See [docs/sbom-dependency-track.md](../docs/sbom-dependency-track.md).

| Secret | Description |
| --- | --- |
| `DEPENDENCYTRACK_URL` | Base URL of the Dependency-Track API server (no trailing `/api`), reachable from the runners. |
| `DEPENDENCYTRACK_API_KEY` | Team API key with `BOM_UPLOAD` + `PROJECT_CREATION_UPLOAD` + `VIEW_PORTFOLIO`. |

## Gitleaks (secret scanning)

Consumed by [`gitleaks.yml`](workflows/gitleaks.yml). See
[docs/security-scanning.md](../docs/security-scanning.md).

| Secret | Description |
| --- | --- |
| `GITLEAKS_LICENSE` | Required by `gitleaks-action` on **organization** repos (free for personal repos). Get a key at <https://gitleaks.io> and add it as an **organization** secret so every repo shares it. |

> The `docker-build.yml` scanners — Checkov (`scan-dockerfile`), Grype
> (`scan-image`) and Dockle (`lint-image`) — need **no new secret**: Checkov
> runs offline, and Grype and Dockle reuse the Nexus registry login already
> configured for the image push.

## Provided automatically — no setup

| Secret | Notes |
| --- | --- |
| `GITHUB_TOKEN` | Injected by GitHub Actions. Used to push to GHCR when `push-to-ghcr: true`. The workflow already requests `packages: write` permission. |

## Quick checklist

- [ ] `NEXUS_HOST`
- [ ] `NEXUS_PORT`
- [ ] `NEXUS_USERNAME`
- [ ] `NEXUS_PASSWORD`
- [ ] `NEXUS_DOCKER_REGISTRY_DEV`
- [ ] `NEXUS_DOCKER_REGISTRY_PROD`
- [ ] `DOCKERHUB_USERNAME`
- [ ] `DOCKERHUB_TOKEN`
- [ ] `COSIGN_PRIVATE_KEY` (only when `sign-image: true`)
- [ ] `COSIGN_PASSWORD` (only when `sign-image: true`)
- [ ] `SONAR_TOKEN`
- [ ] `SONAR_HOST_URL`
- [ ] `DEPENDENCYTRACK_URL`
- [ ] `DEPENDENCYTRACK_API_KEY`
- [ ] `GITLEAKS_LICENSE` (org-level; gitleaks on organization repos)
