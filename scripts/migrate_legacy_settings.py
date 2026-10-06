"""Preview or import pre-rename UI preferences and runtime commands into Focalet."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sys


def settings_paths(platform: str, env: dict[str, str]) -> list[tuple[Path, Path]]:
    home = Path(env.get("HOME") or env.get("USERPROFILE") or str(Path.home()))
    if platform == "win32":
        config = Path(env.get("APPDATA") or env.get("LOCALAPPDATA") or home)
        state = Path(env.get("LOCALAPPDATA") or home)
        old, new = "Zommi", "Focalet"
    elif platform == "darwin":
        config = state = home / "Library/Application Support"
        old, new = "Zommi", "Focalet"
    else:
        config = Path(env.get("XDG_CONFIG_HOME") or home / ".config")
        state = config
        old, new = "zommi", "focalet"
    return [(base / old / name, base / new / name) for base, name in
            [(config, "settings.json"), (state, "runtime-overrides.json")]]


def migrate(paths: list[tuple[Path, Path]], apply: bool = False) -> list[str]:
    outcomes = []
    for source, target in paths:
        if target.exists():
            outcomes.append(f"Kept existing {target.name}")
            continue
        if not source.is_file():
            continue
        data = source.read_bytes()
        # Validate before creating a destination, without exposing setting values.
        expected = list if source.name == "runtime-overrides.json" else dict
        if not isinstance(json.loads(data), expected):
            raise ValueError(f"Invalid settings in {source.name}")
        if apply:
            target.parent.mkdir(parents=True, exist_ok=True)
            with target.open("xb") as output:
                output.write(data)
        outcomes.append(f"{'Imported' if apply else 'Would import'} {source.name}")
    return outcomes


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="Copy missing preferences after both apps are closed.")
    args = parser.parse_args()
    for outcome in migrate(settings_paths(sys.platform, dict(os.environ)), args.apply):
        print(outcome)


if __name__ == "__main__":
    main()
