#!/usr/bin/env bash
# The envsubst shim of the cosign-sign action: same output as GNU envsubst on what the
# cosign-installer feeds it, a working `command -v` once on PATH, and the action runs the
# shim step before the installer. Run from anywhere: bash tests/cosign_sign_envsubst_test.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ACTION="$ROOT/.github/actions/cosign-sign/action.yml"
SHIM="$ROOT/.github/actions/cosign-sign/envsubst-shim.sh"
fail=0
check() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fail=1; fi; }

export HOME=/home/runner SOME_VAR=value EMPTY_VAR=""
unset UNSET_VAR
cases=(
  '$HOME/.cosign'
  '${HOME}/.cosign'
  '$HOME/${SOME_VAR}/x'
  '/opt/cosign'
  'a-$UNSET_VAR-b'
  '$EMPTY_VAR|$SOME_VAR'
  'cost is 5$ and $SOME_VAR'
  '$1 stays, ${SOME_VAR} goes'
  ''
)
if command -v envsubst >/dev/null 2>&1; then
  for c in "${cases[@]}"; do
    check "same as GNU envsubst for: $c" "[ \"\$(printf '%s\n' \"\$c\" | bash '$SHIM')\" = \"\$(printf '%s\n' \"\$c\" | envsubst)\" ]"
  done
else
  echo "SKIP - no GNU envsubst to compare with"
fi

check "a value is not expanded again" \
  "[ \"\$(SOME_VAR='\$HOME' bash '$SHIM' <<<'\${SOME_VAR}')\" = '\$HOME' ]"
check "the last line is kept without a newline at the end" \
  "[ \"\$(printf '\$SOME_VAR' | bash '$SHIM')\" = 'value' ]"

# As the action installs it: a copy named envsubst, on a PATH that has no other one.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
install -m 0755 "$SHIM" "$tmp/envsubst"
# The shebang is `env bash`, so the system directories stay on PATH; the shim's directory
# goes first, as the action puts it with GITHUB_PATH, and must be the one that is found.
check "the installed shim is the envsubst found first, and expands install-dir" \
  "[ \"\$(PATH='$tmp:/usr/bin:/bin' bash -c 'command -v envsubst')\" = '$tmp/envsubst' ] && [ \"\$(PATH='$tmp:/usr/bin:/bin' bash -c 'envsubst <<<\"\$HOME/.cosign\"')\" = '/home/runner/.cosign' ]"
check "with no envsubst on PATH the check the action makes says so" \
  "! PATH='$tmp/none' '$BASH' -c 'command -v envsubst' >/dev/null 2>&1"

check "the shim step comes before the installer" \
  "[ \$(grep -n 'Provide envsubst when the runner lacks it' '$ACTION' | cut -d: -f1) -lt \$(grep -n 'sigstore/cosign-installer@' '$ACTION' | cut -d: -f1) ]"
check "the shim is only used when envsubst is missing" \
  "grep -q 'command -v envsubst' '$ACTION'"
check "the shim reaches later steps through GITHUB_PATH" \
  "grep -q 'GITHUB_PATH' '$ACTION'"

# actionlint only reads workflow files, so the action is checked as YAML: the steps in order.
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
  check "the action parses and lists the steps: shim, installer, signing" \
    "python3 -c \"import yaml,sys; s=yaml.safe_load(open('$ACTION'))['runs']['steps']; n=[x.get('name','') for x in s]; sys.exit(0 if n[:3]==['Provide envsubst when the runner lacks it','Install Cosign','Sign image references by digest'] else 1)\""
else
  echo "SKIP - no python3 with yaml"
fi
exit $fail
