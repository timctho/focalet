#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
browser_executable="${ZOMMI_TEST_CHROMIUM:-}"
if [[ -z "$browser_executable" ]]; then
  for candidate in chromium chromium-browser google-chrome; do
    if command -v "$candidate" >/dev/null 2>&1; then
      browser_executable="$(command -v "$candidate")"
      break
    fi
  done
fi
if [[ -z "$browser_executable" && -d "$HOME/.cache/ms-playwright" ]]; then
  browser_executable="$(rg --files "$HOME/.cache/ms-playwright" -g chrome | sort | tail -n 1)"
fi
if [[ -z "$browser_executable" || ! -x "$browser_executable" ]]; then
  echo 'Install Chromium or set ZOMMI_TEST_CHROMIUM to its executable to run the browser interaction gate.' >&2
  exit 1
fi
dotnet build src/Zommi.BrowserCapture/Zommi.BrowserCapture.csproj --configuration Release
export ZOMMI_TEST_PORTABLE_BROWSER_HOST="$PWD/src/Zommi.BrowserCapture/bin/Release/net8.0/zommi-browser-capture.dll"
dotnet run --project tests/Zommi.Browser.Tests --configuration Release -- "$browser_executable" artifacts/browser-capture-acceptance
