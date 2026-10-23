#!/usr/bin/env bash
# A minimal envsubst, for runners that do not have one (the containerized pool's image is
# the bare actions-runner base, without gettext-base). Reads stdin, writes stdout, replaces
# $NAME and ${NAME} with the value of that environment variable (empty when unset). A value
# is not expanded again, and a `$` that does not start a name is kept as it is.
#
# Why it exists: sigstore/cosign-installer runs `envsubst` on its install-dir input, even
# when there is nothing to expand, and stops with "envsubst: command not found" (exit 127).
# That is the only thing it is used for here, so this covers the plain `$HOME/.cosign` case,
# not the whole of GNU envsubst (no SHELL-FORMAT argument, no `$$`).
set -u

while IFS= read -r line || [ -n "$line" ]; do
  out=""
  while [ -n "$line" ]; do
    if [[ $line =~ ^([^\$]*)\$\{([A-Za-z_][A-Za-z0-9_]*)\}(.*)$ ]] \
      || [[ $line =~ ^([^\$]*)\$([A-Za-z_][A-Za-z0-9_]*)(.*)$ ]]; then
      name="${BASH_REMATCH[2]}"
      out+="${BASH_REMATCH[1]}${!name-}"
      line="${BASH_REMATCH[3]}"
    elif [[ $line =~ ^([^\$]*\$)(.*)$ ]]; then
      # a `$` that starts no name: keep it, then go on with the rest of the line
      out+="${BASH_REMATCH[1]}"
      line="${BASH_REMATCH[2]}"
    else
      out+="$line"
      line=""
    fi
  done
  printf '%s\n' "$out"
done
