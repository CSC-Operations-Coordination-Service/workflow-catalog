#!/usr/bin/env bash
# Behaviour checks for the devsecops layout (`tools`) of the openbao-secrets
# action: its own script, run by node against a mock OpenBao over TLS.
# Needs node, openssl and python3 with PyYAML. No network, no docker.
# Run from anywhere: bash tests/openbao_secrets_tools_test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ACT="$ROOT/.github/actions/openbao-secrets/action.yml"

for bin in node openssl python3; do
  command -v "$bin" >/dev/null 2>&1 || { echo "SKIP - $bin not found"; exit 0; }
done
python3 -c 'import yaml' 2>/dev/null || { echo "SKIP - PyYAML not found"; exit 0; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# The script exactly as the action runs it, and the action's CA step, which
# hands the script its CA.
python3 - "$ACT" "$tmp/script.js" "$tmp/ca.sh" <<'EOF'
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["runs"]["steps"]
script = [s for s in steps if "github-script" in s.get("uses", "")][0]["with"]["script"]
open(sys.argv[2], "w").write(script)
open(sys.argv[3], "w").write([s for s in steps if s.get("name") == "Read the bundled OpenBao CA"][0]["run"])
EOF

# A throwaway CA and a localhost certificate. The action reads the CA from
# <action dir>/openbao-ca.crt, so the test gives it a directory of its own.
mkdir -p "$tmp/action"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=test-ca' \
  -keyout "$tmp/ca.key" -out "$tmp/action/openbao-ca.crt" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -subj '/CN=localhost' \
  -keyout "$tmp/key.pem" -out "$tmp/req.csr" 2>/dev/null
printf 'subjectAltName=DNS:localhost\n' > "$tmp/san.ext"
openssl x509 -req -in "$tmp/req.csr" -CA "$tmp/action/openbao-ca.crt" -CAkey "$tmp/ca.key" \
  -CAcreateserial -days 1 -extfile "$tmp/san.ext" -out "$tmp/cert.pem" 2>/dev/null

# The CA step as GitHub runs it (sh -e), with GITHUB_ACTION_PATH at that
# directory, and ACTION_PATH, which the old steps filled from the
# github.action_path context, at a directory that does not exist: what a job
# with a container: sees, since the runner does not translate that context into
# the container's paths. The script gets the step's output as the action passes
# it (OPENBAO_CA), and its login over TLS works only with the right CA.
env -i PATH="$PATH" GITHUB_ACTION_PATH="$tmp/action" GITHUB_OUTPUT="$tmp/ca.out" \
  ACTION_PATH="$tmp/runner-side/no-such-dir" sh -e "$tmp/ca.sh" \
  || { echo "FAIL - the action's CA step stopped"; exit 1; }

node "$ROOT/tests/openbao_secrets_tools_test.js" "$tmp/script.js" "$tmp/ca.out" "$tmp/action/openbao-ca.crt" "$tmp/key.pem" "$tmp/cert.pem"
