# Manually building the develop Docker image

The python-demo caller
([`.github/workflows/python-demo.yml`](../.github/workflows/python-demo.yml))
can be triggered by hand to build and push the `develop` Docker image on
demand, in addition to its automatic triggers. It delegates the work to the
reusable building blocks — see the [catalog overview](README.md).

## When it runs

| Trigger | Result |
| --- | --- |
| Push to `develop` | `ci` (test → build) → `docker-local` (Nexus Docker registry) |
| Manual dispatch from `develop` | Same as above — full pipeline, image pushed to Nexus |
| Push of a release tag (`x.y.z`) | `ci` → `sbom` + `docker-registry` (Nexus + GHCR + Docker Hub) |

## How to trigger it manually

1. Open the repository on GitHub and go to the **Actions** tab.
2. Select the **python-demo CI/CD** workflow in the left-hand list.
3. Click **Run workflow**.
4. In the branch dropdown, choose **`develop`**.
5. Click **Run workflow** to start the run.

The run appears in the workflow list and executes `ci` (test → build) →
`docker-local`, pushing the resulting image to the Nexus Docker registry —
exactly the same path as an automatic `develop` push.

## Important notes

- **The full pipeline runs.** The `docker-local` job consumes the `dist`
  artifact produced by the `ci` job's build stage, which in turn depends on the
  test stage. Because of this artifact dependency, a manual trigger re-runs the
  tests and the wheel build too — it is not possible to run only the Docker step
  in isolation.
- **Public registries are not touched.** `docker-registry` (which pushes to
  GHCR and Docker Hub) is gated on release tags (`refs/tags/*`), so a manual
  run from `develop` only publishes to the Nexus Docker registry.
- **Branch matters.** The `docker-local` job is gated on
  `github.ref == 'refs/heads/develop'`, so the manual build only produces an
  image when dispatched from the `develop` branch.

## Underlying configuration

The manual trigger is enabled by the `workflow_dispatch` event in the
workflow's `on` block:

```yaml
on:
  push:
    branches:
      - "develop"
    tags:
      - "[0-9]+.[0-9]+.[0-9]+"
  workflow_dispatch: # manual trigger (e.g. build the develop Docker image on demand)
```
