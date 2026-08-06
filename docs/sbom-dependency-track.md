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
  `curl: (7) Failed to connect to *** port 5055 after 1 ms` — connect refused in
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
