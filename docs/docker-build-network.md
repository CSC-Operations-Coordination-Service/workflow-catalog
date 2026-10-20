# Docker builds on a runner without direct internet egress

`docker-build.yml` makes **four separate network hops**, and each one is
configured by a different mechanism. A setting that fixes one does nothing for
the others — which is why "the proxy is configured" and "the build still
times out" are both true at the same time.

| # | Hop | Who makes the call | Configured by |
| --- | --- | --- | --- |
| 1 | Pull the image the builder itself runs on (`moby/buildkit:buildx-stable-1`) | the runner's **docker daemon** | `buildkit-image` input (or the daemon's own `registry-mirrors` / proxy in `/etc/docker/daemon.json`) |
| 2 | Resolve `# syntax=` and `FROM` images | **BuildKit**, inside its container | `registry-mirror-port` / `registry-mirror` input, or the `BUILDKIT_HTTP_PROXY` repo variable |
| 3 | Fetch packages inside a `RUN` step (`pip install`, `npm ci`, …) | the **build container**, per RUN step | `mount-pip-index` / `mount-npm-registry` inputs — plus a Dockerfile that consumes the secret |
| 4 | Push the built image to Nexus | **BuildKit** | `insecure-registry` input (plain-HTTP connector), plus `no_proxy` — handled automatically; for the `*.ocs-registry.local` names, the builder's network too (`builder-network`, automatic) |

Hop 3 is the one that surprises people, because it fails *after* a green hop 2.
BuildKit resolves `FROM` with its own egress — the mirror, or the proxy in its
`driver-opts` — but a `RUN` step executes in a plain container that inherits
none of that. So `FROM python:3.12-slim` pulls fine and the very next
`RUN pip install` dies with a bare `exit code: 1`. Routing the package manager
through Nexus fixes it without depending on any proxy at all; a Dockerfile that
ignores the mounted secret is still on hop 3 no matter what the caller passes.

The post-push steps that read the image back — Cosign signing, and Syft/Grype/Dockle
when enabled — are a fifth caller against the same connector. `insecure-registry`
is forwarded to Cosign, which otherwise resolves over HTTPS with no fallback. It also
switches Syft, Grype and Dockle to plain HTTP through each tool's own setting, set on
the step (`SYFT_REGISTRY_INSECURE_USE_HTTP`, `GRYPE_REGISTRY_INSECURE_USE_HTTP`,
`DOCKLE_INSECURE`, the env form of Dockle's `--insecure`; `--nonssl` alone is not
enough). When the connector is plain HTTP and reached through a name that does not
resolve to loopback (an overlay alias, for instance), those tools otherwise fail with
`Get "https://<registry>/v2/": ... connection refused`. With `insecure-registry: false`
the three values are `false`, the tools' default.

### Hop 4 through the `ocs-registry.local` names: `builder-network`

`dev.ocs-registry.local` and `prod.ocs-registry.local` resolve only through the
runner node's `/etc/hosts`, to `127.0.0.1`, where the swarm routing mesh hands
port 80 to Traefik and Traefik routes by `Host` to the Nexus connector. The push
is made by **BuildKit**, not by the daemon, and setup-buildx-action runs BuildKit
in a `docker-container` builder: a sibling container on the daemon's default
bridge. It sees neither the node's `/etc/hosts` nor the overlay aliases the runner
container resolves the names through, and `127.0.0.1` there is the builder itself.
The push then fails with
`dial tcp: lookup dev.ocs-registry.local on <dns>:53: no such host`.

`builder-network: auto` (the default) gives the builder `network=host` whenever
the resolved registry host is a `*.ocs-registry.local` name, so it shares the
node's `/etc/hosts` and loopback; any other registry keeps the default bridge.
`host` / `bridge` force one or the other. The `buildkitd.toml` entry
`[registry."dev.ocs-registry.local"] http = true` (from `insecure-registry`) is
unchanged: the name has no port. Checked 2026-10-20 on a docker:28-dind swarm
node with Traefik v3.7.13 and Nexus 3.77.0, from a container holding the node's
docker socket on the Traefik overlay (buildx v0.29.1): the default builder fails
with the error above, `network=host` pushes.

On the host network buildkitd's `RUN` steps share the node's network namespace
too (the builder image has no CNI). The job already holds the node's docker
socket, so that grants nothing new. Note that buildx does **not** copy the
`proxies` of the runner's `~/.docker/config.json` into the builder container
(same check: its environment held no proxy variable); the builder's proxy is only
what this workflow passes as `env.*` driver-opts, whose `no_proxy` already names
the registry. The read-back steps below run in the runner container instead, so
there the runner's own `NO_PROXY` must cover the names.

Hop 1 happens **before** hops 2 and 3 are even possible: the `buildkitd.toml`
mirror config and the proxy `driver-opts` are handed to a BuildKit that does not
exist until its image has been pulled. So neither of them can help hop 1.

## Symptom → hop

