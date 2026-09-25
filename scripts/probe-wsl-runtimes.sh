#!/bin/sh
# Called with CLI names as positional arguments, both by discovery and by the
# relay bootstrap when Node is managed by a shell tool such as nvm or fnm.
zommi_shell=$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f7)
[ -x "$zommi_shell" ] || zommi_shell=${SHELL:-/bin/sh}
zommi_flags=-lic
case "${zommi_shell##*/}" in
  sh|dash) zommi_flags=-lc ;;
esac
case "${zommi_shell##*/}" in
  fish)
    zommi_probe='printf "__ZOMMI_RUNTIME_HOME__%s\n" "$HOME"; printf "__ZOMMI_RUNTIME_ENV_PATH__%s\n" (string join : $PATH); for zommi_command in $argv; set zommi_path (command -s $zommi_command); if test -f "$zommi_path"; and test -x "$zommi_path"; printf "__ZOMMI_RUNTIME_PATH__%s\t%s\n" $zommi_command "$zommi_path"; end; end; printf "__ZOMMI_RUNTIME_READY__\n"'
    ;;
  *)
    zommi_probe='printf "__ZOMMI_RUNTIME_HOME__%s\n" "$HOME"; printf "__ZOMMI_RUNTIME_ENV_PATH__%s\n" "$PATH"; for zommi_command in "$@"; do zommi_path=$(command -v -- "$zommi_command" 2>/dev/null || true); case "$zommi_path" in /*) if [ -f "$zommi_path" ] && [ -x "$zommi_path" ]; then printf "__ZOMMI_RUNTIME_PATH__%s\t%s\n" "$zommi_command" "$zommi_path"; fi ;; esac; done; printf "__ZOMMI_RUNTIME_READY__\n"'
    # POSIX shells consume the first argument after -c as $0; fish does not.
    set -- zommi-runtime-probe "$@"
    ;;
esac

zommi_output=$(mktemp) || exit 1
trap 'rm -f "$zommi_output"' EXIT
# Shell startup messages are not protocol output. Bound shell initialization
# separately from cold WSL boot, and kill its children if startup hangs.
if command -v timeout >/dev/null 2>&1; then
  timeout -k 1 5 "$zommi_shell" "$zommi_flags" "$zommi_probe" "$@" </dev/null >"$zommi_output" 2>/dev/null || exit 1
else
  "$zommi_shell" "$zommi_flags" "$zommi_probe" "$@" </dev/null >"$zommi_output" 2>/dev/null || exit 1
fi
[ "$(wc -c <"$zommi_output")" -le 262144 ] || exit 1
grep -qx '__ZOMMI_RUNTIME_READY__' "$zommi_output" || exit 1
grep '^__ZOMMI_RUNTIME_' "$zommi_output"
