#!/bin/sh
# Stop only relays identified by their exact script and endpoint arguments.
set -eu
relay_pid=$1
endpoint=$2
case "$relay_pid" in ''|*[!0-9]*) exit 2 ;; esac
case "$endpoint" in /*/endpoints/*.json) ;; *) exit 2 ;; esac
relay_root=${endpoint%/endpoints/*}
endpoint_name=${endpoint##*/}
# Current brokers isolate bootstrap scripts by distribution. Keep the legacy
# root script eligible too, including an older relay sharing this endpoint.
legacy_script="$relay_root/zommi-wsl-relay.js"
bootstrap_script="$relay_root/bootstrap/${endpoint_name%.json}/zommi-wsl-relay.js"
matches_relay() {
  [ -r "/proc/$1/cmdline" ] || return 1
  case "$(readlink "/proc/$1/exe" 2>/dev/null)" in
    */node|*/nodejs|*/node\ \(deleted\)|*/nodejs\ \(deleted\)) ;;
    *) return 1 ;;
  esac
  # Require Node's script argument, not a path mentioned by unrelated code.
  script_argument=$(tr '\000' '\n' < "/proc/$1/cmdline" | sed -n '2p')
  case "$script_argument" in
    "$legacy_script"|"$bootstrap_script") ;;
    *) return 1 ;;
  esac
  tr '\000' '\n' < "/proc/$1/cmdline" | (
    previous=
    while IFS= read -r argument; do
      if [ "$previous" = '--endpoint' ] && [ "$argument" = "$endpoint" ]; then exit 0; fi
      previous=$argument
    done
    exit 1
  )
}
if [ -d "/proc/$relay_pid" ] && ! matches_relay "$relay_pid"; then exit 3; fi
# Older simultaneous startups can leave more than one relay writing this file.
# Scan the exact identity, not a process name or a cached PID alone.
for file in $(grep -zlFx -e "$legacy_script" -e "$bootstrap_script" /proc/[0-9]*/cmdline 2>/dev/null | tr '\000' '\n'); do
  target_pid=${file#/proc/}
  target_pid=${target_pid%/cmdline}
  matches_relay "$target_pid" || continue
  for child in $(cat "/proc/$target_pid/task/$target_pid/children" 2>/dev/null); do
    parent=$(awk '$1 == "PPid:" { print $2 }' "/proc/$child/status" 2>/dev/null || true)
    if [ "$parent" = "$target_pid" ]; then
      /bin/kill -TERM -- "-$child" 2>/dev/null || true
    fi
  done
  kill -TERM "$target_pid" 2>/dev/null || true
  attempt=0
  while matches_relay "$target_pid" && [ "$attempt" -lt 30 ]; do
    sleep 0.1
    attempt=$((attempt + 1))
  done
  if matches_relay "$target_pid"; then kill -KILL "$target_pid"; fi
done
