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
check "action has a required-field list per tool (behaviour: tools test)" "grep -q 'const REQUIRED = {' '$ACT'"
check "a failed ocs read lists the ocs/ci paths it needed" "grep -q 'paths=\"\$paths ocs/ci/shared/\$n\"' '$ACT'"
# scripts/ci-secrets does not write devsecops/ci/<kind>/<tool> yet: nothing may say it does.
check "the action does not name scripts/ci-secrets as the devsecops writer" "! grep -q 'scripts/ci-secrets writes' '$ACT' && grep -q 'does not write this layout yet' '$ACT'"

# --- the workflows
# Lines reading a managed value that are NOT in the guarded form
#   inputs.secrets-source == 'openbao' && env.X || (inputs.secrets-source != 'openbao' && secrets.X || '')
# In openbao mode that form gives env.X or '', never secrets.X: a gap in OpenBao
# stays a gap instead of being filled by a GitHub secret through secrets: inherit.
unguarded() { grep -En "secrets\.($MANAGED)\b" "$1" | grep -vE "inputs\.secrets-source == 'openbao' && env\.([A-Z_]+) \|\| \(inputs\.secrets-source != 'openbao' && secrets\.\1 \|\| ''\)"; }
# Step text as YAML sees it: run_of <workflow> <job> <step name>
run_of() { python3 - "$1" "$2" "$3" <<'EOF'
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["jobs"][sys.argv[2]]["steps"]
print([s for s in steps if s.get("name") == sys.argv[3]][0]["run"], end="")
EOF
}
for f in "$NODE" "$DOCKER" "$PY"; do
  n="$(basename "$f")"
  check "$n: secrets-source input defaults to github" "grep -A16 '^      secrets-source:' '$f' | grep -q 'default: github'"
  check "$n: has openbao-url and openbao-role inputs" "grep -q '^      openbao-url:' '$f' && grep -q '^      openbao-role:' '$f'"
  check "$n: every managed secret keeps its secrets.* fallback behind the switch" \
    "! grep -En 'secrets\.($MANAGED)' '$f' | grep -v 'secrets-source'"
  check "$n: in openbao mode no value falls back to secrets.* (every read is the guarded form)" \
    "grep -Eq 'secrets\.($MANAGED)' '$f' && [ -z \"\$(unguarded '$f')\" ] || (unguarded '$f'; false)"
  check "$n: a Check openbao-tools step runs in openbao mode with a non-empty list" \
    "grep -A1 '^      - name: Check openbao-tools\$' '$f' | grep -q \"if: inputs.secrets-source == 'openbao' && inputs.openbao-tools != ''\""
  check "$n: logs in only when secrets-source is openbao" "grep -q \"inputs.secrets-source == 'openbao'\" '$f'"
  check "$n: openbao-tools input defaults to empty" "grep -A12 '^      openbao-tools:' '$f' | grep -q 'default: \"\"'"
  # Every read passes exactly one of tools / shared, from the same test on openbao-tools.
  check "$n: each read chooses tools or shared on openbao-tools" \
    "[ \"\$(grep -c \"^          tools: \\\${{ contains(format(' {0} ', inputs.openbao-tools)\" '$f')\" = \"\$(grep -c \"^          shared: \\\${{ !contains(format(' {0} ', inputs.openbao-tools)\" '$f')\" ] && ! grep -q '^          shared: |' '$f'"
done
# The guarded form, evaluated with GitHub's operators: && and || return an
# operand (first falsy / first truthy), like Python's `and` / `or`, and '' and
# null are falsy in both. The template is taken from the files (every read must
# share it), translated token by token, and checked over every case.
if command -v python3 >/dev/null 2>&1; then
  check "the guarded form: openbao mode gives env.X or '', every other mode exactly what the old form gave" "python3 - '$NODE' '$DOCKER' '$PY' <<'EOF'
