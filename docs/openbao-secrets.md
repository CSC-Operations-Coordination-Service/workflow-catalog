# Secrets from OpenBao (private repositories)

Organization secrets cannot be used by private repositories on our plan. For
those, the catalog workflows can read the same values from OpenBao instead, with
the job's own GitHub OIDC token: no vault token and no other secret is stored in
the repository.

Applies to `node-workflow.yml` and `docker-build.yml` (`python-ci.yml` does not
have the switch yet). Default behaviour is unchanged: without the inputs below
every value still comes from `secrets.*`, as before.

## What the caller sets

| Input | Default | Purpose |
| --- | --- | --- |
| `secrets-source` | `github` | `openbao` reads the values from OpenBao |
| `openbao-url` | `https://openbao:8200` | Reachable from the runner pool only (overlay `ocs_openbao`) |
| `openbao-role` | — | The repository's JWT role, e.g. `ci-ocs-operator-app` |
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

kv-v2 mount `ocs`, one secret per name, the value in the key `value`:

| Path | Read by |
| --- | --- |
| `ocs/ci/shared/<NAME>` (`NEXUS_HOST`, `NEXUS_PASSWORD`, `DOCKERHUB_TOKEN`, ...) | every CI role |
| `ocs/ci/<repository>/<NAME>` | that repository's role only |

An operator writes them (`bao kv put ocs/ci/shared/NEXUS_PASSWORD value=-`), never
a pipeline. Roles and policies are in csc-ocs-ansible
(`stacks/platform/openbao/openbao-config.yml`).

## The action

[`openbao-secrets`](../.github/actions/openbao-secrets/action.yml) does the login
and exports the names as masked environment variables. A job of your own can use
it directly for repository-specific secrets (`repo:` input). If OpenBao cannot be
read, the job stops with a message that names OpenBao and lists what to check; the
first thing to check is whether OpenBao is **sealed** (it is unsealed by hand
after any restart).

A job with `container:` is a sibling container on the node and is not on the
OpenBao overlay: the reusable workflows add `options: --network ocs_openbao` in
openbao mode. Do the same in a `container:` job of your own.
