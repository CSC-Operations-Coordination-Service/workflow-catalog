#!/usr/bin/env bash
# Static checks for the OpenBao secrets path of the catalog workflows.
# Run from anywhere: bash tests/openbao_secrets_test.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ACT="$ROOT/.github/actions/openbao-secrets/action.yml"
NODE="$ROOT/.github/workflows/node-workflow.yml"
DOCKER="$ROOT/.github/workflows/docker-build.yml"
PY="$ROOT/.github/workflows/python-ci.yml"
SBOM="$ROOT/.github/workflows/sbom.yml"
fail=0
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
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
# The signing key has a login role of its own (behaviour: tools test).
check "action logs in as <role>-sign when tools is cosign alone" "grep -q \"const signing = tools.length === 1 && tools\\[0\\] === 'cosign';\" '$ACT' && grep -q -- '-sign\`' '$ACT'"
# The catalog is public: its messages point at the platform repository's OpenBao
# configuration, never at its files or its operations.
check "action messages ask whether OpenBao is sealed, and point at the platform's configuration, without detail" "[ \"\$(grep -c 'Check, in order: is OpenBao SEALED? Does this job' '$ACT')\" = 2 ] && grep -q \"Its policies are in the platform repository's OpenBao configuration.\\\`);\" '$ACT'"
# The platform repository's CI-secrets tool writes devsecops/ci/<kind>/<tool>
# (its devsecops layout): the operator's message names it, by what it is, not
# by its path, and nothing still says it does not write this layout.
check "the devsecops message names the platform's CI-secrets tool as the writer" "grep 'const HOWTO' '$ACT' | grep -q \"the platform repository's CI-secrets tool (devsecops layout, component \\\${tool}\" && ! grep -q 'does not write this layout' '$ACT'"
# Nor does any catalog text name the private platform repository, its files or
# a real host, and no workflow, action or doc names a real CI role (the public
# form is ci-<repo>). The patterns match shapes, not whole names, so that this
# file does not spell what it keeps out. PRIVATE: one alternative per kind of
# private name (the platform repository, its CI-secrets tool, its file tree, its
# hosts); the prose "CI-secrets tool" is upper case and passes. ROLE: a role with
# more than one word after ci- (ci-<repo> has one), in .github, docs and README
# only, because the tests use made-up roles such as ci-x-release. Every file git
# knows, tracked or new, is searched, this one excepted. A failure prints
# file:line only, never the text that matched.
PRIVATE='[[:alnum:]]-ansible|ci[-_]secrets|stacks/[a-z]+/|[a-z]+-[a-z]+-[a-z]+-[0-9][0-9]([^0-9]|$)'
ROLE='(^|[^[:alnum:]-])ci-[a-z0-9]+-[a-z0-9]'
catalog_grep() {  # catalog_grep <ERE> <path>...: file:line of each match
  local re="$1"; shift
  if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$ROOT" grep --untracked -nIE -e "$re" -- "$@" ':!tests/openbao_secrets_test.sh'
  else  # not a git checkout: the catalog's own directories
    [ "$*" = . ] && set -- .github docs scripts tests README.md
    (cd "$ROOT" && grep -rnIE --exclude=openbao_secrets_test.sh -e "$re" -- "$@")
  fi | cut -d: -f1,2
}
none_of() { local hits; hits="$(catalog_grep "$@")"; [ -z "$hits" ] || { printf '  %s\n' $hits; false; }; }
check "no catalog text names the private platform repository, its files or a real host" "none_of '$PRIVATE' ."
check "no workflow, action or doc names a real CI role" "none_of '$ROLE' .github docs README.md"
# The patterns themselves: each catches what it is for. The samples are made
# up, say no more than the patterns do, and are built from parts, so that no
# sample appears whole in this file.
guard_catches() { printf '%s\n' "$2" | grep -Eq "$1"; }
check "  ...the patterns catch what they are for" \
  "guard_catches '$PRIVATE' 'see x''x-ansible' && guard_catches '$PRIVATE' 'ci''-secrets' && guard_catches '$PRIVATE' 'ci''_secrets' && guard_catches '$PRIVATE' 'stacks''/abc/x' && guard_catches '$PRIVATE' 'aaa-bbbb-cccc''-02.example' && guard_catches '$ROLE' 'role ci-abc''-def-ghi'"
check "  ...and leave the public forms alone" \
  "! guard_catches '$PRIVATE' \"the platform repository's CI-secrets tool, ci-<repo>, dev.ocs-registry.local\" && ! guard_catches '$ROLE' 'ci-<repo>-sign, <openbao-role>-release, tok-ci-x-sign'"
# The openbao mode is for any repository with a JWT role, public or private. The
# text that kept it to private repositories (copied from one workflow to the
# next) does not come back.
ONLY_PRIVATE='for (a )?private repositor|\(private repositories\)|cannot use organi[sz]ation secrets'
check "no text keeps the openbao mode to private repositories" "none_of '$ONLY_PRIVATE' .github docs README.md"
check "  ...the pattern catches that text, and leaves 'public or private' alone" \
  "guard_catches '$ONLY_PRIVATE' 'for private ''repositories that' && guard_catches '$ONLY_PRIVATE' 'OpenBao (private ''repositories)' && ! guard_catches '$ONLY_PRIVATE' 'in any repository, public or private, that has'"
# A fork's pull request gets no OIDC token, except through the events a fork can
# start that run in the base repository's context. The doc names that class by
# several of its events, never one event as "the exception".
DOC="$ROOT/docs/openbao-secrets.md"
check "docs/openbao-secrets.md names the base-context events a fork can start, not pull_request_target alone" \
  "grep -q 'pull_request_target' '$DOC' && grep -q 'workflow_run' '$DOC' && grep -q 'issue_comment' '$DOC' && ! grep -q 'is the exception' '$DOC'"

