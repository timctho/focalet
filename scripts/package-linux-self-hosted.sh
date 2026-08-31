#!/usr/bin/env bash
set -euo pipefail

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

if command -v clang >/dev/null 2>&1 &&
  command -v clang++ >/dev/null 2>&1 &&
  command -v ninja >/dev/null 2>&1 &&
  pkg-config --exists gtk+-3.0 x11 ayatana-appindicator3-0.1; then
  exec bash "$repository_root/scripts/package-unix.sh" linux
fi

os_id=$(awk -F= '$1 == "ID" {gsub(/"/, "", $2); print $2}' /etc/os-release)
os_version=$(awk -F= '$1 == "VERSION_ID" {gsub(/"/, "", $2); print $2}' /etc/os-release)
if [[ "$os_id" != ubuntu || "$os_version" != 20.04 ]]; then
  echo "Native Linux build dependencies are missing, and the user-space fallback supports Ubuntu 20.04 only." >&2
  exit 2
fi

temporary_parent=${RUNNER_TEMP:-/tmp}
dependency_root=$(mktemp -d -p "$temporary_parent" zommi-linux-build.XXXXXX)
trap 'rm -r "$dependency_root"' EXIT
download_directory="$dependency_root/packages"
sysroot="$dependency_root/root"
tool_directory="$dependency_root/tools"
python_directory="$dependency_root/python"
mkdir -p "$download_directory" "$sysroot" "$tool_directory" "$python_directory"

mapfile -t development_packages < <(
  apt-cache depends --recurse \
    --no-recommends \
    --no-suggests \
    --no-conflicts \
    --no-breaks \
    --no-replaces \
    --no-enhances \
    libgtk-3-dev \
    libx11-dev \
    libayatana-appindicator3-dev 2>/dev/null |
    awk '/^[[:alnum:]][[:alnum:].+:-]*$/ {print}' |
    sort -u |
    grep -E -- '(-dev$|^wayland-protocols$)' |
    while read -r package_name; do
      if apt-cache show "$package_name" >/dev/null 2>&1; then
        printf '%s\n' "$package_name"
      fi
    done
)
if [[ ${#development_packages[@]} -eq 0 ]]; then
  echo 'Could not resolve the Ubuntu native development package set.' >&2
  exit 2
fi

runtime_packages=(
  clang-10
  libclang-common-10-dev
  libclang-cpp10
  libclang1-10
  libllvm10
  libobjc-9-dev
  libobjc4
  libgcc-9-dev
  libstdc++-9-dev
  libgtk-3-0
  libx11-6
  libayatana-appindicator3-1
  libayatana-indicator3-7
  libdbusmenu-glib4
  libdbusmenu-gtk3-4
  libdbus-glib-1-2
  libpango-1.0-0
  libpangocairo-1.0-0
  libharfbuzz0b
  libatk1.0-0
  libcairo-gobject2
  libcairo2
  libgdk-pixbuf2.0-0
  libglib2.0-0
  shared-mime-info
)

(
  cd "$download_directory"
  apt download "${development_packages[@]}" "${runtime_packages[@]}"
  for package_archive in ./*.deb; do
    dpkg-deb -x "$package_archive" "$sysroot"
  done
)

python3 -m pip install \
  --disable-pip-version-check \
  --no-compile \
  --target "$python_directory" \
  ninja==1.13.0
ninja_directory=$(PYTHONPATH="$python_directory" python3 -c 'import ninja; print(ninja.BIN_DIR)')

ln -s "$sysroot/usr/bin/clang-10" "$tool_directory/clang"
ln -s "$sysroot/usr/bin/clang++-10" "$tool_directory/clang++"
ln -s "$ninja_directory/ninja" "$tool_directory/ninja"

multiarch=$(dpkg-architecture -qDEB_HOST_MULTIARCH)
pkgconfig_paths=(
  "$sysroot/usr/lib/$multiarch/pkgconfig"
  "$sysroot/usr/lib/pkgconfig"
  "$sysroot/usr/share/pkgconfig"
)
library_paths=(
  "$sysroot/usr/lib/llvm-10/lib"
  "$sysroot/usr/lib/$multiarch"
)

export PATH="$tool_directory:$PATH"
export CC=clang
export CXX=clang++
task_pkgconfig_paths=$(IFS=:; printf '%s' "${pkgconfig_paths[*]}")
export PKG_CONFIG_LIBDIR="$task_pkgconfig_paths"
export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"
export PKG_CONFIG_SYSROOT_DIR="$sysroot"
task_library_paths=$(IFS=:; printf '%s' "${library_paths[*]}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}")
export LD_LIBRARY_PATH="$task_library_paths"
export LIBRARY_PATH="$sysroot/usr/lib/$multiarch${LIBRARY_PATH:+:$LIBRARY_PATH}"
export CMAKE_PREFIX_PATH="$sysroot/usr${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
export ZOMMI_LINUX_RUNTIME_LIBRARY_DIRS="$sysroot/usr/lib/$multiarch"

clang++ --version
pkg-config --modversion gtk+-3.0 x11 ayatana-appindicator3-0.1
linux_build_directory="$repository_root/src/Zommi.Flutter/build/linux"
if [[ -d "$linux_build_directory" ]]; then
  rm -r "$linux_build_directory"
fi
bash "$repository_root/scripts/package-unix.sh" linux
if [[ "${ZOMMI_LINUX_STARTUP_SMOKE:-0}" == 1 ]]; then
  bash "$repository_root/scripts/smoke-linux-release.sh"
fi