import re, sys
templates = set()
for f in sys.argv[1:]:
    for line in open(f):
        m = re.search(r\"\\$\\{\\{ (inputs\\.secrets-source == 'openbao' && env\\.([A-Z_]+) .*?) \\}\\}\", line)
        if m:
            templates.add(m.group(1).replace(m.group(2), 'X'))
assert len(templates) == 1, templates
t = templates.pop()
py = (t.replace('inputs.secrets-source', 'src').replace('env.X', 'env').replace('secrets.X', 'sec')
       .replace('&&', 'and').replace('||', 'or'))
new = eval('lambda src, env, sec: ' + py)
old = lambda src, env, sec: (src == 'openbao' and env) or sec
show = lambda v: '' if v is None or v is False else v   # how GitHub renders null / false into a string input
for src in ('openbao', 'github', 'something-else'):
    for env in (None, '', 'from-openbao'):
        for sec in (None, '', 'from-github'):
            got = show(new(src, env, sec))
            want = show(env) if src == 'openbao' else show(old(src, env, sec))
            assert got == want, (src, env, sec, got, want)
EOF"
else
  echo "SKIP - python3 not found (guarded-form evaluation)"
fi

# The Check openbao-tools step: one text in all three workflows, run with sample lists.
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  run_of "$DOCKER" docker "Check openbao-tools" >"$tmp/check.sh"
  check "Check openbao-tools: node-workflow.yml has the same text as docker-build.yml" "run_of '$NODE' node-ci 'Check openbao-tools' | cmp -s - '$tmp/check.sh'"
  check "Check openbao-tools: python-ci.yml has the same text as docker-build.yml" "run_of '$PY' test 'Check openbao-tools' | cmp -s - '$tmp/check.sh'"
  tools_ok()  { env -i PATH="$PATH" OPENBAO_TOOLS="$1" bash -eo pipefail "$tmp/check.sh" >/dev/null 2>&1; }
  # Output only; the step's own exit status is tools_ok's business (and this
  # file runs under pipefail, so a failing step would fail the grep after it).
  tools_err() { env -i PATH="$PATH" OPENBAO_TOOLS="$1" bash -eo pipefail "$tmp/check.sh" 2>&1 || true; }
  check "Check openbao-tools accepts one tool" "tools_ok nexus"
  check "Check openbao-tools accepts every known tool, single spaces" "tools_ok 'nexus sonarqube dependency-track dockerhub cosign'"
  check "Check openbao-tools refuses a misspelled tool, naming it" "! tools_ok 'nexus sonarqbue' && tools_err 'nexus sonarqbue' | grep -q \"Unknown tool 'sonarqbue'\""
  check "Check openbao-tools refuses a comma-separated list" "! tools_ok 'nexus,sonarqube'"
  check "Check openbao-tools refuses a newline-separated list" "! tools_ok \$'nexus\\nsonarqube'"
  check "Check openbao-tools refuses a trailing newline (a '>' block scalar)" "! tools_ok \$'nexus sonarqube\\n'"
  check "Check openbao-tools refuses a tab" "! tools_ok \$'nexus\\tsonarqube'"
  check "Check openbao-tools refuses a double space" "! tools_ok 'nexus  sonarqube'"
  check "Check openbao-tools refuses a capitalised name" "! tools_ok 'Nexus'"
  check "  ...and shows the list it got, escaped" "tools_err \$'nexus\\nsonarqube' | grep -qF \"\\\$'nexus\\\\nsonarqube'\""

  # python-ci's SonarQube preflight names the OpenBao path of an empty value.
  run_of "$PY" sonarqube "Check SonarQube URL and token" >"$tmp/sonar.sh"
  sonar() { env -i PATH="$PATH" SONAR_HOST_URL="$1" SONAR_TOKEN="$2" SONAR_HOST_URL_AT="$3" SONAR_TOKEN_AT="$4" bash "$tmp/sonar.sh" 2>&1 || true; }
  check "python-ci preflight: empty URL in the ocs layout names ocs/ci/shared/SONAR_HOST_URL" \
    "sonar '' tok 'ocs/ci/shared/SONAR_HOST_URL (key value)' 'ocs/ci/shared/SONAR_TOKEN (key value)' | grep -q 'OpenBao has no value at ocs/ci/shared/SONAR_HOST_URL (key value).*openbao-tools'"
  check "python-ci preflight: empty token in the devsecops layout names the field" \
    "sonar https://sonar.example '' 'devsecops/ci/dev/sonarqube (field url)' 'devsecops/ci/dev/sonarqube (field token)' | grep -q 'SONAR_TOKEN is empty: OpenBao has no value at devsecops/ci/dev/sonarqube (field token)'"
  check "python-ci preflight: github mode keeps its message" \
    "sonar '' tok '' '' | grep -qx '::error::SONAR_HOST_URL is empty. Add it as a repository or organization secret; for an org secret, check that this repo is in its access list. With secrets-source: openbao it comes from OpenBao (docs/openbao-secrets.md).'"
else
  echo "SKIP - python3 with PyYAML not found (step behaviour)"
fi
check "python-ci.yml: the preflight's OpenBao paths follow the read (ocs/ci/shared, or devsecops when sonarqube is listed)" \
  "grep -q \"SONAR_HOST_URL_AT: .*' sonarqube ').*devsecops/ci/{0}/sonarqube (field url).*ocs/ci/shared/SONAR_HOST_URL (key value)\" '$PY' && grep -q \"SONAR_TOKEN_AT: .*' sonarqube ').*devsecops/ci/{0}/sonarqube (field token).*ocs/ci/shared/SONAR_TOKEN (key value)\" '$PY'"

# Cosign: read exactly when it is used, so a branch build never reads a signing key.
check "docker-build.yml: the Cosign read has its consumer's gate (sign-image and release)" \
  "grep -A1 '^      - name: Read Cosign secrets from OpenBao' '$DOCKER' | grep -q \"if: inputs.secrets-source == 'openbao' && inputs.sign-image && inputs.release\$\" && grep -A1 '^      - name: Sign image (Cosign)' '$DOCKER' | grep -q 'if: \${{ inputs.sign-image && inputs.release }}'"

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
