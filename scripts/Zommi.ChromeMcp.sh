#!/bin/sh
set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
electron_executable=$(wslpath -w "$script_directory/Zommi.exe")
mcp_entrypoint=$(wslpath -w "$script_directory/resources/browser-mcp/node_modules/chrome-devtools-mcp/build/src/bin/chrome-devtools-mcp.js")

export ELECTRON_RUN_AS_NODE=1
exec /init "$electron_executable" "$mcp_entrypoint" \
  --isolated \
  --no-usage-statistics \
  --no-performance-crux \
  --screenshot-format=jpeg \
  --screenshot-quality=75 \
  --screenshot-max-width=1600 \
  --screenshot-max-height=1200