# --- the workflows
# Reads of a managed value that are NOT in the guarded form
#   inputs.secrets-source == 'openbao' && env.X || (inputs.secrets-source != 'openbao' && secrets.X || '')
# In openbao mode that form gives env.X or '', never secrets.X: a gap in OpenBao
# stays a gap instead of being filled by a GitHub secret through secrets: inherit.
# Every guarded form is cut out first, then any secrets.X left is a read outside
# it, wherever it sits: a second ${{ }} on the same line, or an if: without
# ${{ }}. Prints file:line:text of each line holding one (GNU sed and grep).
GUARDED="inputs\.secrets-source == 'openbao' && env\.([A-Z_]+) \|\| \(inputs\.secrets-source != 'openbao' && secrets\.\1 \|\| ''\)"
unguarded() { sed -E "s/$GUARDED//g" "$1" | grep -En "secrets\.($MANAGED)\b"; }
# unguarded() on itself: one guarded read is clean; anything else next to it,
# or a guarded form whose env.X and secrets.X differ, is reported.
G="inputs.secrets-source == 'openbao' && env.NEXUS_HOST || (inputs.secrets-source != 'openbao' && secrets.NEXUS_HOST || '')"
G_MIXED="inputs.secrets-source == 'openbao' && env.NEXUS_HOST || (inputs.secrets-source != 'openbao' && secrets.NEXUS_PORT || '')"
flags() { printf '%s\n' "$1" >"$tmp/unguarded.yml"; [ -n "$(unguarded "$tmp/unguarded.yml")" ]; }
u_clean()    { ! flags "a: \${{ $G }} \${{ $G }}"; }
u_after()    { flags "a: \${{ $G }}/\${{ secrets.NEXUS_PORT }}"; }
u_inside()   { flags "a: \${{ $G || secrets.NEXUS_HOST }}"; }
u_bare_if()  { flags "if: secrets.NEXUS_HOST != ''"; }
u_mixed()    { flags "a: \${{ $G_MIXED }}"; }
check "unguarded(): two guarded reads on one line are clean" u_clean
check "unguarded(): flags an unguarded \${{ }} after a guarded one on the same line" u_after
check "unguarded(): flags secrets.X inside the same \${{ }} as a guarded form" u_inside
check "unguarded(): flags an if: without \${{ }}" u_bare_if
check "unguarded(): flags a guarded form whose env.X and secrets.X differ" u_mixed
# The other half: reads of env.X outside the guarded form. env.X alone is the
# openbao value only, so a caller in github mode (the default) gets '' there.
# unguarded() cannot see it: such a line names no secrets.X.
env_only() { sed -E "s/$GUARDED//g" "$1" | grep -En "env\.($MANAGED)\b"; }
flags_env() { printf '%s\n' "$1" >"$tmp/env_only.yml"; [ -n "$(env_only "$tmp/env_only.yml")" ]; }
e_clean() { ! flags_env "a: \${{ $G }}" && ! flags_env "a: \${{ env.NEXUS_DOCKER_REGISTRY }}"; }
e_alone() { flags_env "a: \${{ env.NEXUS_HOST }}" && flags_env "a: \${{ $G }}/\${{ env.NEXUS_PORT }}"; }
check "env_only(): a guarded read, and an env value the workflows set themselves, are clean" e_clean
check "env_only(): flags env.X read alone, also next to a guarded read" e_alone
# Step text as YAML sees it: run_of <workflow> <job> <step name>
run_of() { python3 - "$1" "$2" "$3" <<'EOF'
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["jobs"][sys.argv[2]]["steps"]
print([s for s in steps if s.get("name") == sys.argv[3]][0]["run"], end="")
EOF
}
for f in "$NODE" "$DOCKER" "$PY" "$SBOM"; do
  n="$(basename "$f")"
  check "$n: secrets-source input defaults to github" "grep -A16 '^      secrets-source:' '$f' | grep -q 'default: github'"
  check "$n: has openbao-url and openbao-role inputs" "grep -q '^      openbao-url:' '$f' && grep -q '^      openbao-role:' '$f'"
  # Only the lines that still read secrets.X: that each consuming input still
  # has one is pinned below ("github mode is pinned").
  check "$n: every line that reads a managed secret also tests secrets-source" \
    "! grep -En 'secrets\.($MANAGED)' '$f' | grep -v 'secrets-source'"
  check "$n: in openbao mode no value falls back to secrets.* (every read is the guarded form)" \
    "grep -Eq 'secrets\.($MANAGED)' '$f' && [ -z \"\$(unguarded '$f')\" ] || (unguarded '$f'; false)"
  check "$n: in github mode no value is read from env.* alone (every read is the guarded form)" \
    "[ -z \"\$(env_only '$f')\" ] || (env_only '$f'; false)"
  check "$n: a 'Check secrets-source and openbao-tools' step runs under sh" \
    "grep -A1 '^      - name: Check secrets-source and openbao-tools\$' '$f' | grep -qx '        shell: sh'"
  check "$n: logs in only when secrets-source is openbao" "grep -q \"inputs.secrets-source == 'openbao'\" '$f'"
  check "$n: openbao-tools input defaults to empty" "grep -A12 '^      openbao-tools:' '$f' | grep -q 'default: \"\"'"
  # Every read passes exactly one of tools / shared, from the same test on openbao-tools.
  check "$n: each read chooses tools or shared on openbao-tools" \
    "[ \"\$(grep -c \"^          tools: \\\${{ contains(format(' {0} ', inputs.openbao-tools)\" '$f')\" = \"\$(grep -c \"^          shared: \\\${{ !contains(format(' {0} ', inputs.openbao-tools)\" '$f')\" ] && ! grep -q '^          shared: |' '$f'"
done
# The guarded form, evaluated with GitHub's operators: && and || return an
# operand (first falsy / first truthy), like Python's `and` / `or`, and '' and
# null are falsy in both. The template is taken from the files (every read must
# share it), translated token by token, and checked over every case, each result
# rendered as GitHub renders it into an input: null as '', false as 'false'.
if command -v python3 >/dev/null 2>&1; then
  cat >"$tmp/guarded_model.py" <<'EOF'
# guarded_model.py <variant> <workflow>...: prints each case where the form
# gives other than it must, exits 1 if there is one. variant: as-is, or
# no-trailing-default (the form without its last || '').
import re, sys
variant, files = sys.argv[1], sys.argv[2:]
templates = set()
for f in files:
    for line in open(f):
        for m in re.finditer(r"\$\{\{ (inputs\.secrets-source == 'openbao' && env\.([A-Z_]+) .*?) \}\}", line):
            templates.add(m.group(1).replace(m.group(2), 'X'))
assert len(templates) == 1, templates
t = templates.pop()
if variant == 'no-trailing-default':
    assert t.endswith(" || '')"), t
    t = t[:-len(" || '')")] + ')'
py = (t.replace('inputs.secrets-source', 'src').replace('env.X', 'env').replace('secrets.X', 'sec')
       .replace('&&', 'and').replace('||', 'or'))
new = eval('lambda src, env, sec: ' + py)
old = lambda src, env, sec: (src == 'openbao' and env) or sec
# How GitHub renders a value into a string input or env: null as '', a boolean
# as 'true' / 'false', a string as itself. A form that can yield false passes
# the string 'false' on: never empty.
show = lambda v: '' if v is None else 'true' if v is True else 'false' if v is False else v
bad = []
for src in ('openbao', 'github', 'something-else'):
    for env in (None, '', 'from-openbao'):
        for sec in (None, '', 'from-github'):
            got = show(new(src, env, sec))
            want = show(env) if src == 'openbao' else show(old(src, env, sec))
            if got != want:
                bad.append(f'src={src!r} env={env!r} sec={sec!r}: got {got!r}, want {want!r}')
print('\n'.join(bad) or 'every case as it must be')
sys.exit(1 if bad else 0)
EOF
  check "the guarded form: openbao mode gives env.X or '', every other mode exactly what the old form gave" \
    "python3 '$tmp/guarded_model.py' as-is '$NODE' '$DOCKER' '$PY' '$SBOM' >'$tmp/model.out' || (cat '$tmp/model.out'; false)"
  # The model has to tell '' from false: without its trailing || '' the form
  # yields false in openbao mode when env.X is empty, and GitHub passes 'false'.
  check "  ...and the model fails the form without its trailing || '' (it renders false as 'false')" \
    "! python3 '$tmp/guarded_model.py' no-trailing-default '$NODE' '$DOCKER' '$PY' '$SBOM' >'$tmp/model.out' && grep -q \"^src='openbao' env='' sec='from-github': got 'false', want ''\$\" '$tmp/model.out'"
else
  echo "SKIP - python3 not found (guarded-form evaluation)"
fi

# --- github mode is pinned: each input that takes a managed value holds the
# guarded form of its own value, so a caller with the default secrets-source
# still gets secrets.X there. The checks above read the text that names a
# managed value: an input turned into a literal, dropped, or given another
# value's guarded form (nexus-port reading NEXUS_HOST) names nothing wrong and
# passes them. PINNED: input or env name -> the value it carries, wherever a
# step of the four workflows sets it. ACTIONS: each step that uses one of these
# actions sets all of its inputs. STEPS: how many such steps each workflow has,
# so that a step gone whole is seen too.
if python3 -c 'import yaml' 2>/dev/null; then
  cat >"$tmp/pinned.py" <<'EOF'
