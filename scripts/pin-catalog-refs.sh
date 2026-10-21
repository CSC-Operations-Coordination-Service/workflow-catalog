#!/usr/bin/env bash
# Pin every reference the catalog makes to itself to one ref.
#
#   scripts/pin-catalog-refs.sh <ref>           rewrite them to @<ref>
#   scripts/pin-catalog-refs.sh --check <ref>   list those not at @<ref> (file:line),
#                                               exit 1 if there is one
#
# Why: the catalog's workflows call its own actions and workflows by
# owner/repo/path@ref (a local ./ path would resolve in the caller's checkout).
# A caller that pins the catalog at a tag or a commit SHA freezes only the
# workflow it calls; every self-reference left at @develop still runs whatever
# develop holds today, including the steps that receive the caller's secrets.
# So a release pins them all to its own tag, and a branch pins them to develop
# before it is merged there (docs/releasing.md; checked by self-refs.yml).
#
# A self-reference is
#   CSC-Operations-Coordination-Service/workflow-catalog/.github/(actions|workflows)/<name>@<ref>
# in any *.yml or *.yaml file under .github/. Owner and repository match in any
# case, as GitHub resolves them. Nothing else is touched: other repositories'
# actions, comments that do not hold that form, files outside .github/.
#
# Exit status: 0 done (or nothing to report), 1 --check found a reference at
# another ref, 2 usage error or refused ref. Needs bash and POSIX tools (find,
# awk, sed, grep, cut, sort, mktemp); no network.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
  echo "usage: $0 [--check] <ref>   (ref: a branch, a tag or a commit SHA, e.g. develop or 1.2.0)"
}

mode=rewrite
if [ "${1:-}" = "--check" ]; then
  mode=check
  shift
fi
if [ $# -ne 1 ]; then
  usage >&2
  exit 2
fi
ref=$1

# The ref lands in `uses: ...@<ref>` lines as is, and the matcher below reads a
# ref as letters, digits, '.', '_', '-' and '/' only: any other character (a
# quote, a comma, a bracket) would end the match early, and a rewrite would then
# leave the rest of the old ref behind. Within that set, what git refuses in a
# ref name is refused too, so no branch, tag or SHA could carry it, and a
# leading '-' is a mistyped option. The letters are spelled out: in some
# locales a range such as a-z takes in other characters.
refuse() {
  printf "%s: refused ref '%s': %s\n" "$0" "$(printf '%s' "$ref" | tr '\n\r\t' '   ')" "$1" >&2
  exit 2
}
case $ref in
  '') refuse "empty" ;;
  -*) refuse "starts with '-'" ;;
  *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._/-]*)
    refuse "only letters, digits, '.', '_', '-' and '/' are accepted" ;;
  .* | /* | */ | *. | *..* | *//* | */.* | *.lock | *.lock/*) refuse "not a valid git ref name" ;;
esac

# One awk program, two modes, over one file (PIN_FILE, relative to ROOT):
#   list:    each self-reference as "<+|->\t<file>:<line>: <reference>",
#            + when it is at PIN_REF already, - when it is not;
#   rewrite: the file with every self-reference at @PIN_REF.
# Values come in through ENVIRON, not -v, which would expand backslashes.
# tolower() keeps the length, so a match on the lowered line gives the
# positions in the original one.
# shellcheck disable=SC2016 # awk program, not shell
AWK='
BEGIN {
  q = sprintf("%c", 39)
  stop = "@ \t\r\"" q
  # The ref: the characters the argument check accepts, ending on one that is
  # not . or / (git refuses a ref ending so). So a comma, a closing bracket or
  # a full stop after a reference stays, and a glob such as
  # docker-build.yml@* (the job_workflow_ref binding in OpenBao, quoted in a
  # comment) is not a reference at all.
  pat = "csc-operations-coordination-service/workflow-catalog/\\.github/(actions|workflows)/[^" stop "]+@[a-z0-9._/-]*[a-z0-9_-]"
  ref = ENVIRON["PIN_REF"]; file = ENVIRON["PIN_FILE"]; mode = ENVIRON["PIN_MODE"]
}
{
  rest = $0; out = ""
  while (match(tolower(rest), pat)) {
    m = substr(rest, RSTART, RLENGTH)
    at = index(m, "@")
    if (mode == "list") printf "%s\t%s:%d: %s\n", (substr(m, at + 1) == ref ? "+" : "-"), file, NR, m
    out = out substr(rest, 1, RSTART - 1) substr(m, 1, at) ref
    rest = substr(rest, RSTART + RLENGTH)
  }
  if (mode == "rewrite") print out rest
}'

listing="$(mktemp)"
trap 'rm -f "$listing" "$listing.new"' EXIT

files="$(cd "$ROOT" && find .github -type f \( -name '*.yml' -o -name '*.yaml' \) | sed 's|^\./||' | LC_ALL=C sort)"
total=0
off=0
changed=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  PIN_MODE=list PIN_REF="$ref" PIN_FILE="$f" awk "$AWK" "$ROOT/$f" >"$listing"
  n=$(grep -c '' "$listing" || true)
  d=$(grep -c '^-' "$listing" || true)
  total=$((total + n))
  off=$((off + d))
  [ "$d" -gt 0 ] || continue
  if [ "$mode" = check ]; then
    grep '^-' "$listing" | cut -f2-
  else
    PIN_MODE=rewrite PIN_REF="$ref" PIN_FILE="$f" awk "$AWK" "$ROOT/$f" >"$listing.new"
    # cat, not mv: keeps the file's mode and links.
    cat "$listing.new" >"$ROOT/$f"
    changed=$((changed + 1))
    echo "$f: $d reference(s) now at @$ref"
  fi
done <<EOF
$files
EOF

if [ "$mode" = check ]; then
  if [ "$off" -gt 0 ]; then
    echo "$off of $total self-reference(s) are not at @$ref. Fix: scripts/pin-catalog-refs.sh $ref (docs/releasing.md)." >&2
    exit 1
  fi
  echo "All $total self-reference(s) are at @$ref."
else
  echo "$off of $total self-reference(s) rewritten to @$ref, in $changed file(s)."
fi
