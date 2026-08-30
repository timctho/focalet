#!/usr/bin/env bash
set -euo pipefail

target_platform=${1:-}
if [[ "$target_platform" != linux && "$target_platform" != macos ]]; then
  echo 'usage: scripts/package-unix.sh <linux|macos>' >&2
  exit 2
fi

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
flutter_directory="$repository_root/src/Zommi.Flutter"
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