# pinned.py <workflow>...: prints each pinned input that is not the guarded form
# of its own value, each input an action does not get, and each workflow with
# another number of consuming steps; exits 1 if there is one. Names only.
import os, sys, yaml
G = "${{ inputs.secrets-source == 'openbao' && env.%(x)s || (inputs.secrets-source != 'openbao' && secrets.%(x)s || '') }}"
NEXUS = {"nexus-host": "NEXUS_HOST", "nexus-port": "NEXUS_PORT",
         "nexus-username": "NEXUS_USERNAME", "nexus-password": "NEXUS_PASSWORD"}
DT = {"server-url": "DEPENDENCYTRACK_URL", "api-key": "DEPENDENCYTRACK_API_KEY"}
# python-ci.yml's env consumers, one value each. docker-build.yml's username and
# password inputs stand for several values: only the checks above cover them.
ENV = {"SONAR_TOKEN": "SONAR_TOKEN", "SONAR_HOST_URL": "SONAR_HOST_URL",
       "TWINE_USERNAME": "NEXUS_USERNAME", "TWINE_PASSWORD": "NEXUS_PASSWORD"}
PINNED = {**NEXUS, **DT, **ENV}
ACTIONS = {"/actions/nexus-context@": NEXUS, "/actions/npm-context@": NEXUS,
           "/actions/dependency-track-upload@": DT}
STEPS = {"node-workflow.yml": 2, "docker-build.yml": 1, "python-ci.yml": 2, "sbom.yml": 2}
bad = []
for f in sys.argv[1:]:
    n = os.path.basename(f)
    steps = 0
    for job, j in yaml.safe_load(open(f))["jobs"].items():
        for s in j.get("steps") or []:
            at = "%s %s '%s'" % (n, job, s.get("name"))
            for block in ("with", "env"):
                for k, v in (s.get(block) or {}).items():
                    if k in PINNED and v != G % {"x": PINNED[k]}:
                        bad.append("%s: %s is not the guarded form of %s" % (at, k, PINNED[k]))
            for ref, want in ACTIONS.items():
                if ref in s.get("uses", ""):
                    steps += 1
                    bad += ["%s: no %s" % (at, k) for k in want if k not in (s.get("with") or {})]
    if steps != STEPS[n]:
        bad.append("%s: %d steps take Nexus or Dependency-Track inputs, %d expected" % (n, steps, STEPS[n]))
print("\n".join(bad) or "every pinned input holds the guarded form of its own value")
sys.exit(1 if bad else 0)
EOF
  pinned() { python3 "$tmp/pinned.py" "$@"; }
  check "github mode is pinned: each Nexus and Dependency-Track input, and python-ci's SonarQube and twine env, is the guarded form of its own value" \
    "pinned '$NODE' '$DOCKER' '$PY' '$SBOM' >'$tmp/pinned.out' || (cat '$tmp/pinned.out'; false)"
  # The pin on itself, on copies of the workflows edited the ways that break a
  # github-mode caller. mutate <workflow> <sed -E script>: the edited copy, in
  # $M under the same name. It must differ from the original, or the sample
  # proves nothing.
  M="$tmp/mut"; mkdir -p "$M"
  mutate() { sed -E "$2" "$1" >"$M/$(basename "$1")" && ! cmp -s "$1" "$M/$(basename "$1")"; }
  # pin_refuses <copy> <message ERE>: the pin fails that copy, with that message.
  # Its output goes through a file: this script runs under pipefail.
  pin_refuses() { ! pinned "$1" >"$M/pinned.out" && grep -Eq -- "$2" "$M/pinned.out"; }
  p_env()     { mutate "$SBOM" 's/^(          server-url: ).*/\1${{ env.DEPENDENCYTRACK_URL }}/' && [ -z "$(unguarded "$M/sbom.yml")" ] && pin_refuses "$M/sbom.yml" 'server-url is not the guarded form of DEPENDENCYTRACK_URL$' && [ -n "$(env_only "$M/sbom.yml")" ]; }
  p_py_env()  { mutate "$PY" 's/^(          nexus-host: ).*/\1${{ env.NEXUS_HOST }}/' && pin_refuses "$M/python-ci.yml" "'Set up Nexus context': nexus-host is not the guarded form of NEXUS_HOST\$" && [ -n "$(env_only "$M/python-ci.yml")" ]; }
  p_literal() { mutate "$SBOM" 's|^(          server-url: ).*|\1https://dt.example|' && [ -z "$(env_only "$M/sbom.yml")" ] && pin_refuses "$M/sbom.yml" 'server-url is not the guarded form of DEPENDENCYTRACK_URL$'; }
  p_swap()    { mutate "$SBOM" 's/^(          nexus-port: .*)NEXUS_PORT(.*)NEXUS_PORT/\1NEXUS_HOST\2NEXUS_HOST/' && [ -z "$(unguarded "$M/sbom.yml")" ] && pin_refuses "$M/sbom.yml" 'nexus-port is not the guarded form of NEXUS_PORT$'; }
  p_dropped() { mutate "$SBOM" '/^          api-key: /d' && pin_refuses "$M/sbom.yml" "'Upload package SBOM to Dependency-Track': no api-key\$"; }
  p_step()    { mutate "$PY" 's|(/actions/nexus-context)@|\1-renamed@|' && pin_refuses "$M/python-ci.yml" '^python-ci.yml: 0 steps take Nexus or Dependency-Track inputs, 2 expected$'; }
  check "  ...and catches server-url read from env alone, which unguarded() lets through, as does env_only()" p_env
  check "  ...and python-ci.yml's nexus-host read from env alone" p_py_env
  check "  ...and an input turned into a literal" p_literal
  check "  ...and an input given another value's guarded form, which unguarded() lets through" p_swap
  check "  ...and an input dropped from its step" p_dropped
  check "  ...and a consuming step gone" p_step
else
  echo "SKIP - python3 with PyYAML not found (github mode pin)"
fi

# --- openbao mode is pinned: each OpenBao read gets exactly the inputs it must.
# The checks above see the form of a read (tools and shared chosen on the same
# test, environment passed), not what it asks for: a name dropped from or
# misspelled in its shared list, another tool in the result of its tools, or a
# suffix on its role passes them all, and the job then gets an empty value, or
# no login at all. READS: workflow, job and step -> the read's whole with:. Each
# read of the four workflows must be in it, and each of its entries be found.
# Apart from READS, a job's shared lists must give, together, exactly the
# managed values the job reads in the guarded form (the Cosign key excepted: the
# ocs layout never serves it), so that an entry and its workflow cannot go wrong
# together unseen.
if python3 -c 'import yaml' 2>/dev/null; then
  cat >"$tmp/reads.py" <<'EOF'
# reads.py <workflow>...: prints each OpenBao read whose with: is not as pinned,
# each read the pin does not know or does not find, and each job whose shared
# lists do not give what it reads; exits 1 if there is one. Names only.
import os, re, sys, yaml
def pick(tool, names):  # tools / shared of a read that chooses its layout on openbao-tools
    return {"tools": "${{ contains(format(' {0} ', inputs.openbao-tools), ' %s ') && '%s' || '' }}" % (tool, tool),
            "shared": "${{ !contains(format(' {0} ', inputs.openbao-tools), ' %s ') && '%s' || '' }}" % (tool, " ".join(names))}
