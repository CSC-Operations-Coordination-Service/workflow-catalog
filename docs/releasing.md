# Releasing the catalog, and pinning it

A caller pins the catalog to freeze the code it runs, secrets included. That
only holds if the catalog's own references to itself are frozen too.

## Why the self-references matter

The reusable workflows call the catalog's actions and workflows by their full
`owner/repo/path@ref` form, never `./.github/...` (see
[the cross-repo caveat](README.md#cross-repo-consumption-caveat)). For example:

```yaml
uses: CSC-Operations-Coordination-Service/workflow-catalog/.github/actions/cosign-sign@develop
```

A caller that pins `docker-build.yml@1.0.0` runs `docker-build.yml` as it was
at `1.0.0`, but that file still calls `cosign-sign@develop`: the step that
receives the signing key runs whatever `develop` holds on the day of the build.
The same goes for `nexus-context` (Nexus credentials) and
`dependency-track-upload` (the Dependency-Track API key). Pinning by commit SHA
changes nothing: the SHA freezes the outer file, not the refs written inside it.

So every self-reference in a release must name that release.

## The tool: `scripts/pin-catalog-refs.sh`

```bash
scripts/pin-catalog-refs.sh <ref>           # rewrite every self-reference to @<ref>
scripts/pin-catalog-refs.sh --check <ref>   # list those not at @<ref> (file:line), exit 1 if any
```

It rewrites only
`CSC-Operations-Coordination-Service/workflow-catalog/.github/(actions|workflows)/<name>@<ref>`
in the `*.yml` and `*.yaml` files under `.github/`. Other repositories'
actions, the docs and every other file are left alone. It accepts a ref made
of letters, digits, `.`, `_`, `-` and `/` only, and refuses, within that set,
what git refuses in a ref name: a leading `-`, `.` or `/`, a trailing `/` or
`.`, `..`, `//`, `/.` and a `.lock` ending. A second run
with the same ref changes nothing. Its behaviour is tested on a temporary copy
by `bash tests/pin_catalog_refs_test.sh`.

[`self-refs.yml`](../.github/workflows/self-refs.yml) runs the check in CI:

| Event | Check |
| --- | --- |
| push of a tag | every self-reference names that tag |
| pull request into `develop` | every self-reference names `develop` |

## Day to day: a feature branch

A branch that changes a catalog action and a workflow that calls it has to
call that action at its own name while it is tested (as `ci/openbao-secrets`
does). Before it is merged into `develop`:

```bash
scripts/pin-catalog-refs.sh develop
git diff                      # only @refs change
git add .github
git commit -m "chore: call the catalog at develop again"
```

The pull request's `self-refs` check fails until this is done.

## A release

A release is one commit that pins every self-reference to the release tag,
then the tag on that commit. `main` takes changes through a reviewed pull
request only ([below](#repository-settings-maintainers)), so the pin commit
reaches `main` that way too, from a release branch, and the tag goes on `main`
after the merge. Never tag a commit that is not on `main`: nobody reviewed it.
For release `X.Y.Z`:

1. Merge `develop` into `main` through its pull request, as usual.
2. On a release branch made from that `main`, pin, check, commit and push:

   ```bash
   git fetch origin
   git checkout -b release/X.Y.Z origin/main
   scripts/pin-catalog-refs.sh X.Y.Z
   scripts/pin-catalog-refs.sh --check X.Y.Z
   git diff                    # only @refs change
   git add .github
   git commit -m "chore(release): pin catalog self-references to X.Y.Z"
   git push origin release/X.Y.Z
   ```

3. Open a pull request from `release/X.Y.Z` into `main`. The reviewer checks
   that the diff changes only `@` refs, to `@X.Y.Z`. Merge it.
4. Check the commit that the merge made on `main` (its SHA is on the pull
   request), then tag that commit and push the tag:

   ```bash
   git fetch origin
   git checkout <merge commit SHA>
   scripts/pin-catalog-refs.sh --check X.Y.Z
   git tag -a X.Y.Z -m X.Y.Z
   git push origin X.Y.Z
   ```

   The `self-refs` check runs on the tag too. Tags cannot be moved or deleted
   (below), so a tag that fails it is fixed by a new release, not by moving
   the tag. That is why the check runs by hand first, in steps 2 and 4: no
   automatic check runs on a pull request into `main`.
5. Keep `develop` at `@develop`. If `main` comes back into `develop` (a merge
   of `main` into `develop`), run `scripts/pin-catalog-refs.sh develop` in
   that merge. The pull request check catches a merge that forgot it.

Between step 1 and step 3, `main` can call some actions at the previous tag
and some at `@develop`: the release commit pins them all. Callers pin tags,
never `main`.

## How callers pin

Callers pin a release, never a branch:

```yaml
uses: CSC-Operations-Coordination-Service/workflow-catalog/.github/workflows/docker-build.yml@X.Y.Z
# or that tag's commit, with the tag in a comment:
uses: CSC-Operations-Coordination-Service/workflow-catalog/.github/workflows/docker-build.yml@<commit SHA> # X.Y.Z
```

A commit SHA cannot be moved. The self-references inside that commit name the
tag, not a SHA (a commit cannot hold its own SHA), so they stay frozen only as
long as the tag cannot be moved: that is what the tag ruleset below is for.

`@develop` is for the catalog's own pilots while a change is tested, not for
callers that handle real secrets.

## Repository settings (maintainers)

These live on GitHub, not in the repository. A maintainer sets them:

- **Tags**: a tag ruleset that targets all tags and restricts updates and
  deletions, so a released tag always names the same commit.
- **`develop` and `main`**: protected. Changes through a pull request with at
  least one approving review, no force push, no deletion. On `develop`, make
  the `self-refs` check required (it runs on pull requests into `develop`
  only, so a required check on `main` would never report); on both, the
  Gitleaks check.
- **CODEOWNERS**: a `.github/CODEOWNERS` file that makes an owner team review
  every change under `.github/` and `scripts/` (`/.github/ @<org>/<team>` and
  `/scripts/ @<org>/<team>`: the `self-refs` check runs the pull request's own
  `scripts/pin-catalog-refs.sh`), with "require review from Code Owners" on
  both branches. The team is for the maintainers to name.

## Known gap: tag `1.0.0`

`1.0.0` was cut before this check existed. Its workflows still call
`cosign-sign@develop`, `nexus-context@develop` and
`dependency-track-upload@develop`, so pinning the catalog to `1.0.0`, by tag
or by SHA, does not freeze those steps. The next release, made as above, fixes
it. Callers on `1.0.0` move to that release.
