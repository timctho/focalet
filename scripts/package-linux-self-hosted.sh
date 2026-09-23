#!/usr/bin/env bash
set -euo pipefail
repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if ! command -v clang++ >/dev/null || ! command -v ninja >/dev/null ||
   ! pkg-config --exists gtk+-3.0 webkit2gtk-4.1 x11 ayatana-appindicator3-0.1; then
  echo 'Install the Ubuntu 24.04 build dependencies listed in docs/ubuntu-testing.md.' >&2
  exit 2
fi
bash "$repository_root/scripts/package-unix.sh" linux
if [[ "${ZOMMI_LINUX_STARTUP_SMOKE:-0}" == 1 ]]; then
  bash "$repository_root/scripts/smoke-linux-release.sh"
fi