def env(name):  # the action's environment, from the workflow's own input
    return {"environment": "${{ inputs.%s }}" % name}
NEXUS = ["NEXUS_HOST", "NEXUS_PORT", "NEXUS_USERNAME", "NEXUS_PASSWORD"]
REGISTRY = ["NEXUS_DOCKER_REGISTRY_DEV", "NEXUS_DOCKER_REGISTRY_PROD"]
DT = ["DEPENDENCYTRACK_URL", "DEPENDENCYTRACK_API_KEY"]
READS = {
    ("node-workflow.yml", "node-ci", "Read secrets from OpenBao"): pick("nexus", NEXUS),
    ("node-workflow.yml", "sbom-publish", "Read secrets from OpenBao"): pick("dependency-track", DT),
    ("docker-build.yml", "docker", "Read secrets from OpenBao"): {**pick("nexus", NEXUS + REGISTRY), **env("environment")},
    ("docker-build.yml", "docker", "Read Docker Hub secrets from OpenBao"): {**pick("dockerhub", ["DOCKERHUB_USERNAME", "DOCKERHUB_TOKEN"]), **env("environment")},
    ("docker-build.yml", "docker", "Read Dependency-Track secrets from OpenBao"): {**pick("dependency-track", DT), **env("environment")},
    ("docker-build.yml", "docker", "Read Cosign secrets from OpenBao"): {"tools": "cosign", **env("environment")},
    ("python-ci.yml", "test", "Read Nexus secrets from OpenBao"): pick("nexus", NEXUS),
    ("python-ci.yml", "sonarqube", "Read SonarQube secrets from OpenBao"): pick("sonarqube", ["SONAR_TOKEN", "SONAR_HOST_URL"]),
    ("python-ci.yml", "build", "Read Nexus secrets from OpenBao"): pick("nexus", NEXUS),
    ("sbom.yml", "sbom", "Read Nexus secrets from OpenBao"): {**pick("nexus", NEXUS), **env("context")},
    ("sbom.yml", "publish", "Read Dependency-Track secrets from OpenBao"): {**pick("dependency-track", DT), **env("context")},
}
# Every read: the caller's URL, and the base role as given (the action adds
# -release or -sign itself; a suffix here fails every login).
COMMON = {"openbao-url": "${{ inputs.openbao-url }}", "role": "${{ inputs.openbao-role }}"}
GUARDED = re.compile(r"inputs\.secrets-source == 'openbao' && env\.([A-Z_]+) \|\|")
NAMES = re.compile(r"&& '([A-Z_ ]*)' \|\| '' \}\}$")
def strings(o):  # every string in a step, keys and values
    if isinstance(o, dict):
        for k, v in o.items():
            yield str(k); yield from strings(v)
    elif isinstance(o, list):
        for v in o:
            yield from strings(v)
    elif o is not None:
        yield str(o)
bad, seen = [], set()
files = {os.path.basename(f): f for f in sys.argv[1:]}
for n, f in files.items():
    for job, j in yaml.safe_load(open(f))["jobs"].items():
        given, used = set(), set()
        for s in j.get("steps") or []:
            used |= {x for t in strings(s) for x in GUARDED.findall(t)}
            if "/actions/openbao-secrets@" not in s.get("uses", ""):
                continue
            key = (n, job, s.get("name"))
            at = "%s %s '%s'" % key
            w = s.get("with") or {}
            if "shared" in w:
                m = NAMES.search(str(w["shared"]))
                if m:
                    given |= set(m.group(1).split())
                else:
                    bad.append("%s: shared names no list of values" % at)
            if key not in READS:
                bad.append("%s: a read the pin does not know" % at)
                continue
            seen.add(key)
            want = {**COMMON, **READS[key]}
            bad += ["%s: no %s" % (at, k) for k in want if k not in w]
            bad += ["%s: unexpected %s" % (at, k) for k in w if k not in want]
            bad += ["%s: %s is not as pinned" % (at, k) for k in want if k in w and w[k] != want[k]]
        used = {x for x in used if not x.startswith("COSIGN_")}
        if used - given:
            bad.append("%s %s: its shared lists do not give %s, which the job reads" % (n, job, " ".join(sorted(used - given))))
        if given - used:
            bad.append("%s %s: its shared lists give %s, which nothing in the job reads" % (n, job, " ".join(sorted(given - used))))
bad += ["%s %s '%s': pinned read not found" % k for k in READS if k[0] in files and k not in seen]
print("\n".join(bad) or "every OpenBao read gets its pinned inputs, and every job's shared lists give what it reads")
sys.exit(1 if bad else 0)
EOF
  reads() { python3 "$tmp/reads.py" "$@"; }
  check "openbao mode is pinned: each OpenBao read gets exactly its pinned inputs, and each job's shared lists give what it reads" \
    "reads '$NODE' '$DOCKER' '$PY' '$SBOM' >'$tmp/reads.out' || (cat '$tmp/reads.out'; false)"
  # The pin on itself, on copies edited the ways that break an openbao-mode
  # caller and that every other check lets through (mutate: above).
  # read_refuses <copy> <message ERE>...: the pin fails that copy, with each message.
  read_refuses() {
    local f="$1" re; shift
    ! reads "$f" >"$M/reads.out" || return 1
    for re in "$@"; do grep -Eq -- "$re" "$M/reads.out" || return 1; done
  }
  NX="sbom.yml sbom 'Read Nexus secrets from OpenBao'"
  DTR="sbom.yml publish 'Read Dependency-Track secrets from OpenBao'"
  r_drop()     { mutate "$SBOM" "s/^(          shared: .*NEXUS_USERNAME) NEXUS_PASSWORD'/\\1'/" && pinned "$M/sbom.yml" >/dev/null && read_refuses "$M/sbom.yml" "^$NX: shared is not as pinned\$" '^sbom.yml sbom: its shared lists do not give NEXUS_PASSWORD, which the job reads$'; }
  r_typo()     { mutate "$SBOM" "s/^(          shared: .*)DEPENDENCYTRACK_API_KEY'/\\1DEPENDENCYTRACK_APIKEY'/" && read_refuses "$M/sbom.yml" "^$DTR: shared is not as pinned\$" '^sbom.yml publish: its shared lists do not give DEPENDENCYTRACK_API_KEY, which the job reads$' '^sbom.yml publish: its shared lists give DEPENDENCYTRACK_APIKEY, which nothing in the job reads$'; }
  r_role()     { mutate "$SBOM" 's/^(          role: \$\{\{ inputs\.openbao-role \}\})$/\1-release/' && read_refuses "$M/sbom.yml" "^$NX: role is not as pinned\$" "^$DTR: role is not as pinned\$"; }
  r_widen()    { mutate "$SBOM" "s/^(          tools: .*' nexus '\\) && )'nexus'/\\1'nexus dependency-track'/" && read_refuses "$M/sbom.yml" "^$NX: tools is not as pinned\$"; }
  r_tool()     { mutate "$SBOM" "s/^(          tools: .*' dependency-track '\\) && )'dependency-track'/\\1'dependencytrack'/" && read_refuses "$M/sbom.yml" "^$DTR: tools is not as pinned\$"; }
  r_extra()    { mutate "$SBOM" 's/^(          environment: \$\{\{ inputs\.context \}\})$/\1\n          repo: EXTRA/' && read_refuses "$M/sbom.yml" "^$NX: unexpected repo\$" "^$DTR: unexpected repo\$"; }
  r_unknown()  { mutate "$SBOM" 's/^(      - name: Read Nexus secrets from OpenBao)$/\1 again/' && read_refuses "$M/sbom.yml" "^sbom.yml sbom 'Read Nexus secrets from OpenBao again': a read the pin does not know\$" "^$NX: pinned read not found\$"; }
  r_py_drop()  { mutate "$PY" "s/^(          shared: .*NEXUS_USERNAME) NEXUS_PASSWORD'/\\1'/" && read_refuses "$M/python-ci.yml" "^python-ci.yml test 'Read Nexus secrets from OpenBao': shared is not as pinned\$" "^python-ci.yml build 'Read Nexus secrets from OpenBao': shared is not as pinned\$"; }
  r_py_role()  { mutate "$PY" 's/^(          role: \$\{\{ inputs\.openbao-role \}\})$/\1-release/' && read_refuses "$M/python-ci.yml" "^python-ci.yml sonarqube 'Read SonarQube secrets from OpenBao': role is not as pinned\$"; }
  check "  ...and catches a name dropped from sbom.yml's Nexus shared list, which the github-mode pin lets through" r_drop
  check "  ...and a misspelled name in sbom.yml's Dependency-Track shared list" r_typo
  check "  ...and a suffix on the role of sbom.yml's reads" r_role
  check "  ...and another tool added to the result of sbom.yml's Nexus tools" r_widen
  check "  ...and a misspelled tool in the result of sbom.yml's Dependency-Track tools" r_tool
  check "  ...and an input the pin does not have" r_extra
  check "  ...and a read the pin does not know, or a pinned read gone" r_unknown
  check "  ...and python-ci.yml's Nexus shared lists and role, the same way" "r_py_drop && r_py_role"
