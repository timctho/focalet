# This script runs inside the selected WSL distribution. The path is a positional
# argument so spaces and shell metacharacters remain literal filename characters.
case "$1" in
  '~/'*) focalet_executable="$HOME/${1#\~/}" ;;
  /*) focalet_executable="$1" ;;
  *) printf 'Use an absolute Linux path or ~/path for the WSL CLI.\n' >&2; exit 64 ;;
esac
if [ ! -f "$focalet_executable" ]; then
  printf 'CLI file not found in WSL: %s\nUse ~/... for a path under your WSL home.\n' "$focalet_executable" >&2
  exit 2
fi
if [ ! -x "$focalet_executable" ]; then
  printf 'CLI file is not executable in WSL: %s\n' "$focalet_executable" >&2
  exit 126
fi
printf '%s' "$focalet_executable"
