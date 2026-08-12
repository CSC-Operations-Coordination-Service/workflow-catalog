# Docker builds on a runner without direct internet egress

`docker-build.yml` makes **three separate network hops**, and each one is
configured by a different mechanism. A setting that fixes one does nothing for
the other two — which is why "the proxy is configured" and "the build still
times out" are both true at the same time.

| # | Hop | Who makes the call | Configured by |
| --- | --- | --- | --- |
| 1 | Pull the image the builder itself runs on (`moby/buildkit:buildx-stable-1`) | the runner's **docker daemon** | `buildkit-image` input (or the daemon's own `registry-mirrors` / proxy in `/etc/docker/daemon.json`) |
| 2 | Resolve `# syntax=` and `FROM` images | **BuildKit**, inside its container | `registry-mirror-port` / `registry-mirror` input, or the `BUILDKIT_HTTP_PROXY` repo variable |
| 3 | Push the built image to Nexus | **BuildKit** | `insecure-registry` input (plain-HTTP connector), plus `no_proxy` — handled automatically |

The post-push steps that read the image back — Cosign signing, and Syft/Grype/Dockle
when enabled — are a fourth caller against the same connector. `insecure-registry`
is forwarded to Cosign, which otherwise resolves over HTTPS with no fallback; the
Syft/Grype/Dockle tools pull through the runner's docker daemon and so inherit its
`insecure-registries` instead.

Hop 1 happens **before** hops 2 and 3 are even possible: the `buildkitd.toml`
mirror config and the proxy `driver-opts` are handed to a BuildKit that does not
exist until its image has been pulled. So neither of them can help hop 1.

## Symptom → hop

| Symptom | Hop | Fix |
| --- | --- | --- |
| `Set up Docker Buildx` fails at **Creating a new builder instance** with `ERROR: invalid value "127.0.0.1", expecting k=v` | — | Not a network fault. buildx CSV-parses every `--driver-opt`, so each comma in a `no_proxy` list reads as the start of another `k=v` pair. Already fixed: the value is emitted wrapped in double quotes, which keeps it one CSV field. Only bites again if a new comma-bearing driver-opt is added unquoted |
| `Set up Docker Buildx` stalls at **Booting builder**, or the step hits its 8-minute timeout | 1 | Set `buildkit-image` to a Nexus path, e.g. `<host:port>/moby/buildkit:buildx-stable-1` |
| Build fails early resolving `docker/dockerfile:1` or `python:3.11-slim`, `i/o timeout` to `registry-1.docker.io` | 2 | Set `registry-mirror-port` to a Nexus **group** connector that includes the Docker Hub proxy, or set the `BUILDKIT_HTTP_PROXY` repo variable |
| Push fails with `http: server gave HTTP response to HTTPS client`, or an https probe of the connector returns TLS `packet length too long` | 3 | `insecure-registry: true` |
| Push succeeds, then **Sign image (Cosign)** fails reaching the same registry over https | 3 | Same `insecure-registry: true` — it is forwarded to Cosign as `--allow-insecure-registry`, applied only to references on that host so GHCR and Docker Hub keep TLS |
| Push is sent to an internet-facing proxy and fails | 3 | Already handled: the registry and mirror are added to BuildKit's `no_proxy` (host **and** host:port, since a ported `no_proxy` entry only matches that port) |

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
