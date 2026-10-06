#!/usr/bin/env bash
set -euo pipefail
package=${1:?usage: scripts/install-gnome-extension.sh <linux-package>}
source_directory="$package/gnome-extension/focalet@focalet"
test -f "$source_directory/metadata.json"
destination="${XDG_DATA_HOME:-$HOME/.local/share}/gnome-shell/extensions/focalet@focalet"
mkdir -p "$destination"
cp -R "$source_directory/." "$destination/"
if ! gnome-extensions enable focalet@focalet; then
  echo 'Extension installed. Sign out and sign in to load it, then enable desktop integration in Focalet App settings.'
fi