else
  echo "SKIP - python3 with PyYAML not found (openbao mode pin)"
fi

# The Check step: one text in all four workflows, run under every sh it can
# meet, before every OpenBao read.
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
  STEP="Check secrets-source and openbao-tools"
  run_of "$DOCKER" docker "$STEP" >"$tmp/check.sh"
  check "$STEP: node-workflow.yml has the same text as docker-build.yml" "run_of '$NODE' node-ci '$STEP' | cmp -s - '$tmp/check.sh'"
  check "$STEP: python-ci.yml has the same text as docker-build.yml" "run_of '$PY' test '$STEP' | cmp -s - '$tmp/check.sh'"
  check "$STEP: sbom.yml has the same text as docker-build.yml" "run_of '$SBOM' sbom '$STEP' | cmp -s - '$tmp/check.sh'"
  # It guards every read only if it runs in every mode and first: in the job
  # that reads, or in a job that reading job needs (a failed need skips the job
  # unless its if: says always() or !cancelled()).
  check "$STEP: runs under sh with no if:, before every OpenBao read" "python3 - '$NODE' '$DOCKER' '$PY' '$SBOM' '$STEP' <<'EOF'
import sys, yaml
*files, name = sys.argv[1:]
for f in files:
    jobs = yaml.safe_load(open(f))['jobs']
    names = {j: [s.get('name') for s in job.get('steps', [])] for j, job in jobs.items()}
    has = {j: name in n for j, n in names.items()}
    assert any(has.values()), f
    for j, job in jobs.items():
        steps = job.get('steps', [])
        if has[j]:
            step = steps[names[j].index(name)]
            assert step.get('shell') == 'sh' and 'if' not in step, (f, j, step.get('shell'), step.get('if'))
        reads = [i for i, s in enumerate(steps) if 'openbao-secrets' in s.get('uses', '')]
        if not reads:
            continue
        if has[j]:
            assert names[j].index(name) < reads[0], (f, j, 'read before the check')
        else:
            needs = job.get('needs', [])
            needs = [needs] if isinstance(needs, str) else needs
            assert any(has.get(n) for n in needs), (f, j, 'no check in the job or its needs', needs)
            cond = str(job.get('if', ''))
            assert 'always()' not in cond and 'cancelled()' not in cond, (f, j, cond)
