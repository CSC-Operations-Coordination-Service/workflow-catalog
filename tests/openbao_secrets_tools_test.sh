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

# The script exactly as the action runs it.
python3 - "$ACT" "$tmp/script.js" <<'EOF'
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["runs"]["steps"]
script = [s for s in steps if "github-script" in s.get("uses", "")][0]["with"]["script"]
open(sys.argv[2], "w").write(script)
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

node "$ROOT/tests/openbao_secrets_tools_test.js" "$tmp/script.js" "$tmp/action" "$tmp/key.pem" "$tmp/cert.pem"
