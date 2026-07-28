# Connectivity check

[`connectivity-check.yml`](../.github/workflows/connectivity-check.yml) probes every
component the catalog talks to, from the runner, in one run. Use it when a
pipeline fails with an opaque `401`/`403`/timeout, or after rotating a secret, to
confirm the credential that *arrives in CI* is the one you meant to store.

Run it from **Actions → Connectivity check → Run workflow**, or call it from
another workflow:

```yaml
jobs:
  preflight:
    uses: CSC-Operations-Coordination-Service/workflow-catalog/.github/workflows/connectivity-check.yml@develop
    secrets: inherit
```

## What it checks

| Check | Call it makes | Proves |
| --- | --- | --- |
| Secret inventory | none | Which secrets arrive, their length and a truncated hash |
| SonarQube | `GET /api/system/status`, `GET /api/v2/analysis/version` | Which instance answers, and that `SONAR_TOKEN` authenticates — the first call `sonar-scanner` makes |
| Nexus | `GET /service/rest/v1/status`, `/status/writable`, `/repository/pypi-*-group/simple/`, `/repository/pypi-{dev,prod}/`, `/service/rest/v1/repositories` | Nexus is up and writable, `NEXUS_USERNAME`/`NEXUS_PASSWORD` can read the group indexes pip uses, the twine targets exist |
| Nexus Docker | `GET http://<registry>/v2/` | The Docker connector ports are reachable and accept the Nexus credentials |
| Dependency-Track | `GET /api/version`, `GET /api/v1/project?limit=1` | The API server answers and the API key holds `VIEW_PORTFOLIO` |
| Docker Hub | `GET auth.docker.io/token?...` | `DOCKERHUB_TOKEN` is accepted (skipped when unset — release path only) |
| Egress | `binaries.sonarsource.com`, `api.github.com`, `ghcr.io/v2/` | The proxy lets the scanner download and the registries through |

Every check runs even when an earlier one fails, so one run gives the whole
picture. The final step writes a pass/fail table to the run summary and fails
the job if any required check failed.

## Reading a failure

Each error names the component, the HTTP status and the likely cause, for
example:

```
::error::pypi-dev-group: Nexus rejected NEXUS_USERNAME/NEXUS_PASSWORD (HTTP 401).
::error::NEXUS_DOCKER_REGISTRY_DEV: no connection — the Docker connector port must be
         published and reachable from the runner (this is the Squid / insecure-registries trap).
```

`000` always means *no HTTP response at all* — DNS, routing, a closed port or a
proxy — as opposed to `401`/`403`, which means the component answered and
rejected the credential.

## Comparing a secret without revealing it

The inventory prints, per secret, a length and the first 12 hex characters of its
SHA-256:

```
SONAR_TOKEN: len=44 sha256=6779bba7920f
```

Neither value is reversible, and GitHub's masking is unaffected. On the machine
holding the value you *intended* to store, run:

```bash
printf '%s' "$SONAR_TOKEN" | sha256sum | cut -c1-12
```

If the two fingerprints differ, CI is being handed a different value than you
edited. That happens because a higher-precedence copy wins: **environment >
repository > organization**, and the **Actions**, **Codespaces** and
**Dependabot** tabs are three separate stores that can each hold the same name.
The *Updated N ago* timestamp in each secret list tells you which copy you
actually changed.

Length alone is often enough: `0` means the secret never reached the job (an
organization secret whose access list omits the repo yields an empty string
silently), and a SonarQube token that is `45` or longer has stray whitespace —
they are 44 characters (`sqa_`/`sqp_`/`squ_` plus 40).

## Why it runs where it does

The job runs on `self-hosted` inside `python:3.11`, the same vantage point as the
real pipelines, so DNS, routing and proxy behaviour match what they see. Internal
components are queried with `--noproxy '*'` — they are on the OCS network and must
never be routed through the egress proxy — while only the egress checks are
allowed through it.

One consequence worth knowing: if a Docker registry secret points at a loopback
address, the check probes `host.docker.internal` instead. A loopback registry
works during a real push because the **daemon on the runner host** resolves it,
whereas inside the job container loopback is the container itself.
