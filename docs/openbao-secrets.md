# Secrets from OpenBao

Instead of repository or organization secrets, the catalog workflows can read
the same values from OpenBao, with the job's own GitHub OIDC token: no vault
token and no other secret is stored in the repository, and OpenBao is the one
place an operator keeps them up to date. Any repository with a JWT role in
OpenBao can use it, public or private.

A public repository also runs its workflows for pull requests from forks.
GitHub gives such a run a read-only token, and the OIDC token needs
`id-token: write`, so it cannot log in to OpenBao, whatever the role allows.
That is GitHub's documented behaviour, not yet tried here with a pull request
from a fork. It does not hold for the events that a fork's pull request can
start but that run in the base repository's context, with its token and
permissions: `pull_request_target`, `workflow_run` (a run that follows the
fork's workflow), and `issue_comment` on the pull request, for example. Such a
run gets an OIDC token whenever its workflow grants `id-token: write`. Never
call a workflow in openbao mode from any of them.

Applies to `node-workflow.yml`, `docker-build.yml`, `python-ci.yml` and
`sbom.yml`. Default behaviour is unchanged: without the inputs below every
value still comes from `secrets.*`, as before.

With `secrets-source: openbao`, OpenBao is the only source. A value it does not
give is empty: the workflows never fall back to `secrets.*`, even with
`secrets: inherit`. What the OpenBao read itself stops the job on:

| Gap in OpenBao | ocs layout (vault-action) | devsecops layout (`openbao-tools`) |
| --- | --- | --- |
| Failed login, or a path that does not exist or that the role may not read | stops the job | stops the job |
| A secret without its key `value`, or a tool's secret without a required field | stops the job | stops the job |
| That key or field stored empty or blank | **not caught**: exported as an empty or blank variable | stops the job, also for a `repo` name's `value` |

In the ocs layout an empty value goes on until a step needs it.
`python-ci.yml`'s SonarQube preflight stops on an empty URL or token and names
the OpenBao path. Anywhere else it surfaces later, as a failed login or an empty
URL.

## What the caller sets

| Input | Default | Purpose |
| --- | --- | --- |
| `secrets-source` | `github` | `openbao` reads the values from OpenBao. Any other value (`open-bao`, `OpenBao`, empty) stops the job at the step "Check secrets-source and openbao-tools", before any read |
| `openbao-url` | `https://openbao:8200` | Reachable from the runner pool only (overlay `ocs_openbao`). `https://` only: any other scheme stops the job before the login, which would send the job's token in clear |
| `openbao-role` | — | The repository's JWT role, `ci-<repo>` (the base name: in the devsecops layout the action adds `-release` or `-sign` itself) |
| `openbao-tools` | — | Tools read from the [devsecops layout](#the-devsecops-layout-openbao-tools), separated by single spaces on one line (`nexus sonarqube`). An unknown name, a comma, a tab or a newline stops the job at the step "Check secrets-source and openbao-tools". Empty: every value from `ocs/ci/shared`, as before. With `sign-image` on a `release` build, `cosign` is required, and so are a tag build and `environment: prod` ([the signing key](#the-signing-key-cosign)) |
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
      openbao-role: ci-<repo>   # the repository's base role name
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

An operator writes them, never a pipeline: `ocs/ci/shared/<NAME>` with the
platform repository's CI-secrets tool (its default layout) or by hand,
`ocs/ci/<repository>/<NAME>` by hand only. By hand, the value goes in from
stdin: `bao kv put ocs/ci/shared/NEXUS_PASSWORD value=-`. Roles and policies
are in the platform repository's OpenBao configuration.

The names each workflow reads from `ocs/ci/shared`, for a tool not listed in
`openbao-tools`. Every name read must exist: one missing path stops the read.
The job's error lists the paths it needed, and the log gives, per path, the
`bao kv metadata get -mount=ocs ...` command that shows whether it exists,
without its value.

| Workflow | When | Names under `ocs/ci/shared` |
| --- | --- | --- |
| `node-workflow.yml` | `use-nexus-registry` | `NEXUS_HOST`, `NEXUS_PORT`, `NEXUS_USERNAME`, `NEXUS_PASSWORD` |
| `node-workflow.yml` | `generate-sbom` | `DEPENDENCYTRACK_URL`, `DEPENDENCYTRACK_API_KEY` |
| `docker-build.yml` | always | `NEXUS_HOST`, `NEXUS_PORT`, `NEXUS_USERNAME`, `NEXUS_PASSWORD`, `NEXUS_DOCKER_REGISTRY_DEV`, `NEXUS_DOCKER_REGISTRY_PROD` |
| `docker-build.yml` | `push-to-dockerhub` | `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN` |
| `docker-build.yml` | `generate-sbom` | `DEPENDENCYTRACK_URL`, `DEPENDENCYTRACK_API_KEY` |
| `docker-build.yml` | `sign-image` on a `release` build | none: the signing key comes from the devsecops layout only, with `cosign` in `openbao-tools` ([the signing key](#the-signing-key-cosign)) |
| `python-ci.yml` | always | `NEXUS_HOST`, `NEXUS_PORT`, `NEXUS_USERNAME`, `NEXUS_PASSWORD`, `SONAR_TOKEN`, `SONAR_HOST_URL` |
| `sbom.yml` | always (job `sbom`) | `NEXUS_HOST`, `NEXUS_PORT`, `NEXUS_USERNAME`, `NEXUS_PASSWORD` |
| `sbom.yml` | always (job `publish`) | `DEPENDENCYTRACK_URL`, `DEPENDENCYTRACK_API_KEY` |

`python-ci.yml` needs `ocs/ci/shared/SONAR_HOST_URL`. The platform
repository's CI-secrets tool stores it, in its default layout (it removes a
trailing `/`, which `python-ci.yml` refuses). Run it as a dry run first: it
reads OpenBao, says what it would store, and writes nothing. Its own
documentation, in the platform repository, says how.

While `ocs/ci/shared/SONAR_HOST_URL` is not stored, the `sonarqube` job of a
`python-ci.yml` caller in openbao mode stops at its OpenBao read, unless the
caller lists `sonarqube` in `openbao-tools`: the URL and token then come from
`devsecops/ci/<dev|prod>/sonarqube`, which must be stored instead.
`bao kv metadata get -mount=ocs ci/shared/SONAR_HOST_URL` shows whether it
exists, without its value.

### The devsecops layout (`openbao-tools`)

kv-v2 mount `devsecops`, one secret per tool, its fields inside:

| Path | Read by |
| --- | --- |
| `devsecops/ci/dev/<tool>` | `ci-<repo>`: every build that is not a tag |
| `devsecops/ci/prod/<tool>`, but `cosign` | `ci-<repo>-release`: tag builds only |
| `devsecops/ci/prod/cosign` | `ci-<repo>-sign` only: tag builds, in a job of the catalog's `docker-build.yml` ([the signing key](#the-signing-key-cosign)) |

The build kind decides both, from `github.ref_type`: a tag build reads `prod`
and logs in as `<openbao-role>-release`, any other build reads `dev` and logs in
as `<openbao-role>`. The caller passes the base role name only. So a branch build
never holds the credentials that publish prod artifacts. The signing key is the
exception: it is read alone, as `<openbao-role>-sign`.

`docker-build.yml`'s `environment` input must agree: `dev` on a branch build,
`prod` on a tag build. The action refuses a mismatch, with a message, at any
devsecops read (a dev build gets no prod registry, and the reverse). The reads
at the start of the job come before anything is built, but they check the
environment only for the tools listed in `openbao-tools`: with `nexus` not
listed, the Nexus read uses the ocs layout and checks nothing. The Cosign read
comes after the push. So when a build signs in openbao mode,
"Check secrets-source and openbao-tools" refuses an `environment` other than
`prod` itself, before anything is built. A build that does not sign, with no
devsecops tool listed, is not checked: the ocs layout serves both registries.

`sbom.yml`'s `context` input follows the same rule. Each of its reads passes
`context` to the action as `environment`, so with `nexus` or
`dependency-track` listed, a `context` that disagrees with the build stops the
job at that read, before the login (the message names `environment`). The
Nexus read comes before anything is installed. The default, `prod`, stops a
branch build in openbao mode with a devsecops tool listed: pass `context` from
the build kind, as in
[sbom-dependency-track.md](sbom-dependency-track.md#secrets-from-openbao). With
no tool listed nothing checks it, as above. `python-ci.yml` has no such input:
it takes the context from the ref itself.

Each field arrives as the variable the workflows already read, masked:

| Tool | Field → variable | Required |
| --- | --- | --- |
| `nexus` | `host` → `NEXUS_HOST`, `port` → `NEXUS_PORT`, `username` → `NEXUS_USERNAME`, `password` → `NEXUS_PASSWORD`, `docker_registry` → `NEXUS_DOCKER_REGISTRY_DEV` (dev) or `NEXUS_DOCKER_REGISTRY_PROD` (prod), `goproxy` → `GOPROXY` | all but `goproxy` |
| `sonarqube` | `url` → `SONAR_HOST_URL`, `token` → `SONAR_TOKEN` | both |
| `dependency-track` | `url` → `DEPENDENCYTRACK_URL`, `api_key` → `DEPENDENCYTRACK_API_KEY` | both |
| `dockerhub` | `username` → `DOCKERHUB_USERNAME`, `token` → `DOCKERHUB_TOKEN` | both |
| `cosign` | `private_key` → `COSIGN_PRIVATE_KEY`, `password` → `COSIGN_PASSWORD` | both |

A required field that is absent, blank, or not a string or number stops the job
before anything is exported. The error names the path and the fields, never a
value. `goproxy` is the one optional field: only Go builds use it. Other fields
are ignored. A listed tool whose secret cannot be read stops the job: it is never
skipped.

`docker-build.yml` reads `cosign` only on a tag build with `sign-image` and
`release`, the only builds that sign in openbao mode. There is no
`devsecops/ci/dev/cosign`: the action refuses `cosign` on any other build.

This map is the contract with the platform repository's CI-secrets tool:
change both together. An operator writes each secret, never a pipeline, in one
of two ways.

With the platform repository's CI-secrets tool, in its devsecops layout. Its
components have the tool names above. Run it as a dry run first: it reads
OpenBao, says what it would store, and writes nothing. Its own documentation,
in the platform repository, gives the commands and where each field comes
from.

Or by hand, with `bao kv put -mount=devsecops ci/<dev|prod>/<tool> ...`.
A secret value goes in from stdin (`field=-`, typed or piped, one per command)
or from a file (`field=@path`), never as an argument, where the shell history
and the process list would keep it. For example:

```bash
bao kv put -mount=devsecops ci/dev/sonarqube url=<url> token=-
bao kv put -mount=devsecops ci/prod/cosign private_key=@cosign.key password=-
```

`bao kv put` replaces the whole secret. To add one field to an existing secret,
use `bao kv patch` with the same form.

### The signing key (`cosign`)

The Cosign key has a login role of its own. Each repository has three roles,
and the caller names only the first:

| Role | Logs in on | Reads |
| --- | --- | --- |
| `ci-<repo>` | every build that is not a tag | `devsecops/ci/dev/*` |
| `ci-<repo>-release` | tag builds | `devsecops/ci/prod/*`, but not `devsecops/ci/prod/cosign` |
| `ci-<repo>-sign` | tag builds, in a job of the catalog's `docker-build.yml` only | `devsecops/ci/prod/cosign`, nothing else |

Why: every job of a tag build holds the release role, including the jobs that
run `npm ci`, `tox` or a project's own build, and any step of such a job can
request the job's OIDC token itself. While the release role could read the key,
a malicious dependency in a tag build could log in with it and read the signing
key, even in a job that never signs.

So `docker-build.yml` reads the key:

- alone. The read passes `tools: cosign` and nothing else, so the action logs
  in as `<openbao-role>-sign`. The action refuses `cosign` together with
  another tool or with `repo` names, and on a build that is not a tag.
- in the step right before "Sign image (Cosign)", under the same gate
  (`secrets-source: openbao`, `sign-image` and `release`), not with the other
  reads at the start of the job. No step before the signature has the key in
  its environment, and a build that fails a scan gate never reads it.
- for the signing step only. The step right after it, "Clear the Cosign key
  from the job environment", runs even when the signature failed
  (`always()`), and sets `COSIGN_PRIVATE_KEY` and `COSIGN_PASSWORD` to empty
  for the rest of the job. Only post steps follow it: those of the actions
  the job used earlier (checkout, the registry logins, Buildx, the image
  build).
- from the devsecops layout only. In openbao mode, `sign-image` on a `release`
  build needs `cosign` in `openbao-tools`, a tag build, and
  `environment: prod`. Without any one of them, "Check secrets-source and
  openbao-tools" stops the job before anything is built, not at the Cosign
  read with the image already pushed. `ocs/ci/shared/COSIGN_*` is never read.

`node-workflow.yml` forwards `sign-image`, `openbao-tools` and
`docker-environment` (as `environment`) to `docker-build.yml`, and its
`node-ci` job runs the same check first, before the Node build and the SBOM
upload. Its image build is a job of `docker-build.yml`, which the `-sign` role
is meant to accept; that rests on an assumption about nested calls, below.
`python-ci.yml` and `sbom.yml` sign nothing.

What the platform repository's OpenBao configuration must hold (the catalog
cannot check it):

- The release roles' policy denies `devsecops/data/ci/prod/cosign`
  explicitly.
- A policy that reads `devsecops/data/ci/prod/cosign` and nothing else, held
  by the `-sign` roles only.
- Per repository, a JWT role `ci-<repo>-sign` with that policy only,
  `bound_claims_type: glob`, and these `bound_claims`:
  - `repository`: the repository, `<org>/<repo>`;
  - `ref_type`: `tag`;
  - `job_workflow_ref`:
    `CSC-Operations-Coordination-Service/workflow-catalog/.github/workflows/docker-build.yml@*`.
- The policy for `ocs/ci/shared`, held by the base `ci-<repo>` roles, denies
  `ocs/data/ci/shared/COSIGN_PRIVATE_KEY` and
  `ocs/data/ci/shared/COSIGN_PASSWORD`. Every branch and pull request build
  holds that policy, so the ocs layout must never hand out the key.

`job_workflow_ref` is the GitHub OIDC claim that names the reusable workflow
that defines the job, at the ref of the `uses:` line that called it. So a
`node-workflow.yml` or `python-ci.yml` job that runs `npm ci` or `tox` cannot
get the `-sign` role, and a `docker-build.yml` job that a repository calls
directly can. `@*` accepts any catalog ref, for two reasons:

- pilot repositories call the catalog at a branch while it is tested;
- through `node-workflow.yml`, the `uses:` line that calls `docker-build.yml`
  is the catalog's own nested call, not the pilot's. It names `@develop` on
  `develop`.
  A release made as [releasing.md](releasing.md) says pins it to the release
  tag, so a pilot that calls such a release through `node-workflow.yml`
  presents `docker-build.yml@refs/tags/<tag>` (with the nested-call assumption
  below).

The binding is tightened to `@refs/tags/*` once both hold: the pilots call a
catalog release, **and** the catalog's nested calls to `docker-build.yml` name
a release tag. Tag `1.0.0` has no openbao mode at all, so signing in openbao
mode needs a release after `1.0.0`, and every such release made with
`scripts/pin-catalog-refs.sh` meets the second condition. What is left is the
first: every pilot that signs in openbao mode calls such a release, not a
branch. Tightened before that, the login as `-sign` of a pilot still on a
branch is refused.

**Not verified yet: nested calls.** GitHub documents the claim for a job of
one reusable workflow called by a repository. It does not say what the claim
names when that workflow is itself called by another reusable workflow, as
`node-workflow.yml` calls `docker-build.yml`. The design assumes it names the
innermost workflow, the one that defines the job (`docker-build.yml`). Until a
real tag build confirms it, treat signing through `node-workflow.yml` in
openbao mode as untested:

- Confirm it on the first tag build of a `node-workflow.yml` caller with
  `sign-image`, `docker-release`, `cosign` in `openbao-tools` and
  `docker-environment: prod`. In the nested `docker` job, the step "Read Cosign
  secrets from OpenBao" logs `role <openbao-role>-sign` when the login
  succeeds.
- If that login is refused and the role exists, suspect the claim first: it
  may name `node-workflow.yml`. The action's error points back here. Do not
  widen the `-sign` binding to `node-workflow.yml`: its `node-ci` job runs
  `npm ci`, the case the role exists to keep out. Until this is settled, a
  repository that must sign in openbao mode calls `docker-build.yml` directly.

What this does not cover: every step of the `docker-build.yml` `docker` job
can still request the job's token and log in as `-sign`. Those steps run only
actions the catalog pins, never a project's dependencies: the image's `RUN`
steps run inside BuildKit, without the job's token.

### Use it from a repository

Call the catalog at `@develop` (merged on 2026-10-22), or at a release once one
is cut ([releasing.md](releasing.md)). Its own workflows call the action and
`docker-build.yml` at the same ref.

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
      openbao-role: ci-<repo>   # the repository's base role name
      openbao-tools: nexus sonarqube dependency-track
    secrets: inherit
```

1. A push to a branch exercises `ci-<repo>` and `devsecops/ci/dev/*`. The read
   step logs, without values, which variables it exported per tool.
2. A version tag exercises `ci-<repo>-release` and `devsecops/ci/prod/*`. Set
   the image build's environment to `prod` (`docker-environment: prod` here).
   With `sign-image`, `docker-release` and `cosign` in `openbao-tools`, it also
   exercises `ci-<repo>-sign` and `devsecops/ci/prod/cosign`, read in the step
   right before the signature. Through `node-workflow.yml`, that run is also
   the check of the [nested-call assumption](#the-signing-key-cosign).
3. Expected failures, worth seeing once: a branch build with
   `docker-environment: prod` stops at the read; a tool whose secret does not
   exist stops the job naming its path; a secret without one of its required
   fields stops the job naming the path and the field; a misspelled tool in
   `openbao-tools`, or a misspelled `secrets-source`, stops the job at
   "Check secrets-source and openbao-tools", and so does `sign-image` on a
   `docker-release` build without `cosign` in `openbao-tools`, or with
   `docker-environment` other than `prod`.

The action's devsecops read can be tested locally against a mock OpenBao:
`bash tests/openbao_secrets_tools_test.sh` (node, openssl and PyYAML; no
network).

## The action

[`openbao-secrets`](../.github/actions/openbao-secrets/action.yml) does the login
and exports the names as masked environment variables (`shared` / `repo` names
in the ocs layout, `tools` in the devsecops layout; one call takes one layout). A job of your own can use
it directly for repository-specific secrets (`repo:` input). If OpenBao cannot be
read, the job stops with a message that names OpenBao and lists what to check; the
first thing to check is whether OpenBao is **sealed**.

A job with `container:` is a sibling container on the node and is not on the
OpenBao overlay: the reusable workflows add `options: --network ocs_openbao` in
openbao mode. Do the same in a `container:` job of your own.

The action trusts the CA it bundles (`openbao-ca.crt`), read through
`$GITHUB_ACTION_PATH`, which the runner translates into a job container's paths
(the `github.action_path` context is not translated). If that file is missing or
empty, the job stops at the step "Read the bundled OpenBao CA" with an error that
names it, not later at the login with a misleading "is OpenBao SEALED?".
