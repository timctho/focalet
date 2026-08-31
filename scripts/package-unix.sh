#!/usr/bin/env bash
set -euo pipefail

target_platform=${1:-}
if [[ "$target_platform" != linux && "$target_platform" != macos ]]; then
  echo 'usage: scripts/package-unix.sh <linux|macos>' >&2
  exit 2
fi

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
flutter_directory="$repository_root/src/Zommi.Flutter"

resolve_linux_runtime_library() {
  local soname=$1
  local search_path
  local candidate
  IFS=: read -r -a search_paths <<< "${ZOMMI_LINUX_RUNTIME_LIBRARY_DIRS:-}"
  for search_path in "${search_paths[@]}"; do
    [[ -n "$search_path" ]] || continue
    candidate="$search_path/$soname"
    if [[ -f "$candidate" || -L "$candidate" ]]; then
      readlink -f "$candidate"
      return 0
    fi
  done
  if command -v ldconfig >/dev/null 2>&1; then
    candidate=$(ldconfig -p | awk -v name="$soname" '$1 == name {print $NF; exit}')
    if [[ -n "$candidate" && -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi
  echo "Required Linux runtime library is unavailable: $soname" >&2
  return 1
}

bundle_linux_runtime_libraries() {
  local output_directory=$1
  local soname
  local source_path
  local required_libraries=(
    libayatana-appindicator3.so.1
    libayatana-indicator3.so.7
    libdbusmenu-glib.so.4
    libdbusmenu-gtk3.so.4
  )
  mkdir -p "$output_directory"
  for soname in "${required_libraries[@]}"; do
    source_path=$(resolve_linux_runtime_library "$soname")
    cp -L "$source_path" "$output_directory/$soname"
  done
}
machine_architecture=$(uname -m)
case "$machine_architecture" in
  x86_64) release_architecture=x64 ;;
  arm64|aarch64) release_architecture=arm64 ;;
  *) echo "unsupported release architecture: $machine_architecture" >&2; exit 2 ;;
esac
git_commit=$(git -C "$repository_root" rev-parse HEAD)

(
  cd "$flutter_directory"
  flutter pub get
  flutter build "$target_platform" --release --no-pub
)
cargo build \
  --manifest-path "$repository_root/Cargo.toml" \
  --release \
  --bin zommi-core-host

if [[ "$target_platform" == linux ]]; then
  flutter_output="$flutter_directory/build/linux/$release_architecture/release/bundle"
  bundle_linux_runtime_libraries "$flutter_output/lib"
else
  flutter_output="$flutter_directory/build/macos/Build/Products/Release/Zommi.app"
fi
core_host="${CARGO_TARGET_DIR:-$repository_root/target}/release/zommi-core-host"
assembler_arguments=(
  "$repository_root/scripts/assemble_release.py"
  --platform "$target_platform"
  --architecture "$release_architecture"
  --flutter-output "$flutter_output"
  --core-host "$core_host"
  --output-root "$repository_root/artifacts"
  --git-commit "$git_commit"
  --document "$repository_root/README.md"
  --document "$repository_root/docs/flutter-rust-migration.md"
)
if [[ "$target_platform" == macos && -n "${ZOMMI_MACOS_SIGNING_IDENTITY:-}" ]]; then
  assembler_arguments+=(--macos-signing-identity "$ZOMMI_MACOS_SIGNING_IDENTITY")
elif [[ "$target_platform" == linux ]]; then
  assembler_arguments+=(--signing-status checksum-only --signing-mechanism sha256)
fi
python3 "${assembler_arguments[@]}"

package_directory="$repository_root/artifacts/zommi-$target_platform-$release_architecture"
python3 "$repository_root/scripts/verify_release.py" \
  "$package_directory" \
  --expected-platform "$target_platform" \
  --expected-commit "$git_commit"
