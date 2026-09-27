#!/bin/bash
# sing-box multi-protocol installer launcher (v2.5.18)
# Full script: sing-box2.sh  |  Usage: bash sb.sh   or   bash sb.sh -i
set -e
RAW="https://raw.githubusercontent.com/gxjxzgx/sing-box/main/sing-box2.sh"
if command -v curl >/dev/null 2>&1; then
  exec bash <(curl -fsSL "$RAW") "$@"
elif command -v wget >/dev/null 2>&1; then
  exec bash <(wget -qO- "$RAW") "$@"
else
  echo "需要 curl 或 wget" >&2
  exit 1
fi
