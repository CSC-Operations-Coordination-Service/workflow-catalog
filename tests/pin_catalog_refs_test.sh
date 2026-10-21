#!/usr/bin/env bash
# Behaviour of scripts/pin-catalog-refs.sh, always on a temporary copy: this
# tree is never rewritten. The copy holds this repository's .github/ plus a few
# fixtures: references to other repositories, a reference in another case, a
# quoted one, two on one line, CRLF line endings, a .md under .github/ and a
# .yml outside it.
# Needs bash, awk, diff, find; no network.
# Run from anywhere: bash tests/pin_catalog_refs_test.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
check() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fail=1; fi; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
C="$tmp/copy"
mkdir -p "$C/scripts" "$C/docs"
cp -R "$ROOT/.github" "$C/.github"
cp "$ROOT/scripts/pin-catalog-refs.sh" "$C/scripts/"
PIN="$C/scripts/pin-catalog-refs.sh"
pin() { bash "$PIN" "$@"; }

SELF="CSC-Operations-Coordination-Service/workflow-catalog/.github"
FIX="$C/.github/workflows/zz-fixture.yaml"
cat >"$FIX" <<EOF
jobs:
  j:
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
      - uses: other-org/workflow-catalog/.github/actions/cosign-sign@develop
      - uses: CSC-Operations-Coordination-Service/other-repo/.github/actions/cosign-sign@develop
      - uses: csc-operations-coordination-service/Workflow-Catalog/.github/actions/cosign-sign@feature/x
      - uses: "$SELF/actions/nexus-context@develop"
      # two on one line: $SELF/actions/a@x and $SELF/workflows/b.yml@y
      # glob $SELF/workflows/docker-build.yml@*, kept; and see ($SELF/actions/x@develop).
      # a sentence ends on $SELF/actions/y@develop.
EOF
printf 'a:\r\n  uses: %s/actions/syft-sbom@develop\r\n' "$SELF" >"$C/.github/workflows/zz-crlf.yml"
printf 'Call it as %s/workflows/docker-build.yml@develop.\n' "$SELF" >"$C/.github/NOTES.md"
printf 'uses: %s/actions/syft-sbom@develop\n' "$SELF" >"$C/docs/outside.yml"
OTHERS="$(sed -n '4,6p' "$FIX")"

# Every self-reference in the yml/yaml files under .github/, one per line, as
# grep sees it (independently of the script's awk).
refs() { find "$C/.github" -type f \( -name '*.yml' -o -name '*.yaml' \) -exec cat {} + | tr -d '\r' \
  | grep -ioE 'csc-operations-coordination-service/workflow-catalog/\.github/(actions|workflows)/[^@ "]+@[A-Za-z0-9._/-]*[A-Za-z0-9_-]'; }
snapshot() { rm -rf "$tmp/snap"; cp -R "$C" "$tmp/snap"; }
unchanged() { diff -r "$tmp/snap" "$C" >/dev/null; }

# --- --check on the copy as it is
total="$(refs | wc -l | tr -d ' ')"
not_dev="$(refs | grep -vc '@develop$')"
check "the copy holds self-references (from this tree and the fixtures)" "[ \"$total\" -gt 10 ]"
snapshot
out="$(pin --check develop 2>"$tmp/err")"; rc=$?
check "--check develop fails while a reference is at another ref" "[ $rc -eq 1 ]"
check "  ...lists exactly those, one file:line each" "[ \"\$(grep -c '' <<<\"\$out\")\" = '$not_dev' ] && ! grep -vqE '^\.github/[^:]+:[0-9]+: ' <<<\"\$out\""
check "  ...names the case variant, at its line" "grep -qx '.github/workflows/zz-fixture.yaml:7: csc-operations-coordination-service/Workflow-Catalog/.github/actions/cosign-sign@feature/x' <<<\"\$out\""
check "  ...says how many and how to fix them" "grep -q \"^$not_dev of $total self-reference(s) are not at @develop. Fix: scripts/pin-catalog-refs.sh develop\" '$tmp/err'"
check "  ...and writes nothing" unchanged

