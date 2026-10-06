#!/bin/sh
# Called with CLI names as positional arguments, both by discovery and by the
# relay bootstrap when Node is managed by a shell tool such as nvm or fnm.
focalet_shell=$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f7)
[ -x "$focalet_shell" ] || focalet_shell=${SHELL:-/bin/sh}
focalet_flags=-lic
case "${focalet_shell##*/}" in
  sh|dash) focalet_flags=-lc ;;
esac
case "${focalet_shell##*/}" in
  fish)
    focalet_probe='printf "__FOCALET_RUNTIME_HOME__%s\n" "$HOME"; printf "__FOCALET_RUNTIME_ENV_PATH__%s\n" (string join : $PATH); for focalet_command in $argv; set focalet_path (command -s $focalet_command); if test -f "$focalet_path"; and test -x "$focalet_path"; printf "__FOCALET_RUNTIME_PATH__%s\t%s\n" $focalet_command "$focalet_path"; end; end; printf "__FOCALET_RUNTIME_READY__\n"'
    ;;
  *)
    focalet_probe='printf "__FOCALET_RUNTIME_HOME__%s\n" "$HOME"; printf "__FOCALET_RUNTIME_ENV_PATH__%s\n" "$PATH"; for focalet_command in "$@"; do focalet_path=$(command -v -- "$focalet_command" 2>/dev/null || true); case "$focalet_path" in /*) if [ -f "$focalet_path" ] && [ -x "$focalet_path" ]; then printf "__FOCALET_RUNTIME_PATH__%s\t%s\n" "$focalet_command" "$focalet_path"; fi ;; esac; done; printf "__FOCALET_RUNTIME_READY__\n"'
    # POSIX shells consume the first argument after -c as $0; fish does not.
    set -- focalet-runtime-probe "$@"
    ;;
esac

focalet_output=$(mktemp) || exit 1
trap 'rm -f "$focalet_output"' EXIT
# Shell startup messages are not protocol output. Bound shell initialization
# separately from cold WSL boot, and kill its children if startup hangs.
set -- "$focalet_shell" "$focalet_flags" "$focalet_probe" "$@"
if command -v timeout >/dev/null 2>&1; then
  set -- timeout -k 1 5 "$@"
fi
# WSL can attach a controlling terminal even with redirected stdin. Detach it
# before timeout creates a process group, or interactive shells stop on SIGTTIN
# while trying to become that terminal's foreground job.
if command -v setsid >/dev/null 2>&1; then
  set -- setsid --wait "$@"
fi
"$@" </dev/null >"$focalet_output" 2>/dev/null || exit 1
[ "$(wc -c <"$focalet_output")" -le 262144 ] || exit 1
grep -qx '__FOCALET_RUNTIME_READY__' "$focalet_output" || exit 1
grep '^__FOCALET_RUNTIME_' "$focalet_output"
