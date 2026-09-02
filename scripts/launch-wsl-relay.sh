#!/bin/sh
set -eu

relay_script=$1
endpoint_file=$2
relay_token=$3
relay_version=$4
distribution=$5

node_path=
for candidate in "$(command -v node 2>/dev/null || true)" "$HOME"/.nvm/versions/node/*/bin/node /usr/local/bin/node /usr/bin/node "$HOME"/.local/bin/node; do
  [ -n "$candidate" ] && [ -x "$candidate" ] || continue
  if "$candidate" -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 18 ? 0 : 1)' 2>/dev/null; then
    node_path=$candidate
    break
  fi
done
[ -n "$node_path" ] || exit 43

if command -v setsid >/dev/null 2>&1; then
  nohup setsid -f "$node_path" "$relay_script" \
    --endpoint "$endpoint_file" \
    --token "$relay_token" \
    --version "$relay_version" \
    --distribution "$distribution" \
    </dev/null >/dev/null 2>&1 &
else
  nohup "$node_path" "$relay_script" \
    --endpoint "$endpoint_file" \
    --token "$relay_token" \
    --version "$relay_version" \
    --distribution "$distribution" \
    </dev/null >/dev/null 2>&1 &
fi