EOF"

  # GitHub runs `shell: sh` as `sh -e {0}`. That sh is dash on Debian and
  # Ubuntu (node:<v>, python:<v>, the runner hosts), busybox ash on Alpine
  # (node:<v>-alpine), bash in POSIX mode where /bin/sh is bash. Busybox runs
  # with nothing but its own applets on PATH (awk included), as on Alpine.
  shells="bash"
  if command -v dash >/dev/null 2>&1; then shells="dash $shells"; else echo "SKIP - dash not found"; fi
  if command -v busybox >/dev/null 2>&1; then
    mkdir "$tmp/bb"
    for a in $(busybox --list); do ln -s "$(command -v busybox)" "$tmp/bb/$a"; done
    shells="$shells busybox"
  else
    echo "SKIP - busybox not found"
  fi
  in_sh() {  # in_sh <shell> <option> <script> [VAR=value ...]
    local sh="$1" opt="$2" script="$3"; shift 3
    case "$sh" in
      dash) env -i PATH="$PATH" "$@" dash "$opt" "$script" ;;
      bash) env -i PATH="$PATH" "$@" bash --posix "$opt" "$script" ;;
      busybox) env -i PATH="$tmp/bb" "$@" "$tmp/bb/sh" "$opt" "$script" ;;
    esac
  }
  for sh in $shells; do
    step_ok()  { in_sh "$sh" -e "$tmp/check.sh" SECRETS_SOURCE="$1" OPENBAO_TOOLS="$2" >/dev/null 2>&1; }
    # Output only; the step's own exit status is step_ok's business (and this
    # file runs under pipefail, so a failing step would fail the grep after it).
    step_err() { in_sh "$sh" -e "$tmp/check.sh" SECRETS_SOURCE="$1" OPENBAO_TOOLS="$2" 2>&1 || true; }
    shows_escaped() { step_err openbao $'nexus\nsonarqube' | grep -qF "(got 'nexus\\nsonarqube')"; }
    check "[$sh] $STEP: parses (-n)" "in_sh $sh -n '$tmp/check.sh'"
    check "[$sh] accepts secrets-source github (the default), whatever openbao-tools holds" "step_ok github '' && step_ok github 'nexus,typo'"
    check "[$sh] accepts secrets-source openbao without openbao-tools" "step_ok openbao ''"
    check "[$sh] refuses a misspelled secrets-source, naming it" "! step_ok open-bao '' && step_err open-bao '' | grep -qF \"secrets-source must be 'github' (the default) or 'openbao', got 'open-bao'.\""
    check "[$sh] refuses an empty, capitalised or padded secrets-source" "! step_ok '' '' && ! step_ok OpenBao '' && ! step_ok 'openbao ' '' && ! step_ok \$'openbao\\n' ''"
    check "[$sh] accepts one tool" "step_ok openbao nexus"
    check "[$sh] accepts every known tool, single spaces" "step_ok openbao 'nexus sonarqube dependency-track dockerhub cosign'"
    check "[$sh] refuses a misspelled tool, naming it" "! step_ok openbao 'nexus sonarqbue' && step_err openbao 'nexus sonarqbue' | grep -q \"Unknown tool 'sonarqbue'\""
    check "[$sh] refuses a comma-separated list" "! step_ok openbao 'nexus,sonarqube'"
    check "[$sh] refuses a newline-separated list" "! step_ok openbao \$'nexus\\nsonarqube'"
    check "[$sh] refuses a trailing newline (a '>' block scalar)" "! step_ok openbao \$'nexus sonarqube\\n'"
    check "[$sh] refuses a tab" "! step_ok openbao \$'nexus\\tsonarqube'"
    check "[$sh] refuses a double, leading or trailing space" "! step_ok openbao 'nexus  sonarqube' && ! step_ok openbao ' nexus' && ! step_ok openbao 'nexus '"
    check "[$sh] refuses a capitalised name, and a glob" "! step_ok openbao 'Nexus' && ! step_ok openbao 'nex*'"
    check "[$sh]   ...and shows the list it got on one line, a newline as \\n" shows_escaped
    # Signing in openbao mode: cosign listed, a tag build, environment prod.
    # sign_ok <source> <tools> <sign-image> <release> <ref_type> <environment>,
    # as docker-build.yml passes them.
    sign_ok()  { in_sh "$sh" -e "$tmp/check.sh" SECRETS_SOURCE="$1" OPENBAO_TOOLS="$2" SIGN_IMAGE="$3" RELEASE="$4" REF_TYPE="$5" ENVIRONMENT="$6" >/dev/null 2>&1; }
    sign_err() { in_sh "$sh" -e "$tmp/check.sh" SECRETS_SOURCE="$1" OPENBAO_TOOLS="$2" SIGN_IMAGE="$3" RELEASE="$4" REF_TYPE="$5" ENVIRONMENT="$6" 2>&1 || true; }
    check "[$sh] refuses sign-image on a release build in openbao mode without cosign, naming the rule" \
      "! sign_ok openbao nexus true true tag prod && sign_err openbao nexus true true tag prod | grep -qF \"::error::sign-image on a release build in openbao mode needs cosign in openbao-tools (got 'nexus'). Signing in openbao mode reads the key with the <openbao-role>-sign role\""
    check "[$sh]   ...also with openbao-tools empty (no ocs/ci/shared fallback for the key)" "! sign_ok openbao '' true true tag prod && sign_err openbao '' true true tag prod | grep -q 'needs cosign in openbao-tools'"
    check "[$sh] accepts signing in openbao mode with cosign listed, alone or with others, on a tag build with environment prod" "sign_ok openbao cosign true true tag prod && sign_ok openbao 'nexus cosign dockerhub' true true tag prod"
    check "[$sh] refuses signing in openbao mode on a build that is not a tag, naming it" \
      "! sign_ok openbao cosign true true branch prod && sign_err openbao cosign true true branch prod | grep -qF \"signs tag builds only, and this is a 'branch' build\""
    # The Cosign read is right before the signature, after the push: with nexus
    # not in openbao-tools it is the job's first read that checks environment,
    # so an environment other than prod must stop the job here, before the build.
    check "[$sh] refuses signing in openbao mode on a tag build with environment dev (the default), naming the rule" \
      "! sign_ok openbao cosign true true tag dev && sign_err openbao cosign true true tag dev | grep -qF \"::error::sign-image on a release build in openbao mode needs the image build's environment to be prod (got 'dev')\""
    check "[$sh]   ...also with environment empty, capitalised or unset" \
      "! sign_ok openbao cosign true true tag '' && ! sign_ok openbao cosign true true tag Prod && ! in_sh $sh -e '$tmp/check.sh' SECRETS_SOURCE=openbao OPENBAO_TOOLS=cosign SIGN_IMAGE=true RELEASE=true REF_TYPE=tag >/dev/null 2>&1"
    check "[$sh]   ...and shows the environment it got on one line, a newline as \\n" "sign_err openbao cosign true true tag \$'prod\\n' | grep -qF \"(got 'prod\\n')\""
    check "[$sh] signing without release, or a release without signing, needs no cosign and no environment prod" "sign_ok openbao nexus true false branch dev && sign_ok openbao nexus false true tag dev && sign_ok openbao '' false true tag ''"
    check "[$sh] github mode signs as before, without cosign, on any build and any environment" "sign_ok github '' true true tag dev && sign_ok github '' true true branch dev"
    check "[$sh] a badly separated list is refused for its separator first" "sign_err openbao \$'nexus\\ncosign' true true tag prod | grep -q 'separated by single spaces' && ! sign_err openbao \$'nexus\\ncosign' true true tag prod | grep -q 'needs cosign'"
  done

  # The Cosign read: right before the signing step, cosign alone, no ocs/ci/shared
  # fallback; the key blanked right after, whatever happened. And the Check step
  # gets what it needs to refuse signing without cosign.
  docker_steps() {  # docker_steps <python body>: the docker job's steps as `steps`
    python3 -c "import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))['jobs']['docker']['steps']
names = [s.get('name') for s in steps]
$1" "$DOCKER"
  }
  check "docker-build.yml: the Cosign read is immediately before 'Sign image (Cosign)', the blanking step immediately after" "docker_steps \"
r, g, c = (names.index(n) for n in ('Read Cosign secrets from OpenBao', 'Sign image (Cosign)', 'Clear the Cosign key from the job environment'))
assert (r + 1, g + 1) == (g, c), (r, g, c)
\""
  check "docker-build.yml: the Cosign read passes tools: cosign alone, no shared, under the signing gate" "docker_steps \"
read = steps[names.index('Read Cosign secrets from OpenBao')]
w = read['with']
assert 'openbao-secrets@' in read['uses'], read['uses']
assert w['tools'] == 'cosign' and 'shared' not in w and 'repo' not in w, w
assert read['if'] == \\\"inputs.secrets-source == 'openbao' && inputs.sign-image && inputs.release\\\", read['if']
others = [s for s in steps if 'openbao-secrets' in s.get('uses', '') and s is not read]
assert others and not any('cosign' in str(s.get('with', {})).lower() for s in others), others
\""
  check "docker-build.yml: no ocs/ci/shared fallback for the signing key remains" "! grep -q 'COSIGN_PRIVATE_KEY COSIGN_PASSWORD' '$DOCKER' && ! grep -q \"' cosign ')\" '$DOCKER'"
  check "docker-build.yml: the blanking step runs if: always() under the signing gate, under sh" "docker_steps \"
clear = steps[names.index('Clear the Cosign key from the job environment')]
assert clear['if'] == \\\"\\\${{ always() && inputs.secrets-source == 'openbao' && inputs.sign-image && inputs.release }}\\\", clear['if']
assert clear.get('shell') == 'sh', clear.get('shell')
\""
  docker_steps "print(steps[names.index('Clear the Cosign key from the job environment')]['run'], end='')" >"$tmp/clear.sh"
  printf 'COSIGN_PRIVATE_KEY<<EOF_X\nnot-a-key\nEOF_X\n' >"$tmp/github_env"
  check "docker-build.yml: the blanking step appends empty COSIGN_PRIVATE_KEY and COSIGN_PASSWORD to GITHUB_ENV" \
    "env -i PATH=\"\$PATH\" GITHUB_ENV='$tmp/github_env' sh -e '$tmp/clear.sh' >/dev/null && [ \"\$(tail -n 2 '$tmp/github_env')\" = \"\$(printf 'COSIGN_PRIVATE_KEY=\\nCOSIGN_PASSWORD=')\" ]"
  check_env() {  # check_env <workflow> <job> <SIGN_IMAGE> <RELEASE> <ENVIRONMENT>: the Check step's env
    python3 -c "import sys, yaml
f, job, sign, release, environment = sys.argv[1:]
step = [s for s in yaml.safe_load(open(f))['jobs'][job]['steps'] if s.get('name') == 'Check secrets-source and openbao-tools'][0]
e = step['env']
got = (e.get('SIGN_IMAGE'), e.get('RELEASE'), e.get('REF_TYPE'), e.get('ENVIRONMENT'))
assert got == (sign, release, '\${{ github.ref_type }}', environment), got" "$@"
  }
  check "Check step env: docker-build.yml passes sign-image, release, the ref type and environment" \
    "check_env '$DOCKER' docker '\${{ inputs.sign-image }}' '\${{ inputs.release }}' '\${{ inputs.environment }}'"
  check "Check step env: node-workflow.yml passes its image build's sign-image, docker-release and docker-environment" \
    "check_env '$NODE' node-ci '\${{ inputs.build-image && inputs.sign-image }}' '\${{ inputs.docker-release }}' '\${{ inputs.docker-environment }}'"
  check "Check step env: node-workflow.yml's docker-environment is the environment its image build gets" \
    "python3 -c \"import sys, yaml; w = yaml.safe_load(open(sys.argv[1]))['jobs']['docker']['with']; assert w['environment'] == '\\\${{ inputs.docker-environment }}', w['environment']\" '$NODE'"
  check "Check step env: python-ci.yml signs nothing, so passes none of the signing variables" \
    "python3 -c \"import sys, yaml
