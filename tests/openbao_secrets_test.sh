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
    "python3 '$tmp/guarded_model.py' as-is '$NODE' '$DOCKER' '$PY' >'$tmp/model.out' || (cat '$tmp/model.out'; false)"
  # The model has to tell '' from false: without its trailing || '' the form
  # yields false in openbao mode when env.X is empty, and GitHub passes 'false'.
  check "  ...and the model fails the form without its trailing || '' (it renders false as 'false')" \
    "! python3 '$tmp/guarded_model.py' no-trailing-default '$NODE' '$DOCKER' '$PY' >'$tmp/model.out' && grep -q \"^src='openbao' env='' sec='from-github': got 'false', want ''\$\" '$tmp/model.out'"
else
  echo "SKIP - python3 not found (guarded-form evaluation)"
fi

# The Check step: one text in all three workflows, run under every sh it can
# meet, before every OpenBao read.
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
  STEP="Check secrets-source and openbao-tools"
  run_of "$DOCKER" docker "$STEP" >"$tmp/check.sh"
  check "$STEP: node-workflow.yml has the same text as docker-build.yml" "run_of '$NODE' node-ci '$STEP' | cmp -s - '$tmp/check.sh'"
  check "$STEP: python-ci.yml has the same text as docker-build.yml" "run_of '$PY' test '$STEP' | cmp -s - '$tmp/check.sh'"
  # It guards every read only if it runs in every mode and first: in the job
  # that reads, or in a job that reading job needs (a failed need skips the job
  # unless its if: says always() or !cancelled()).
  check "$STEP: runs under sh with no if:, before every OpenBao read" "python3 - '$NODE' '$DOCKER' '$PY' '$STEP' <<'EOF'
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
refs="$(grep -hoE 'workflow-catalog/\.github/(workflows/docker-build\.yml|actions/openbao-secrets)@[^ ]+' "$NODE" "$DOCKER" "$PY" | sed -E 's/.*@//' | sort -u)"
check "docker-build.yml and the openbao-secrets action are called at one and the same ref" "[ \"\$(wc -l <<<\"\$refs\")\" = 1 ]"

# --- actionlint
if docker image inspect rhysd/actionlint:1.7.7 >/dev/null 2>&1 || docker pull -q rhysd/actionlint:1.7.7 >/dev/null 2>&1; then
  check "actionlint is clean on the touched files" "docker run --rm -v '$ROOT:/r' -w /r rhysd/actionlint:1.7.7 -color=false .github/workflows/node-workflow.yml .github/workflows/docker-build.yml .github/workflows/python-ci.yml >/tmp/actionlint.out 2>&1 || (cat /tmp/actionlint.out; false)"
else
  echo "SKIP - actionlint image unavailable"
fi
exit $fail