| Symptom | Hop | Fix |
| --- | --- | --- |
| `Set up Docker Buildx` fails at **Creating a new builder instance** with `ERROR: invalid value "127.0.0.1", expecting k=v` | — | Not a network fault. buildx CSV-parses every `--driver-opt`, so each comma in a `no_proxy` list reads as the start of another `k=v` pair. Already fixed: the value is emitted wrapped in double quotes, which keeps it one CSV field. Only bites again if a new comma-bearing driver-opt is added unquoted |
| `Set up Docker Buildx` stalls at **Booting builder**, or the step hits its 8-minute timeout | 1 | Set `buildkit-image` to a Nexus path, e.g. `<host:port>/moby/buildkit:buildx-stable-1` |
| Build fails early resolving `docker/dockerfile:1` or `python:3.11-slim`, `i/o timeout` to `registry-1.docker.io` | 2 | Set `registry-mirror-port` to a Nexus **group** connector that includes the Docker Hub proxy, or set the `BUILDKIT_HTTP_PROXY` repo variable |
| Build reaches a `RUN` step and fails with `exit code: 1` from `pip install` / `npm ci`, or the package manager times out reaching pypi.org / registry.npmjs.org | 3 | Pass `mount-pip-index: true` / `mount-npm-registry: true` **and** consume the secret in the Dockerfile — see below |
| `npm ci` fails `401 Unauthorized` against the Nexus registry | 3 | The repo needs authentication and `NEXUS_USERNAME`/`NEXUS_PASSWORD` were not both set, so the `_auth` line was omitted. The step logs `(anonymous — …)` when that happens |
| Push fails with `http: server gave HTTP response to HTTPS client`, or an https probe of the connector returns TLS `packet length too long` | 4 | `insecure-registry: true` |
| Push succeeds, then **Sign image (Cosign)** fails reaching the same registry over https | 4 | Same `insecure-registry: true` — it is forwarded to Cosign as `--allow-insecure-registry`, applied only to references on that host so GHCR and Docker Hub keep TLS |
| Push fails with `lookup dev.ocs-registry.local ... no such host` (or `prod.`) | 4 | The builder is on the default bridge: leave `builder-network` at `auto` (or set `host`). `bridge` reproduces the failure |
| Push is sent to an internet-facing proxy and fails | 4 | Already handled: the registry and mirror are added to BuildKit's `no_proxy` (host **and** host:port, since a ported `no_proxy` entry only matches that port) |

## Notes on the Nexus side

- A Nexus **proxy** repository has no connector port of its own — it is only
  reachable through a **group** repository that includes it. `registry-mirror-port`
  therefore wants the group's port, not the proxy's.
- The mirror host is derived from the `NEXUS_DOCKER_REGISTRY_*` secret, so a
  caller only ever passes a port; nothing internal is hardcoded in the caller.
- A mirror on a different connector than the push target gets **its own**
  `docker login` — a Nexus group answers `/v2/` with `401` for anonymous pulls,
  which fails a `FROM` resolution exactly like an unreachable Docker Hub does.
- When `registry-mirror`/`registry-mirror-port` is set and `buildkit-image` is
  not, the builder image is derived from the mirror
  (`<mirror>/moby/buildkit:buildx-stable-1`) — one setting covers hops 1 and 2.
- A plain-HTTP source for hop 1 must be listed in the **daemon's**
  `insecure-registries`; the `insecure-registry` input only speaks for BuildKit.

## Reading the failure in the log

The `Compose BuildKit registry config` step prints what it decided — which
registries are plain HTTP, which mirror was chosen, which builder image, and a
warning per hop that has no route configured. Read that step first; it says
which of the three hops is unconfigured before any of them is attempted.

GitHub collapses `Set up Docker Buildx` into groups (`Docker info`,
`Buildx version`, `Creating a new builder instance`, `Booting builder`, …). The
error is *inside* a group — expand `Booting builder` before diagnosing, since
the group headers alone look identical for a hang and a success.

## Hop 3: package managers inside the build

Neither input does anything on its own — each mounts a BuildKit secret that the
Dockerfile has to read. Make the secret **optional** in the Dockerfile so a local
`docker compose build` with no secret mounted still works.

Python, with `mount-pip-index: true`:

```dockerfile
RUN --mount=type=secret,id=pip_index_url \
    --mount=type=secret,id=netrc,target=/root/.netrc \
    set -eu; \
    if [ -s /run/secrets/pip_index_url ]; then \
      index_url="$(tr -d '\r\n' < /run/secrets/pip_index_url)"; \
      hostpart="${index_url#*://}"; hostpart="${hostpart%%/*}"; \
      index_host="${hostpart##*@}"; index_host="${index_host%%:*}"; \
      set -- --index-url "$index_url" --trusted-host "$index_host"; \
    else set --; fi; \
    pip install --no-cache-dir --no-input "$@" -r requirements.txt
```

`--trusted-host` is required because the Nexus index is served over plain HTTP.

Node, with `mount-npm-registry: true`:

```dockerfile
RUN --mount=type=secret,id=npmrc,target=/root/.npmrc npm ci --no-audit --no-fund
```

The npm secret is a complete `.npmrc`, so mounting it at the location npm already
reads is the whole integration — no flags, and nothing registry-specific in the
Dockerfile. It is mounted, never copied, so the credential is not in any layer.

Two things to know about it:

- **The registry name is an input, not a convention.** `npm-registry-repo`
  defaults to `npm-proxy`. The PyPI side derives `pypi-<context>-group` from
  `environment`; npm repositories are not split per context here, so the name is
  passed explicitly. Point it at a group if you later front several repos.
- **Credentials are optional**, unlike the pip secret. A Nexus npm proxy is often
  anonymously readable; the `_auth` line is added only when `NEXUS_USERNAME` and
  `NEXUS_PASSWORD` are both set, and the step says which mode it chose. `_auth`
  is base64 of `user:password`, so a password containing `@`, `:` or `/` needs no
  escaping — the same reasoning as the pip `netrc` split. The base64 blob is
  masked explicitly: GitHub masks the raw secrets, but not a re-encoding of them.