step = [s for s in yaml.safe_load(open(sys.argv[1]))['jobs']['test']['steps'] if s.get('name') == 'Check secrets-source and openbao-tools'][0]
assert set(step['env']) == {'SECRETS_SOURCE', 'OPENBAO_TOOLS'}, sorted(step['env'])\" '$PY'"
  check "Check step env: sbom.yml signs nothing, so passes none of the signing variables" \
    "python3 -c \"import sys, yaml
step = [s for s in yaml.safe_load(open(sys.argv[1]))['jobs']['sbom']['steps'] if s.get('name') == 'Check secrets-source and openbao-tools'][0]
assert set(step['env']) == {'SECRETS_SOURCE', 'OPENBAO_TOOLS'}, sorted(step['env'])\" '$SBOM'"

  # python-ci's SonarQube preflight names the OpenBao path of an empty value.
  run_of "$PY" sonarqube "Check SonarQube URL and token" >"$tmp/sonar.sh"
  sonar() { env -i PATH="$PATH" SONAR_HOST_URL="$1" SONAR_TOKEN="$2" SONAR_HOST_URL_AT="$3" SONAR_TOKEN_AT="$4" bash "$tmp/sonar.sh" 2>&1 || true; }
  check "python-ci preflight: empty URL in the ocs layout names ocs/ci/shared/SONAR_HOST_URL" \
    "sonar '' tok 'ocs/ci/shared/SONAR_HOST_URL (key value)' 'ocs/ci/shared/SONAR_TOKEN (key value)' | grep -q 'OpenBao has no value at ocs/ci/shared/SONAR_HOST_URL (key value).*openbao-tools'"
  check "python-ci preflight: empty token in the devsecops layout names the field" \
    "sonar https://sonar.example '' 'devsecops/ci/dev/sonarqube (field url)' 'devsecops/ci/dev/sonarqube (field token)' | grep -q 'SONAR_TOKEN is empty: OpenBao has no value at devsecops/ci/dev/sonarqube (field token)'"
  check "python-ci preflight: github mode keeps its message" \
    "sonar '' tok '' '' | grep -qx '::error::SONAR_HOST_URL is empty. Add it as a repository or organization secret; for an org secret, check that this repo is in its access list. With secrets-source: openbao it comes from OpenBao (docs/openbao-secrets.md).'"

  # The action's "Stop if OpenBao could not be read", as GitHub runs a bash
  # step, with its ${{ }} expressions filled in.
  python3 - "$ACT" >"$tmp/stop.sh" <<'EOF'
import re, sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["runs"]["steps"]
run = [s for s in steps if s.get("name") == "Stop if OpenBao could not be read"][0]["run"]
print(re.sub(r"\$\{\{.*?\}\}", "EXPR", run), end="")
EOF
  stop_run() { env -i PATH="$PATH" SHARED="$1" REPO="$2" REPO_NAME=repo-x bash --noprofile --norc -eo pipefail "$tmp/stop.sh"; }
  stop_out() { stop_run "$@" 2>&1 || true; }
  stop_cmds() {  # the bao commands only
    stop_out 'NEXUS_HOST SONAR_HOST_URL' 'EXTRA' | grep 'bao kv metadata get'
  }
  check "ocs Stop step: stops the job" "! stop_run NEXUS_HOST '' >/dev/null 2>&1"
  check "ocs Stop step: one bao command per path, with that path (shared and repo)" \
    "[ \"\$(stop_cmds)\" = \"\$(printf '  bao kv metadata get -mount=ocs %s\\n' ci/shared/NEXUS_HOST ci/shared/SONAR_HOST_URL ci/repo-x/EXTRA)\" ]"
  check "ocs Stop step: no bao command for a read with no names" "! stop_out '' '' | grep -q 'bao kv'"
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
check "node-workflow.yml passes sign-image to docker-build, and signs nothing itself" "grep -q 'sign-image: \${{ inputs.sign-image }}' '$NODE' && ! grep -q 'cosign-sign' '$NODE'"
check "node-workflow.yml and python-ci.yml read no Cosign value from OpenBao" "! grep -q \"' cosign '\" '$NODE' '$PY' && ! grep -q 'COSIGN_' '$PY'"
check "docker-build.yml: runs-on is an input, default self-hosted" "grep -A4 '^      runs-on:' '$DOCKER' | grep -q 'default: self-hosted' && ! grep -q '^    runs-on: self-hosted' '$DOCKER'"
check "node-workflow.yml: no job hardcodes self-hosted" "! grep -q '^    runs-on: self-hosted' '$NODE'"
check "node-workflow.yml: container job joins the openbao network only in openbao mode" "grep -q -- '--network ocs_openbao' '$NODE' && grep -B2 -- '--network ocs_openbao' '$NODE' | grep -q 'secrets-source'"

# sbom.yml: its `context` input picks the Nexus repositories, and every read
# passes the same input as the action's environment, which the action checks
# against the build kind (behaviour: tests/openbao_secrets_tools_test.sh). So a
# tag build reads prod and any other build dev, or the job stops at the read.
check "sbom.yml: every read passes context as environment for the build-kind check" \
  "[ \"\$(grep -c '^          tools: ' '$SBOM')\" -gt 0 ] && [ \"\$(grep -c '^          tools: ' '$SBOM')\" = \"\$(grep -c '^          environment: \${{ inputs.context }}\$' '$SBOM')\" ]"
