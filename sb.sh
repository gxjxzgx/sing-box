#!/bin/bash
# Temporary loader: serves last complete tree file (v2.5.14) from git.
# Replace this file via GitHub web UI with artifacts/sb.sh (v2.5.18, ~200KB) when ready.
set -e
RAW="https://raw.githubusercontent.com/gxjxzgx/sing-box/60b449eca069c48d86ab5ed0726fb7a786fdacf3/sing-box2.sh"
if command -v curl >/dev/null 2>&1; then
  exec bash <(curl -fsSL "$RAW") "$@"
elif command -v wget >/dev/null 2>&1; then
  exec bash <(wget -qO- "$RAW") "$@"
else
  echo "需要 curl 或 wget" >&2
  exit 1
fi
