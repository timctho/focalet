# This script runs inside the selected WSL distribution. The path is a positional
# argument so spaces and shell metacharacters remain literal filename characters.
case "$1" in
  '~/'*) zommi_executable="$HOME/${1#\~/}" ;;
  /*) zommi_executable="$1" ;;
  *) printf 'Use an absolute Linux path or ~/path for the WSL CLI.\n' >&2; exit 64 ;;
esac
if [ ! -f "$zommi_executable" ]; then
  printf 'CLI file not found in WSL: %s\nUse ~/... for a path under your WSL home.\n' "$zommi_executable" >&2
  exit 2
fi
if [ ! -x "$zommi_executable" ]; then
  printf 'CLI file is not executable in WSL: %s\n' "$zommi_executable" >&2
  exit 126
fi
printf '%s' "$zommi_executable"
