#!/usr/bin/env bash
set -euo pipefail

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
package_directory=${1:-"$repository_root/artifacts/focalet-linux-x64"}
application="$package_directory/focalet"
core_host="$package_directory/focalet-core-host"
if [[ ! -x "$application" || ! -x "$core_host" ]]; then
  echo "Linux startup smoke requires executable Flutter and Rust hosts in $package_directory." >&2
  exit 2
fi
if [[ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
  echo 'Linux startup smoke requires a live DISPLAY or WAYLAND_DISPLAY.' >&2
  exit 2
fi

temporary_directory=$(mktemp -d -p "${RUNNER_TEMP:-/tmp}" focalet-linux-smoke.XXXXXX)
runtime_log="$temporary_directory/focalet.log"
application_pid=
core_pid=

is_running() {
  local process_status process_state
  if ! { IFS= read -r process_status < "/proc/$1/stat"; } 2>/dev/null; then
    return 1
  fi
  process_state=${process_status##*) }
  process_state=${process_state%% *}
  [[ "$process_state" != Z && "$process_state" != X && "$process_state" != x ]]
}

cleanup() {
  if [[ -n "$application_pid" ]] && is_running "$application_pid"; then
    kill -TERM "$application_pid" 2>/dev/null || true
    sleep 1
    kill -KILL "$application_pid" 2>/dev/null || true
  fi
  if [[ -n "$core_pid" ]] && is_running "$core_pid"; then
    kill -TERM "$core_pid" 2>/dev/null || true
    sleep 1
    kill -KILL "$core_pid" 2>/dev/null || true
  fi
  rm -r "$temporary_directory"
}
trap cleanup EXIT

XDG_STATE_HOME="$temporary_directory/state" "$application" >"$runtime_log" 2>&1 &
application_pid=$!
core_executable=$(readlink -f "$core_host")
startup_deadline=$((SECONDS + 20))
while [[ $SECONDS -lt $startup_deadline && -z "$core_pid" ]]; do
  if ! is_running "$application_pid"; then
    sed -n '1,200p' "$runtime_log" >&2
    echo 'Flutter exited before starting the adjacent Rust core.' >&2
    exit 1
  fi
  children_file="/proc/$application_pid/task/$application_pid/children"
  if [[ -r "$children_file" ]]; then
    for child_candidate in $(<"$children_file"); do
      child_executable=$(readlink -f "/proc/$child_candidate/exe" 2>/dev/null || true)
      if [[ "$child_executable" == "$core_executable" ]]; then
        core_pid=$child_candidate
        break
      fi
    done
  fi
  sleep 0.25
done

if [[ -z "$core_pid" ]]; then
  sed -n '1,200p' "$runtime_log" >&2
  echo 'Flutter did not start the adjacent Rust core within 20 seconds.' >&2
  exit 1
fi

sleep 5
if ! is_running "$application_pid" || ! is_running "$core_pid"; then
  sed -n '1,200p' "$runtime_log" >&2
  echo 'Flutter or the adjacent Rust core exited during the startup observation.' >&2
  exit 1
fi
if grep -Eiq 'Unhandled Exception|MissingPluginException|ERROR:flutter/runtime' "$runtime_log"; then
  sed -n '1,200p' "$runtime_log" >&2
  echo 'Flutter reported an unhandled startup exception.' >&2
  exit 1
fi

if [[ "${FOCALET_VERIFY_SQLITE_CACHE:-0}" == 1 ]]; then
  python3 - "$temporary_directory/state/focalet/session-catalog.sqlite" <<'PY'
import pathlib, sqlite3, sys
path = pathlib.Path(sys.argv[1])
assert path.is_file(), "Packaged Flutter did not initialize its SQLite cache"
with sqlite3.connect(path.as_uri() + "?mode=ro", uri=True) as db:
    assert db.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
    version = db.execute("PRAGMA user_version").fetchone()[0]
    assert version == 3, f"Expected session catalog schema 3, got {version}"
    db.execute("SELECT runtime_target_id, id, pinned, custom_title FROM sessions LIMIT 1").fetchall()
    db.execute("SELECT runtime_target_id, id FROM dismissed_sessions LIMIT 1").fetchall()
PY
fi

kill -TERM "$application_pid"
for _ in {1..40}; do
  if ! is_running "$application_pid"; then
    break
  fi
  sleep 0.25
done
if is_running "$application_pid"; then
  echo 'Flutter did not stop within 10 seconds.' >&2
  exit 1
fi
wait "$application_pid" 2>/dev/null || true
application_pid=

for _ in {1..40}; do
  if ! is_running "$core_pid"; then
    break
  fi
  sleep 0.25
done
if is_running "$core_pid"; then
  ps -o pid=,ppid=,stat=,comm= -p "$core_pid" >&2 || true
  printf 'Core wait channel: ' >&2
  cat "/proc/$core_pid/wchan" >&2 || true
  printf '\n' >&2
  echo 'The adjacent Rust core remained after Flutter stopped.' >&2
  exit 1
fi

hotkey_warnings=$(grep -Eic "Binding '.*' failed" "$runtime_log" || true)
printf '{"flutterStarted":true,"rustCoreStarted":true,"cleanShutdown":true,"hotkeyWarnings":%s}\n' "$hotkey_warnings"
core_pid=