# --- rewrite
out="$(pin 1.2.3)"; rc=$?
check "rewrite to 1.2.3 succeeds and reports the count" "[ $rc -eq 0 ] && grep -q \"^$total of $total self-reference(s) rewritten to @1.2.3\" <<<\"\$out\""
check "  ...every self-reference is at @1.2.3" "[ \"\$(refs | grep -c '@1\.2\.3$')\" = '$total' ]"
check "  ...--check 1.2.3 now passes" "pin --check 1.2.3 | grep -qx 'All $total self-reference(s) are at @1.2.3.'"
check "  ...--check develop now fails" "! pin --check develop >/dev/null 2>&1"
# Nothing but the refs changed: with every ref replaced by @X, both trees match.
norm() { (cd "$1" && find .github -type f | LC_ALL=C sort | while IFS= read -r f; do printf '== %s\n' "$f"; sed -E 's#(workflow-catalog/\.github/(actions|workflows)/[^@ "]+)@[A-Za-z0-9._/-]*[A-Za-z0-9_-]#\1@X#Ig' "$f"; done); }
check "  ...and nothing else changed under .github/" "diff <(norm '$tmp/snap') <(norm '$C') >/dev/null"
check "  ...uses: of other repositories untouched (checkout, other owner, other repo)" "[ \"\$(sed -n '4,6p' '$FIX')\" = \"\$OTHERS\" ]"
check "  ...a quoted reference keeps its quotes" "grep -qF '      - uses: \"$SELF/actions/nexus-context@1.2.3\"' '$FIX'"
check "  ...both references on one line" "grep -qF \"# two on one line: $SELF/actions/a@1.2.3 and $SELF/workflows/b.yml@1.2.3\" '$FIX'"
check "  ...punctuation after a reference is kept, and a glob @* is not a reference" "grep -qF \"# glob $SELF/workflows/docker-build.yml@*, kept; and see ($SELF/actions/x@1.2.3).\" '$FIX'"
check "  ...a full stop right after a reference is kept" "grep -qF \"# a sentence ends on $SELF/actions/y@1.2.3.\" '$FIX'"
check "  ...owner and repository keep their case" "grep -qF 'csc-operations-coordination-service/Workflow-Catalog/.github/actions/cosign-sign@1.2.3' '$FIX'"
check "  ...CRLF line endings kept" "[ \"\$(od -An -c '$C/.github/workflows/zz-crlf.yml' | tr -d ' \\n')\" = \"\$(printf 'a:\\r\\n  uses: %s/actions/syft-sbom@1.2.3\\r\\n' '$SELF' | od -An -c | tr -d ' \\n')\" ]"
check "  ...a .md under .github/ untouched" "cmp -s '$tmp/snap/.github/NOTES.md' '$C/.github/NOTES.md'"
check "  ...a .yml outside .github/ untouched" "cmp -s '$tmp/snap/docs/outside.yml' '$C/docs/outside.yml'"

# --- idempotent
snapshot
out="$(pin 1.2.3)"; rc=$?
check "a second rewrite to the same ref changes nothing" "[ $rc -eq 0 ] && grep -q '^0 of $total self-reference(s) rewritten' <<<\"\$out\" && unchanged"

# --- other refs: a branch with a slash, a commit SHA, back to develop
SHA=0123456789abcdef0123456789abcdef01234567
check "a commit SHA as ref" "pin $SHA >/dev/null && pin --check $SHA >/dev/null && [ \"\$(refs | grep -c '@$SHA$')\" = '$total' ]"
check "a branch name with a slash as ref" "pin ci/some-branch >/dev/null && pin --check ci/some-branch >/dev/null"
check "back to develop: --check develop passes" "pin develop >/dev/null && pin --check develop >/dev/null"

# --- refused refs: exit 2, nothing written
snapshot
refused() {  # refused <args...>: exit 2 and no file changed
  pin "$@" >/dev/null 2>"$tmp/err"; local rc=$?
  [ $rc -eq 2 ] && unchanged
}
check "no argument is refused" "refused"
check "two refs are refused" "refused develop main"
check "--check without a ref is refused" "refused --check"
check "an empty ref is refused, saying so" "refused '' && grep -q \"refused ref '': empty\" '$tmp/err'"
check "a ref with a space, a tab or a newline is refused" "refused 'a b' && refused \$'a\\tb' && refused \$'a\\nb' && refused --check \$'develop\\n'"
check "a ref with '@' is refused" "refused 'develop@x' && refused --check '@develop'"
check "a ref starting with '-' (a mistyped option) is refused" "refused --chek && refused -- develop"
check "refs git refuses are refused (.., ~, ^, :, ?, *, [, backslash, trailing / or .)" \
  "refused 'a..b' && refused 'a~1' && refused 'a^' && refused 'a:b' && refused 'a?' && refused 'a*' && refused 'a[b' && refused 'a\\b' && refused 'a/' && refused 'a.'"
check "refs git refuses within the accepted characters are refused (.lock, leading . or /, //, /.)" \
  "refused 'a.lock' && refused 'a.lock/b' && refused '.a' && refused '/a' && refused 'a//b' && refused 'a/.b'"
check "characters the matcher would stop at are refused, saying so (quotes, comma, bracket)" \
  "refused \"a'b\" && refused 'a\"b' && refused 'a,b' && refused 'a)' && grep -q \"only letters, digits\" '$tmp/err'"

exit $fail
