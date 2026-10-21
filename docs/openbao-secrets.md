# Secrets from OpenBao (private repositories)

Organization secrets cannot be used by private repositories on our plan. For
those, the catalog workflows can read the same values from OpenBao instead, with
the job's own GitHub OIDC token: no vault token and no other secret is stored in
the repository.

Applies to `node-workflow.yml`, `docker-build.yml` and `python-ci.yml`. Default
behaviour is unchanged: without the inputs below every value still comes from
`secrets.*`, as before.

## What the caller sets

| Input | Default | Purpose |
| --- | --- | --- |
| `secrets-source` | `github` | `openbao` reads the values from OpenBao |
| `openbao-url` | `https://openbao:8200` | Reachable from the runner pool only (overlay `ocs_openbao`) |
| `openbao-role` | — | The repository's JWT role, e.g. `ci-ocs-operator-app` |
| `openbao-tools` | — | Tools read from the [devsecops layout](#the-devsecops-layout-openbao-tools), space-separated on one line. Empty: every value from `ocs/ci/shared`, as before |
| `runs-on` | `self-hosted` | Use `containerized` (a single label; the input is a string, not a list) |

Two things the **caller job** must do, because a reusable workflow cannot grant
itself more than its caller:

1. `permissions: id-token: write` (GitHub signs the OIDC token only then).
2. Spell out the rest it needs: `contents: read` and `packages: write`. The
   `docker` jobs of `docker-build.yml` and `node-workflow.yml` no longer have a
   `permissions:` block of their own (a block asking for `id-token: write` would
   fail every caller that does not grant it, openbao or not), so they take
   exactly what the calling job grants. Grant no more than that.

```yaml
jobs:
  node:
    permissions:
      contents: read
      packages: write
      id-token: write
    uses: CSC-Operations-Coordination-Service/workflow-catalog/.github/workflows/node-workflow.yml@develop
    with:
      runs-on: containerized
      secrets-source: openbao
      openbao-role: ci-ocs-operator-app
    secrets: inherit
```

## Where the values live

Two layouts. A tool listed in `openbao-tools` comes from the
[devsecops layout](#the-devsecops-layout-openbao-tools); everything else from
the ocs layout below. One repository can move one tool at a time.

### The ocs layout

kv-v2 mount `ocs`, one secret per name, the value in the key `value`:

| Path | Read by |
| --- | --- |
| `ocs/ci/shared/<NAME>` (`NEXUS_HOST`, `NEXUS_PASSWORD`, `DOCKERHUB_TOKEN`, ...) | every CI role |
| `ocs/ci/<repository>/<NAME>` | that repository's role only |

An operator writes them (`bao kv put ocs/ci/shared/NEXUS_PASSWORD value=-`), never
a pipeline. Roles and policies are in csc-ocs-ansible
(`stacks/platform/openbao/openbao-config.yml`).

### The devsecops layout (`openbao-tools`)

kv-v2 mount `devsecops`, one secret per tool, its fields inside:

| Path | Read by |
| --- | --- |
| `devsecops/ci/dev/<tool>` | `ci-<repo>`: every build that is not a tag |
| `devsecops/ci/prod/<tool>` | `ci-<repo>-release`: tag builds only |

The build kind decides both, from `github.ref_type`: a tag build reads `prod`
and logs in as `<openbao-role>-release`, any other build reads `dev` and logs in
as `<openbao-role>`. The caller passes the base role name only. So a branch build
never holds the credentials that publish prod artifacts.

`docker-build.yml`'s `environment` input must agree: `dev` on a branch build,
`prod` on a tag build. A mismatch stops the job at the OpenBao read, with a
message, before anything is built (a dev build gets no prod registry, and the
reverse).

Each field arrives as the variable the workflows already read, masked:

| Tool | Field → variable |
| --- | --- |
| `nexus` | `host` → `NEXUS_HOST`, `port` → `NEXUS_PORT`, `username` → `NEXUS_USERNAME`, `password` → `NEXUS_PASSWORD`, `docker_registry` → `NEXUS_DOCKER_REGISTRY_DEV` (dev) or `NEXUS_DOCKER_REGISTRY_PROD` (prod), `goproxy` → `GOPROXY` |
| `sonarqube` | `url` → `SONAR_HOST_URL`, `token` → `SONAR_TOKEN` |
| `dependency-track` | `url` → `DEPENDENCYTRACK_URL`, `api_key` → `DEPENDENCYTRACK_API_KEY` |
| `dockerhub` | `username` → `DOCKERHUB_USERNAME`, `token` → `DOCKERHUB_TOKEN` |
| `cosign` | `private_key` → `COSIGN_PRIVATE_KEY`, `password` → `COSIGN_PASSWORD` |

This map is the contract with csc-ocs-ansible, whose `scripts/ci-secrets` writes
the secrets: change both together. A field missing from a secret is not
exported, and other fields are ignored. A listed tool whose secret cannot be read
stops the job: it is never skipped.

### Test it from a pilot repository

While the branch `ci/devsecops-secrets` is under test, call the catalog at that
ref. Its own workflows call the action and `docker-build.yml` at the same ref.

```yaml
jobs:
  node:
    permissions:
      contents: read
      packages: write
      id-token: write
    uses: CSC-Operations-Coordination-Service/workflow-catalog/.github/workflows/node-workflow.yml@ci/devsecops-secrets
    with:
      runs-on: containerized
      secrets-source: openbao
      openbao-role: ci-ocs-operator-app
      openbao-tools: nexus sonarqube dependency-track
    secrets: inherit
```

1. A push to a branch exercises `ci-<repo>` and `devsecops/ci/dev/*`. The read
   step logs, without values, which variables it exported per tool.
2. A version tag exercises `ci-<repo>-release` and `devsecops/ci/prod/*`. Set
   the image build's environment to `prod` (`docker-environment: prod` here).
3. Expected failures, worth seeing once: a branch build with
   `docker-environment: prod` stops at the read; a tool whose secret does not
   exist stops the job naming its path.

Before the branch is merged, every `@ci/devsecops-secrets` ref inside the
catalog goes back to `@develop`, and the pilots move to `@develop` with it.

The action's devsecops read can be tested locally against a mock OpenBao:
`bash tests/openbao_secrets_tools_test.sh` (node, openssl and PyYAML; no
network).

## The action

[`openbao-secrets`](../.github/actions/openbao-secrets/action.yml) does the login
and exports the names as masked environment variables (`shared` / `repo` names
in the ocs layout, `tools` in the devsecops layout; one call takes one layout). A job of your own can use
it directly for repository-specific secrets (`repo:` input). If OpenBao cannot be
read, the job stops with a message that names OpenBao and lists what to check; the
first thing to check is whether OpenBao is **sealed** (it is unsealed by hand
after any restart).

A job with `container:` is a sibling container on the node and is not on the
OpenBao overlay: the reusable workflows add `options: --network ocs_openbao` in
openbao mode. Do the same in a `container:` job of your own.