check "sbom.yml: runs-on is an input, default self-hosted" "grep -A4 '^      runs-on:' '$SBOM' | grep -q 'default: self-hosted' && ! grep -q '^    runs-on: self-hosted' '$SBOM'"
check "sbom.yml: its container job joins the openbao network only in openbao mode" "[ \"\$(grep -c -- \"secrets-source == 'openbao' && '--network ocs_openbao' || ''\" '$SBOM')\" = 1 ]"
check "sbom.yml reads no Cosign value from OpenBao" "! grep -q \"' cosign '\" '$SBOM' && ! grep -q 'COSIGN_' '$SBOM'"
if python3 -c 'import yaml' 2>/dev/null; then
  # Each read right before the step that uses its values, in openbao mode only,
  # with context as environment; the Nexus context from that same input.
  sbom_reads() { python3 - "$SBOM" <<'EOF'
import sys, yaml
jobs = yaml.safe_load(open(sys.argv[1]))["jobs"]
for job, read, use, tool in (
    ("sbom", "Read Nexus secrets from OpenBao", "Set up Nexus context", "nexus"),
    ("publish", "Read Dependency-Track secrets from OpenBao", "Upload package SBOM to Dependency-Track", "dependency-track"),
):
    steps = jobs[job]["steps"]
    names = [s.get("name") for s in steps]
    r, u = names.index(read), names.index(use)
    assert r + 1 == u, (job, read, r, use, u)
    step = steps[r]
    assert "/actions/openbao-secrets@" in step["uses"], step["uses"]
    assert step["if"] == "inputs.secrets-source == 'openbao'", (job, step["if"])
    w = step["with"]
    assert w["environment"] == "${{ inputs.context }}", (job, w)
    assert f"' {tool} ')" in w["tools"] and f"' {tool} ')" in w["shared"], (job, w)
nexus = [s for s in jobs["sbom"]["steps"] if s.get("name") == "Set up Nexus context"][0]["with"]
assert nexus["context"] == "${{ inputs.context }}", nexus["context"]
# publish runs on the runner itself (an internal Dependency-Track is out of a
# job container's reach), so it has no container to put on the overlay.
assert "container" not in jobs["publish"], jobs["publish"].get("container")
assert jobs["publish"].get("needs") == "sbom", jobs["publish"].get("needs")
EOF
  }
  check "sbom.yml: each read sits right before the step that uses it, in openbao mode only, with context as environment" sbom_reads
else
  echo "SKIP - python3 with PyYAML not found (sbom.yml reads)"
fi

# --- protections that a later edit could undo without any other test noticing:
# the https:// check on openbao-url, no ${{ }} in a script, and the masking of
# the normalised registry. The steps are read from the files and run, not copied.
if python3 -c 'import yaml' 2>/dev/null; then
  # step_run <workflow or action> <step name>: that step's run: body.
  step_run() { python3 - "$1" "$2" <<'EOF'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
if "runs" in d:
    steps = d["runs"].get("steps") or []
else:
    steps = [s for j in d["jobs"].values() for s in j.get("steps") or []]
print("".join(s["run"] for s in steps if s.get("name") == sys.argv[2] and "run" in s), end="")
EOF
  }
  # The action's first step, under sh as GitHub runs it (dash here, ash in an
  # Alpine job container). Both layouts send the token, so it has no if:.
  first_step() { python3 -c 'import sys, yaml; s = yaml.safe_load(open(sys.argv[1]))["runs"]["steps"][0]; print(s.get("name"), s.get("shell"), "if" in s)' "$ACT"; }
  step_run "$ACT" 'Check openbao-url' >"$tmp/url.sh"
  url_run() { env -i PATH="$PATH" OPENBAO_URL="$1" sh "$tmp/url.sh"; }
  url_refused() {  # every sample is refused; prints the first one that is not
    local u
    for u in 'http://bao.example.internal:8200' '' 'https://' 'HTTPS://bao.example.internal' \
             'bao.example.internal:8200' 'https://bao.example.internal x' \
             "$(printf 'https://bao.example.internal\n::warning::x')" "$(printf 'https://bao.example.internal\tx')"; do
      if url_run "$u" >/dev/null 2>&1; then printf '  accepted: %q\n' "$u"; return 1; fi
    done
  }
  check "action: 'Check openbao-url' is the first step, under sh, with no if:" "[ \"\$(first_step)\" = 'Check openbao-url sh False' ]"
  check "action: an https:// openbao-url passes" "url_run https://bao.example.internal:8200"
  check "action: http://, no scheme, an empty host, whitespace or a newline is refused" url_refused
  check "action: the refusal is an ::error:: that asks for https://" \
    "{ url_run http://bao.example.internal:8200 2>&1; true; } | grep -q '^::error::openbao-url must be an https:// URL'"

  # A ${{ }} inside a script is pasted into it before the shell starts: an input
  # or a secret holding a quote or $(...) would run as code. Every value goes
  # through env:. The one exception is by design: node-workflow's four command
  # steps run the caller's own command, their whole run: is ${{ inputs.<x>-command }}.
  exprs_in_runs() { python3 - "$ROOT" <<'EOF'
import glob, os, re, sys, yaml
root = sys.argv[1]
caller = re.compile(r"\$\{\{ inputs\.[a-z]+-command \}\}")
files = glob.glob(root + "/.github/workflows/*.y*ml") + glob.glob(root + "/.github/actions/*/action.y*ml")
for f in sorted(files):
    d = yaml.safe_load(open(f))
    if "runs" in d:
        steps = d["runs"].get("steps") or []
    else:
        steps = [s for j in (d.get("jobs") or {}).values() for s in j.get("steps") or []]
    rel = os.path.relpath(f, root)
    for s in steps:
        run = s.get("run")
        if run is None or "${{" not in str(run):
            continue
        if rel == ".github/workflows/node-workflow.yml" and caller.fullmatch(str(run).strip()):
            print("caller", rel, s.get("name"))
        else:
            print("script", rel, s.get("name"))
EOF
  }
  check "no run: body holds a \${{ }} expression, except node-workflow's four caller commands" \
    "exprs_in_runs >'$tmp/exprs' && ! grep '^script' '$tmp/exprs' && [ \"\$(grep -c '^caller' '$tmp/exprs')\" = 4 ]"

  # docker-build.yml's registry step, as GitHub runs it (bash): GitHub masks the
  # secret as stored, so the normalised value and its host are masked here.
  step_run "$DOCKER" 'Resolve Nexus registry for context' >"$tmp/reg.sh"
  reg_run() { : >"$tmp/genv"; env -i PATH="$PATH" GITHUB_ENV="$tmp/genv" ENVIRONMENT=dev RAW_DEV="$1" RAW_PROD= bash --noprofile --norc "$tmp/reg.sh" 2>&1; }
  check "docker-build.yml: the normalised registry and its host are masked, and exported" \
    "reg_run ' https://nexus.example.internal:5000/' >'$tmp/reg.out' && grep -qx '::add-mask::nexus.example.internal:5000' '$tmp/reg.out' && grep -qx '::add-mask::nexus.example.internal' '$tmp/reg.out' && grep -qx 'NEXUS_DOCKER_REGISTRY=nexus.example.internal:5000' '$tmp/genv'"
else
  echo "SKIP - python3 with PyYAML not found (openbao-url, run: bodies, masking)"
fi

# --- one ref for everything this branch adds. A workflow that calls another catalog
# workflow or the action at a different ref (e.g. @develop while the new inputs only
# exist on the branch) is rejected by GitHub: "Invalid input, X is not defined".
refs="$(grep -hoE 'workflow-catalog/\.github/(workflows/docker-build\.yml|actions/openbao-secrets)@[^ ]+' "$NODE" "$DOCKER" "$PY" "$SBOM" | sed -E 's/.*@//' | sort -u)"
check "docker-build.yml and the openbao-secrets action are called at one and the same ref" "[ \"\$(wc -l <<<\"\$refs\")\" = 1 ]"

# --- actionlint
if docker image inspect rhysd/actionlint:1.7.7 >/dev/null 2>&1 || docker pull -q rhysd/actionlint:1.7.7 >/dev/null 2>&1; then
  check "actionlint is clean on the touched files" "docker run --rm -v '$ROOT:/r' -w /r rhysd/actionlint:1.7.7 -color=false .github/workflows/node-workflow.yml .github/workflows/docker-build.yml .github/workflows/python-ci.yml .github/workflows/sbom.yml >/tmp/actionlint.out 2>&1 || (cat /tmp/actionlint.out; false)"
else
  echo "SKIP - actionlint image unavailable"
fi
exit $fail
