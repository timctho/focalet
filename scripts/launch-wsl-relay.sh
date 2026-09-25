#!/bin/sh
set -eu

relay_script=$1
endpoint_file=$2
relay_token=$3
relay_version=$4
distribution=$5

node_path=
for candidate in "$(command -v node 2>/dev/null || true)" "$HOME"/.hermes/node/bin/node "$HOME"/.nvm/versions/node/*/bin/node /usr/local/bin/node /usr/bin/node "$HOME"/.local/bin/node; do
  [ -n "$candidate" ] && [ -x "$candidate" ] || continue
  if "$candidate" -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 18 ? 0 : 1)' 2>/dev/null; then
    node_path=$candidate
    break
  fi
done
# Other shell-managed installations (including fnm) need their initialization
# files. Use the same bounded probe as runtime discovery, only when necessary.
if [ -z "$node_path" ]; then
  candidate=$(/bin/sh "$(dirname "$0")/probe-wsl-runtimes.sh" node 2>/dev/null | sed -n 's/^__ZOMMI_RUNTIME_PATH__node\t//p')
  if [ -n "$candidate" ] && [ -x "$candidate" ] && "$candidate" -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 18 ? 0 : 1)' 2>/dev/null; then
    node_path=$candidate
  fi
fi
[ -n "$node_path" ] || exit 43

launch_log="${endpoint_file}.launch.log"
: >"$launch_log"

# Runtime requests supply their own cwd. The persistent daemon must not pin
# the extracted Windows package directory and prevent its next replacement.
cd /

if command -v setsid >/dev/null 2>&1; then
  nohup setsid "$node_path" "$relay_script" \
    --endpoint "$endpoint_file" \
    --token "$relay_token" \
    --version "$relay_version" \
    --distribution "$distribution" \
    </dev/null >"$launch_log" 2>&1 &
else
  nohup "$node_path" "$relay_script" \
    --endpoint "$endpoint_file" \
    --token "$relay_token" \
    --version "$relay_version" \
    --distribution "$distribution" \
    </dev/null >"$launch_log" 2>&1 &
fi

relay_pid=$!
attempt=0
while [ "$attempt" -lt 60 ]; do
  [ -s "$endpoint_file" ] && exit 0
  if ! kill -0 "$relay_pid" 2>/dev/null; then
    sed -n '1,20p' "$launch_log" >&2 || :
    exit 44
  fi
  attempt=$((attempt + 1))
  sleep 0.1
done
sed -n '1,20p' "$launch_log" >&2 || :
exit 45
