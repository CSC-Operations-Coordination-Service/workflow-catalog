#!/usr/bin/env bash
# Static checks: the Syft, Grype and Dockle steps of docker-build.yml pull the image
# over plain HTTP when (and only when) inputs.insecure-registry is true.
# Run from anywhere: bash tests/docker_build_insecure_test.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCKER="$ROOT/.github/workflows/docker-build.yml"
fail=0
check() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fail=1; fi; }

# Text of one step: from its "- name: <name>" line up to the next "- name:" line.
step() { awk -v n="      - name: $1" '$0 == n {on=1; print; next} on && /^      - name:/ {exit} on {print}' "$DOCKER"; }

GATE="\${{ inputs.insecure-registry && 'true' || 'false' }}"
for pair in "Generate image SBOM (Syft)|SYFT_REGISTRY_INSECURE_USE_HTTP" \
            "Scan image for vulnerabilities (Grype)|GRYPE_REGISTRY_INSECURE_USE_HTTP" \
            "Lint image hardening (Dockle)|DOCKLE_INSECURE"; do
  name="${pair%%|*}"; var="${pair##*|}"
  body="$(step "$name")"
  check "step '$name' exists" "[ -n \"\$body\" ]"
  check "step '$name' sets $var gated on inputs.insecure-registry" \
    "grep -Fq \"\$var: \$GATE\" <<<\"\$body\""
  check "step '$name' keeps its env block under the step (not at workflow level)" \
    "grep -q '^        env:' <<<\"\$body\""
done
check "no scanner variable is set unconditionally" \
  "! grep -En '(SYFT|GRYPE)_REGISTRY_INSECURE_USE_HTTP: *(true|\"true\")|DOCKLE_INSECURE: *(true|\"true\")' '$DOCKER'"
check "insecure-registry input description mentions the scanners" \
  "grep -A2 '^      insecure-registry:' '$DOCKER' | grep -q 'Syft, Grype and Dockle'"
check "docs page mentions the scanner variables" \
  "grep -q 'SYFT_REGISTRY_INSECURE_USE_HTTP' '$ROOT/docs/docker-build-network.md' && grep -q 'DOCKLE_INSECURE' '$ROOT/docs/docker-build-network.md'"

# --- actionlint (pinned container)
if docker image inspect rhysd/actionlint:1.7.7 >/dev/null 2>&1 || docker pull -q rhysd/actionlint:1.7.7 >/dev/null 2>&1; then
  out="$(mktemp)"; trap 'rm -f "$out"' EXIT
  check "actionlint is clean on docker-build.yml" "docker run --rm -v '$ROOT:/r' -w /r rhysd/actionlint:1.7.7 -color=false .github/workflows/docker-build.yml >\"\$out\" 2>&1 || (cat \"\$out\"; false)"
else
  echo "SKIP - actionlint image unavailable"
fi
exit $fail
