"""Read release identity from the application's committed pubspec version."""
from __future__ import annotations

import argparse
from pathlib import Path
import re

PUBSPEC = Path(__file__).resolve().parents[1] / "src/Zommi.Flutter/pubspec.yaml"
NUMBER = r"(?:0|[1-9][0-9]*)"
IDENTIFIER = r"(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)"
VERSION = re.compile(
    rf"(?P<base>{NUMBER}\.{NUMBER}\.{NUMBER})"
    rf"(?:-(?P<preview>{IDENTIFIER}(?:\.{IDENTIFIER})*))?"
    rf"(?:\+(?P<build>{NUMBER}))?"
)


def read_version(pubspec: Path = PUBSPEC) -> dict:
    values = re.findall(r"^version:[ \t]*(\S+)[ \t]*$", pubspec.read_text(encoding="utf-8"), re.M)
    match = VERSION.fullmatch(values[0]) if len(values) == 1 else None
    if match is None:
        raise ValueError("pubspec.yaml needs one version: major.minor.patch[-preview.N][+build-number].")
    version = match["base"]
    release = version + ("-" + match["preview"] if match["preview"] else "")
    return {"version": version, "releaseVersion": release, "tag": "v" + release,
            "prerelease": match["preview"] is not None, "buildNumber": match["build"] or "1"}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--field", choices=("version", "releaseVersion", "tag", "prerelease", "buildNumber"), default="tag")
    value = read_version()[parser.parse_args().field]
    print(str(value).lower() if isinstance(value, bool) else value)


if __name__ == "__main__":
    main()
