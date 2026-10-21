#!/usr/bin/env bash
# Static checks for the OpenBao secrets path of the catalog workflows.
# Run from anywhere: bash tests/openbao_secrets_test.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ACT="$ROOT/.github/actions/openbao-secrets/action.yml"
NODE="$ROOT/.github/workflows/node-workflow.yml"
DOCKER="$ROOT/.github/workflows/docker-build.yml"
PY="$ROOT/.github/workflows/python-ci.yml"
fail=0
check() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fail=1; fi; }
MANAGED='NEXUS_HOST|NEXUS_PORT|NEXUS_USERNAME|NEXUS_PASSWORD|NEXUS_DOCKER_REGISTRY_DEV|NEXUS_DOCKER_REGISTRY_PROD|DEPENDENCYTRACK_URL|DEPENDENCYTRACK_API_KEY|DOCKERHUB_USERNAME|DOCKERHUB_TOKEN|COSIGN_PRIVATE_KEY|COSIGN_PASSWORD|SONAR_TOKEN|SONAR_HOST_URL'

# --- the action
check "action exists" "[ -f '$ACT' ]"
check "action logs in with the jwt method and exports env" "grep -q 'method: jwt' '$ACT' && grep -q 'exportEnv: true' '$ACT'"
check "action pins vault-action by commit" "grep -Eq 'hashicorp/vault-action@[0-9a-f]{40}' '$ACT'"
check "action trusts the bundled OpenBao CA" "[ -f '$ROOT/.github/actions/openbao-secrets/openbao-ca.crt' ] && grep -q 'caCertificate' '$ACT'"
check "action reads shared secrets from ocs/data/ci/shared" "grep -q 'ocs/data/ci/shared' '$ACT'"
check "action reads repo secrets from ocs/data/ci/<repo>" "grep -q 'ocs/data/ci/' '$ACT' && grep -q 'github.event.repository.name' '$ACT'"
check "a failed login stops the job with a message naming OpenBao" "grep -q \"outcome == 'failure'\" '$ACT' && grep -qi 'OpenBao' '$ACT' && grep -q 'exit 1' '$ACT'"
# devsecops layout (behaviour: tests/openbao_secrets_tools_test.sh)
check "action has the tools and environment inputs" "grep -q '^  tools:' '$ACT' && grep -q '^  environment:' '$ACT'"
check "action pins github-script by commit" "grep -Eq 'actions/github-script@[0-9a-f]{40}' '$ACT'"
check "action reads devsecops/data/ci/<kind>/<tool>" "grep -q 'devsecops/data/ci/' '$ACT'"
check "action logs in as <role>-release on tag builds" "grep -q \"REF_TYPE === 'tag'\" '$ACT' && grep -q -- '-release' '$ACT'"
check "the ocs-layout steps run only without tools" "[ \"\$(grep -c \"if: inputs.tools == ''\\$\" '$ACT')\" = 2 ] && grep -q \"if: inputs.tools == '' && steps.login.outcome == 'failure'\" '$ACT'"

# --- the workflows
for f in "$NODE" "$DOCKER" "$PY"; do
  n="$(basename "$f")"
  check "$n: secrets-source input defaults to github" "grep -A16 '^      secrets-source:' '$f' | grep -q 'default: github'"
  check "$n: has openbao-url and openbao-role inputs" "grep -q '^      openbao-url:' '$f' && grep -q '^      openbao-role:' '$f'"
  check "$n: every managed secret keeps its secrets.* fallback behind the switch" \
    "! grep -En 'secrets\.($MANAGED)' '$f' | grep -v 'secrets-source'"
  check "$n: logs in only when secrets-source is openbao" "grep -q \"inputs.secrets-source == 'openbao'\" '$f'"
  check "$n: openbao-tools input defaults to empty" "grep -A12 '^      openbao-tools:' '$f' | grep -q 'default: \"\"'"
  # Every read passes exactly one of tools / shared, from the same test on openbao-tools.
  check "$n: each read chooses tools or shared on openbao-tools" \
    "[ \"\$(grep -c \"^          tools: \\\${{ contains(format(' {0} ', inputs.openbao-tools)\" '$f')\" = \"\$(grep -c \"^          shared: \\\${{ !contains(format(' {0} ', inputs.openbao-tools)\" '$f')\" ] && ! grep -q '^          shared: |' '$f'"
done
check "docker-build.yml: every read passes environment for the build-kind check" \
  "[ \"\$(grep -c '^          tools: ' '$DOCKER')\" = \"\$(grep -c '^          environment: \${{ inputs.environment }}' '$DOCKER')\" ]"
check "python-ci.yml: runs-on is an input, default self-hosted" "grep -A4 '^      runs-on:' '$PY' | grep -q 'default: self-hosted' && ! grep -q '^    runs-on: self-hosted' '$PY'"
check "python-ci.yml: container jobs join the openbao network only in openbao mode" "[ \"\$(grep -c -- \"secrets-source == 'openbao' && '.*--network ocs_openbao\" '$PY')\" = 3 ]"
check "node-workflow.yml passes openbao-tools to docker-build" "grep -q 'openbao-tools: \${{ inputs.openbao-tools }}' '$NODE'"
check "docker-build.yml: runs-on is an input, default self-hosted" "grep -A4 '^      runs-on:' '$DOCKER' | grep -q 'default: self-hosted' && ! grep -q '^    runs-on: self-hosted' '$DOCKER'"
check "node-workflow.yml: no job hardcodes self-hosted" "! grep -q '^    runs-on: self-hosted' '$NODE'"
check "node-workflow.yml: container job joins the openbao network only in openbao mode" "grep -q -- '--network ocs_openbao' '$NODE' && grep -B2 -- '--network ocs_openbao' '$NODE' | grep -q 'secrets-source'"

# --- one ref for everything this branch adds. A workflow that calls another catalog
# workflow or the action at a different ref (e.g. @develop while the new inputs only
# exist on the branch) is rejected by GitHub: "Invalid input, X is not defined".
refs="$(grep -hoE 'workflow-catalog/\.github/(workflows/docker-build\.yml|actions/openbao-secrets)@[^ ]+' "$NODE" "$DOCKER" "$PY" | sed -E 's/.*@//' | sort -u)"
check "docker-build.yml and the openbao-secrets action are called at one and the same ref" "[ \"\$(wc -l <<<\"\$refs\")\" = 1 ]"

# --- actionlint
if docker image inspect rhysd/actionlint:1.7.7 >/dev/null 2>&1 || docker pull -q rhysd/actionlint:1.7.7 >/dev/null 2>&1; then
  check "actionlint is clean on the touched files" "docker run --rm -v '$ROOT:/r' -w /r rhysd/actionlint:1.7.7 -color=false .github/workflows/node-workflow.yml .github/workflows/docker-build.yml .github/workflows/python-ci.yml >/tmp/actionlint.out 2>&1 || (cat /tmp/actionlint.out; false)"
else
  echo "SKIP - actionlint image unavailable"
fi
exit $fail
