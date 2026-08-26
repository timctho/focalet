#!/bin/sh
set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ "$#" -ne 1 ]; then
  echo "Usage: Zommi.ChromeMcp.sh <cdp-port>" >&2
  exit 64
fi

cdp_port=$1
case "$cdp_port" in
  ''|*[!0-9]*)
    echo "Invalid Chrome CDP port: $cdp_port" >&2
    exit 64
    ;;
esac

mcp_entrypoint="$script_directory/resources/browser-mcp/node_modules/chrome-devtools-mcp/build/src/bin/chrome-devtools-mcp.js"
exec node "$mcp_entrypoint" \
  --browser-url="http://127.0.0.1:$cdp_port" \
  --no-usage-statistics \
  --no-performance-crux \
  --screenshot-format=jpeg \
  --screenshot-quality=75 \
  --screenshot-max-width=1600 \
  --screenshot-max-height=1200
