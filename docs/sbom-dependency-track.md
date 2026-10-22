# SBOM generation & Dependency-Track integration

Every **release** (a git tag `x.y.z`) automatically produces CycloneDX SBOMs
(Software Bill of Materials) and uploads them to the team's **Dependency-Track**
instance for continuous vulnerability tracking. Uploads are **non-blocking** —
they never fail a release (no quality gate yet).

## What gets generated

Each release produces **two** SBOMs, tracked as **two separate Dependency-Track
projects** at the release version:

| Dependency-Track project | Source                         | Tool          | Produced in |
| ------------------------ | ------------------------------ | ------------- | ----------- |
| `python-demo-image`      | the released Docker image (OS packages + interpreter + installed wheels) | Syft | [docker-build.yml](../.github/workflows/docker-build.yml) (`docker-registry` job) |
| `python-demo`            | the Python package environment | `cyclonedx-py` | [sbom.yml](../.github/workflows/sbom.yml) (called by [python-demo.yml](../.github/workflows/python-demo.yml)) |

The **image SBOM is the high-signal one** — `python-demo` itself declares almost
no third-party runtime dependencies, so the meaningful inventory (and most CVEs)
comes from the `python:3.11-slim` base and everything pip installs into the image.
The package SBOM documents the app's own dependency graph and grows in value as
`install_requires` expands.

Both SBOMs are also attached to the workflow run as build artifacts
(`sbom-python-demo-image`, `sbom-python-demo-package`).

## How it fits the pipeline

```
push tag x.y.z  (python-demo.yml)
  └─ ci (python-ci.yml: test → build) ─┬─ sbom.yml         → DT project "python-demo"
                                       └─ docker-registry  → DT project "python-demo-image"
                                          (docker-build.yml: Syft + upload)
```

Develop builds are unaffected — SBOM generation is release-only.

## Required secrets

Set these as repository or organization secrets (forwarded to the reusable
workflow via `secrets: inherit`):

| Secret                    | Purpose |
| ------------------------- | ------- |
| `DEPENDENCYTRACK_URL`     | Base URL of the Dependency-Track API server (no trailing `/api`), e.g. `http://host.docker.internal:8081`. Must be reachable from the self-hosted runners, the same way Nexus is. |
| `DEPENDENCYTRACK_API_KEY` | A Dependency-Track team API key. For upload-only, it needs **`BOM_UPLOAD`**, **`PROJECT_CREATION_UPLOAD`**, and **`VIEW_PORTFOLIO`**. |

