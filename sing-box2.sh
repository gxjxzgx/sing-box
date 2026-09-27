#!/bin/bash
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
