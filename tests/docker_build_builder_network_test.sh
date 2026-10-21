#!/usr/bin/env bash
# Runs the "Compose BuildKit registry config" step of docker-build.yml with sample
# inputs and asserts on the driver-opts it hands to setup-buildx-action: the
# builder joins the node's network (network=host) when the push target is one of
# the internal registry names the step matches, and only then, unless
# builder-network forces it. The samples below use those names because the step's
# case pattern must match them.
# Why: those names resolve only through the node's /etc/hosts. The
# docker-container builder is a sibling container on the daemon's default bridge:
# it does not see that file, so the push dies with "lookup <registry name> ...
# no such host" (docs/docker-build-network.md).
# Needs python3 with PyYAML (the step is read from the workflow, not copied).
# Run from anywhere: bash tests/docker_build_builder_network_test.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCKER="$ROOT/.github/workflows/docker-build.yml"
fail=0
check() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fail=1; fi; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PY="$(command -v /usr/bin/python3 || command -v python3)"
"$PY" - "$DOCKER" "$WORK/step.sh" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
step = [s for s in wf["jobs"]["docker"]["steps"] if s.get("name") == "Compose BuildKit registry config"][0]
open(sys.argv[2], "w").write(step["run"])
PY
check "the step is found in the workflow" "[ -s '$WORK/step.sh' ]"

# run_step REGISTRY BUILDER_NETWORK [PROXY]  -> driver-opts in $WORK/opts, toml in $WORK/buildkitd.toml, rc in $RC
run_step() {
  : >"$WORK/out"
  env -i PATH="$PATH" HOME="$WORK" RUNNER_TEMP="$WORK" GITHUB_OUTPUT="$WORK/out" \
    NEXUS_DOCKER_REGISTRY="$1" BUILDER_NETWORK="$2" https_proxy="${3:-}" \
    INSECURE=true PROXY_VAR= NO_PROXY_VAR= MIRROR_INPUT= MIRROR_PORT= BUILDKIT_IMAGE= \
    bash -e "$WORK/step.sh" >"$WORK/log" 2>&1
  RC=$?
  sed -n '/^driver-opts<<EOF$/,/^EOF$/p' "$WORK/out" >"$WORK/opts"
}

run_step dev.ocs-registry.local auto
check "auto + dev.ocs-registry.local: builder on the host network" "[ $RC -eq 0 ] && grep -qx 'network=host' '$WORK/opts'"
check "  ...and the name is still a plain-HTTP registry for BuildKit (no port)" \
  "grep -A1 -F '[registry.\"dev.ocs-registry.local\"]' '$WORK/buildkitd.toml' | grep -q 'http = true'"
check "  ...and the step says why" "grep -q 'host network' '$WORK/log'"

run_step prod.ocs-registry.local auto
check "auto + prod.ocs-registry.local: builder on the host network" "[ $RC -eq 0 ] && grep -qx 'network=host' '$WORK/opts'"

run_step nexus.example.internal:5000 auto
check "auto + any other registry: default bridge (no network opt)" "[ $RC -eq 0 ] && ! grep -q '^network=' '$WORK/opts'"

run_step 127.0.0.1:5001 auto
check "auto + a loopback registry (127.0.0.1:5001): default bridge (unchanged behaviour)" "[ $RC -eq 0 ] && ! grep -q '^network=' '$WORK/opts'"

run_step evilocs-registry.local auto
check "auto + a look-alike host (no dot before ocs-registry.local): default bridge" "[ $RC -eq 0 ] && ! grep -q '^network=' '$WORK/opts'"

run_step nexus.example.internal:5000 host
check "builder-network host forces it for any registry" "[ $RC -eq 0 ] && grep -qx 'network=host' '$WORK/opts'"

run_step dev.ocs-registry.local bridge
check "builder-network bridge keeps the default bridge even for the names" "[ $RC -eq 0 ] && ! grep -q '^network=' '$WORK/opts'"

run_step dev.ocs-registry.local hots
check "an unknown builder-network value fails the step, naming the input" "[ $RC -ne 0 ] && grep -q 'builder-network' '$WORK/log'"

run_step dev.ocs-registry.local auto http://squid.example:3128
check "with a proxy: host network AND the name in BuildKit's no_proxy" \
  "[ $RC -eq 0 ] && grep -qx 'network=host' '$WORK/opts' && grep -q 'env.no_proxy=.*dev.ocs-registry.local' '$WORK/opts'"

# --- wiring
check "builder-network input exists, default auto" "grep -A14 '^      builder-network:' '$DOCKER' | grep -q 'default: \"auto\"'"
check "the step reads it from inputs.builder-network" \
  "grep -q 'BUILDER_NETWORK: \${{ inputs.builder-network }}' '$DOCKER'"
check "docs page explains the builder network" "grep -q 'builder-network' '$ROOT/docs/docker-build-network.md' && grep -q 'internal registry names' '$ROOT/docs/docker-build-network.md'"
exit $fail