`sbom.yml` also reads `NEXUS_HOST`, `NEXUS_PORT`, `NEXUS_USERNAME` and
`NEXUS_PASSWORD` for its Nexus context (the `sbom` job installs the wheel and
tox through Nexus). Or, with `secrets-source: openbao`, all six values come
from OpenBao instead: [below](#secrets-from-openbao).

## Inputs of `sbom.yml`

| Input | Default | Purpose |
| --- | --- | --- |
| `project-dir` | `python-demo` | Directory holding the package (`tox.ini` with a `sbom` env) |
| `project-name` | — (required) | Dependency-Track project name, kept stable across releases |
| `project-version` | — (required) | Dependency-Track project version, usually the release version |
| `python-version` | `3.11` | Python image of the `sbom` job |
| `artifact-name` | `dist` | Distribution artifact to download (the one `python-ci.yml` uploads) |
| `context` | `prod` | Nexus context for the dependencies, `dev` or `prod`. In openbao mode it must match the build: `prod` on a tag build, `dev` on any other |
| `runs-on` | `self-hosted` | Runner label of both jobs. `containerized` in openbao mode (a single label; the input is a string, not a list) |
| `secrets-source` | `github` | `openbao`: read the Nexus and Dependency-Track values from OpenBao, and only from there (no fallback to `secrets.*`). Any value other than `github` or `openbao` stops the job at the step "Check secrets-source and openbao-tools", before any read |
| `openbao-url` / `openbao-role` | `https://openbao:8200` / — | OpenBao address and this repository's JWT role, `ci-<repo>` (the base name) |
| `openbao-tools` | — | Tools read from the devsecops layout instead of `ocs/ci/shared`: `nexus`, `dependency-track`, separated by single spaces on one line. An unknown name or another separator stops the job. See [openbao-secrets.md](openbao-secrets.md#the-devsecops-layout-openbao-tools) |

## Secrets from OpenBao

With `secrets-source: openbao`, the `sbom` job reads the four Nexus values and
the `publish` job the two Dependency-Track values from OpenBao, with the job's
GitHub OIDC token. The general rules, the two layouts and how an operator
stores the values are in [openbao-secrets.md](openbao-secrets.md). What is
particular to `sbom.yml`:

```yaml
jobs:
  sbom:
    needs: ci
    permissions:
      contents: read
      id-token: write
    uses: CSC-Operations-Coordination-Service/workflow-catalog/.github/workflows/sbom.yml@develop
    with:
      project-dir: .
      project-name: <package>
      project-version: ${{ needs.ci.outputs.version }}
      context: ${{ github.ref_type == 'tag' && 'prod' || 'dev' }}
      runs-on: containerized
      secrets-source: openbao
      openbao-role: ci-<repo>   # the repository's base role name
      openbao-tools: nexus dependency-track
    secrets: inherit
```

- **`context` follows the build.** A tag build reads
  `devsecops/ci/prod/<tool>` and logs in as `<openbao-role>-release`, any other
  build reads `devsecops/ci/dev/<tool>` as `<openbao-role>`. Each read passes
  `context` to the action as its `environment`, so for a tool listed in
  `openbao-tools` a `context` that disagrees stops the job at that read, before
  the login. The default, `prod`, would stop every branch build that lists a
  tool: pass the expression above. For a tool not listed, the `ocs/ci/shared`
  names serve both contexts and nothing checks it. The default stays `prod`
  all the same: callers in GitHub-secrets mode that pass no `context` (such as
  `python-demo.yml`, which runs `sbom.yml` on tag builds only) rely on it for
  their release SBOMs, and `tests/openbao_secrets_test.sh` pins it.
- **The caller job grants `id-token: write`.** `sbom.yml` has no
  `permissions:` block of its own: it takes what the calling job grants.
- **Where each job reaches OpenBao.** The `sbom` job's container joins the
  `ocs_openbao` network in openbao mode. The `publish` job has no container
  (see [Usage tips](#usage-tips)) and runs on the runner itself, which the
  containerized pool already has on that network.
- **The check runs once, first.** "Check secrets-source and openbao-tools", the
  same step as in the other workflows, runs in the `sbom` job before its read.
  `publish` needs `sbom`, so a refused input stops both before any read.
- **An empty Dependency-Track value.** In the ocs layout an empty
  `ocs/ci/shared/DEPENDENCYTRACK_URL` or `DEPENDENCYTRACK_API_KEY` is not
  caught by the read. The upload then stops on `server-url is empty` or
  `api-key is empty`, and its message names the GitHub secret, but in openbao
  mode the value comes from OpenBao. With `dependency-track` in
  `openbao-tools`, the read itself stops on an empty field.

Call `sbom.yml` at `@develop` or a release, as
[openbao-secrets.md](openbao-secrets.md#use-it-from-a-repository) says.

## The shared primitives

Two composite actions, split so either half can be swapped or reused alone:

- [`syft-sbom`](../.github/actions/syft-sbom/action.yml) — **generate** a
  CycloneDX SBOM with Syft from an image, a directory or a single file, and
  optionally attach it to the run. Outputs `bom-file`.
- [`dependency-track-upload`](../.github/actions/dependency-track-upload/action.yml)
  — **publish** a CycloneDX file to `${DEPENDENCYTRACK_URL}/api/v1/bom`.
  Tool-agnostic: it does not care whether Syft, `cyclonedx-py` or
  `cyclonedx-npm` produced the file, which is why the Python and npm SBOMs use
  their own generators and the same uploader.

Chained, that is the whole image-SBOM path in `docker-build.yml`:

```yaml
- id: sbom
  uses: CSC-Operations-Coordination-Service/workflow-catalog/.github/actions/syft-sbom@develop
  with:
    image: ${{ env.REGISTRY }}/my-component@${{ steps.build.outputs.digest }}
    output-file: sbom-image.cdx.json
    artifact-name: sbom-my-component-image

- uses: CSC-Operations-Coordination-Service/workflow-catalog/.github/actions/dependency-track-upload@develop
  with:
    bom-file: ${{ steps.sbom.outputs.bom-file }}
    project-name: my-component
    project-version: ${{ needs.build.outputs.version }}
    server-url: ${{ secrets.DEPENDENCYTRACK_URL }}
    api-key: ${{ secrets.DEPENDENCYTRACK_API_KEY }}
```

Pass the image **by digest**, as above: a tag can move between the push and the
scan, and an inventory recorded against the wrong image is worse than none.
`syft-sbom` warns when you give it a tag.

## Adding the upcoming React app

The design is deliberately language-agnostic:

1. **Image SBOM** — if the React app builds a Docker image via the reusable
   [docker-build.yml](../.github/workflows/docker-build.yml), just pass
   `generate-sbom: true` and `sbom-project-name: <react-app>-image` (plus
   `sbom-project-version`). Nothing else to write.
2. **Package/npm SBOM** — generate a CycloneDX file in the app's build job with
   `npx @cyclonedx/cyclonedx-npm --output-file bom.json`, then call the same
   composite action with `project-name: <react-app>`.

Because `autoCreate=true`, the first release of a new component creates its
Dependency-Track project automatically — no manual pre-registration.

## Usage tips

- **Project = name + version.** Keep `projectName` stable and let `projectVersion`
  track the release tag. Dependency-Track then shows a version timeline and the
  "affected versions" for each CVE.
- **Upload from the host, not from a job container.** Dependency-Track is an
  internal server; a job container has its own resolver and no route to a port
  published on the runner host, so the upload dies as
  `curl: (7) Failed to connect to *** port <port> after 1 ms` — connect refused in
  ~0 ms, i.e. nothing left the runner. Generate the SBOM wherever the build tools
  live, publish it as an artifact, and upload it from a job with no `container:`
  (`publish` in [sbom.yml](../.github/workflows/sbom.yml), `sbom-publish` in
  [node-workflow.yml](../.github/workflows/node-workflow.yml)). The alternative —
  `--add-host=host.docker.internal:host-gateway` on the container plus a URL
  pointing at that alias — only works when the server is on the runner host
  itself. The action preflights the connection and prints both causes.
- **Least-privilege API key.** Upload-only needs just `BOM_UPLOAD` +
  `PROJECT_CREATION_UPLOAD` + `VIEW_PORTFOLIO`. Add `VIEW_VULNERABILITY` /
  `POLICY_VIOLATION_*` only if/when you introduce a quality gate.
- **Continuous re-analysis is free.** Once a version's SBOM is uploaded,
  Dependency-Track keeps re-scanning it against newly-published CVEs — you get
  alerts on already-released versions without re-running CI. Wire up DT
  notifications (email / Slack / webhook) to take advantage of this.
- **Tag your DT projects** (e.g. `team:ocsproc`, `repo:workflow-catalog`) so you
  can drive portfolio-wide policies and dashboards once several components exist.
- **Adding a quality gate later** (deliberately out of scope now): after upload,
  poll the BOM-processing token and the project's policy-violation / metrics
  endpoints, then fail the job on violations. This needs the extra API-key
  permissions above.

## Local usage

Generate the package SBOM locally without CI:

```bash
cd python-demo
python -m venv .sbom-venv
.sbom-venv/bin/pip install dist/*.whl   # build first with: tox -e build
tox -e sbom -- .sbom-venv               # -> python-demo/sbom-python.cdx.json
```

Generate an image SBOM locally with Syft:

```bash
syft <image-ref> -o cyclonedx-json > sbom-image.cdx.json
```
