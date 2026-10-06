#!/usr/bin/env bash
set -euo pipefail

target_platform=${1:-}
if [[ "$target_platform" != linux && "$target_platform" != macos ]]; then
  echo 'usage: scripts/package-unix.sh <linux|macos>' >&2
  exit 2
fi

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
flutter_directory="$repository_root/src/Focalet.Flutter"

if [[ "$target_platform" == linux ]]; then
  python3 "$repository_root/scripts/ubuntu_compatibility.py" build-host
fi

if [[ "$target_platform" == macos ]]; then
  # Keep this checkout's local builds on the same identity. Ad-hoc signatures
  # use binary hashes, so replacing the app invalidates existing TCC grants.
  macos_signing_identity=${FOCALET_MACOS_SIGNING_IDENTITY:-$(git -C "$repository_root" config --local --get focalet.macosSigningIdentity || true)}
  if [[ -z "$macos_signing_identity" || "$macos_signing_identity" == - ]]; then
    echo 'macOS: using ad-hoc signing; rebuilt apps can lose Screen Recording and Accessibility grants. Set FOCALET_MACOS_SIGNING_IDENTITY or git config --local focalet.macosSigningIdentity to retain a signing identity.' >&2
  fi
fi

resolve_linux_runtime_library() {
  local soname=$1
  local search_path
  local candidate
  IFS=: read -r -a search_paths <<< "${FOCALET_LINUX_RUNTIME_LIBRARY_DIRS:-}"
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
    libsqlite3.so.0
  )
  mkdir -p "$output_directory"
  for soname in "${required_libraries[@]}"; do
    source_path=$(resolve_linux_runtime_library "$soname")
    cp -L "$source_path" "$output_directory/$soname"
  done
  ln -sf libsqlite3.so.0 "$output_directory/libsqlite3.so"
}
machine_architecture=$(uname -m)
case "$machine_architecture" in
  x86_64) release_architecture=x64 ;;
  arm64|aarch64) release_architecture=arm64 ;;
  *) echo "unsupported release architecture: $machine_architecture" >&2; exit 2 ;;
esac
git_commit=$(git -C "$repository_root" rev-parse HEAD)
version_arguments=()
if [[ "$target_platform" == macos ]]; then
  # CFBundleShortVersionString needs three numeric components. The release tag
  # keeps the prerelease suffix from pubspec; Flutter still uses its build number.
  native_version=$(python3 "$repository_root/scripts/release_version.py" --field version)
  build_number=$(python3 "$repository_root/scripts/release_version.py" --field buildNumber)
  version_arguments=("--build-name=$native_version" "--build-number=$build_number")
fi

(
  cd "$flutter_directory"
  if [[ "$target_platform" == macos ]]; then
    export XCODE_XCCONFIG_FILE="${XCODE_XCCONFIG_FILE:-$repository_root/scripts/macos-build.xcconfig}"
    # The Rust and .NET helpers are native to this runner, so match their CPU.
    export FLUTTER_XCODE_ARCHS="$machine_architecture"
  fi
  flutter pub get
  flutter build "$target_platform" --release --no-pub "--dart-define=FOCALET_BUILD_REVISION=$git_commit" "${version_arguments[@]}"
)
cargo build \
  --manifest-path "$repository_root/Cargo.toml" \
  --release \
  --bin focalet-core-host
if [[ "$target_platform" == linux ]]; then
  cargo build \
    --manifest-path "$repository_root/Cargo.toml" \
    --release \
    --bin focalet-linux-capture
fi

if [[ "$target_platform" == linux ]]; then
  flutter_output="$flutter_directory/build/linux/$release_architecture/release/bundle"
  bundle_linux_runtime_libraries "$flutter_output/lib"
else
  flutter_output="$flutter_directory/build/macos/Build/Products/Release/Focalet.app"
fi
core_host="${CARGO_TARGET_DIR:-$repository_root/target}/release/focalet-core-host"
browser_runtime="$target_platform-$release_architecture"
if [[ "$target_platform" == macos ]]; then browser_runtime="osx-$release_architecture"; fi
browser_output="$repository_root/artifacts/browser-capture-$browser_runtime"
dotnet publish "$repository_root/src/Focalet.BrowserCapture/Focalet.BrowserCapture.csproj" \
  --configuration Release --runtime "$browser_runtime" --self-contained true \
  -p:PublishSingleFile=true -p:DebugType=None --output "$browser_output"
assembler_arguments=(
  "$repository_root/scripts/assemble_release.py"
  --platform "$target_platform"
  --architecture "$release_architecture"
  --flutter-output "$flutter_output"
  --core-host "$core_host"
  --browser-capture-host "$browser_output"
  --output-root "$repository_root/artifacts"
  --git-commit "$git_commit"
  --document "$repository_root/README.md"
  --document "$repository_root/docs/install.md"
)
if [[ "$target_platform" == macos ]]; then
  assembler_arguments+=(--document "$repository_root/docs/macos-testing.md")
  assembler_arguments+=(--document "$repository_root/scripts/accept-macos.py")
  assembler_arguments+=(--document "$repository_root/scripts/macos-capture-input.swift")
fi
if [[ "$target_platform" == macos && -n "$macos_signing_identity" ]]; then
  assembler_arguments+=(--macos-signing-identity "$macos_signing_identity")
elif [[ "$target_platform" == linux ]]; then
  assembler_arguments+=(--signing-status checksum-only --signing-mechanism sha256)
  assembler_arguments+=(
    --linux-capture-host
    "${CARGO_TARGET_DIR:-$repository_root/target}/release/focalet-linux-capture"
  )
fi
python3 "${assembler_arguments[@]}"

package_directory="$repository_root/artifacts/focalet-$target_platform-$release_architecture"
python3 "$repository_root/scripts/verify_release.py" \
  "$package_directory" \
  --expected-platform "$target_platform" \
  --expected-commit "$git_commit"
