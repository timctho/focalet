#!/usr/bin/env python3
"""Keep Linux release builds within the declared Ubuntu runtime baseline."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess

UBUNTU_VERSION = "24.04"
GLIBC_MINIMUM = "2.39"
LIBSTDCXX_MINIMUM = "13.2"
# Match the Debian dependency floors, not whatever a build host has installed.
# GCC's symbol version table: https://gcc.gnu.org/onlinedocs/libstdc++/manual/abi.html
SYMBOL_LIMITS = {
    "GLIBC": GLIBC_MINIMUM,
    "GLIBCXX": "3.4.32",  # GCC 13.2
    "CXXABI": "1.3.14",  # GCC 13.2
}
SPECIAL_VERSIONS = {"GLIBC_ABI_DT_RELR", "CXXABI_TM_1", "CXXABI_FLOAT128"}


class UbuntuCompatibilityError(RuntimeError):
    pass


def verify_build_host() -> None:
    try:
        release = platform.freedesktop_os_release()
    except OSError as error:
        raise UbuntuCompatibilityError("Cannot identify the Ubuntu build environment.") from error
    if release.get("ID") != "ubuntu" or release.get("VERSION_ID") != UBUNTU_VERSION:
        raise UbuntuCompatibilityError(
            f"Linux releases must be built on Ubuntu {UBUNTU_VERSION}; found "
            f"{release.get('ID', 'unknown')} {release.get('VERSION_ID', 'unknown')}. "
            "Use an Ubuntu 24.04 VM/container instead of raising the package baseline."
        )


def required_symbol_versions(output: str) -> set[str]:
    """Read imports only: version definitions describe what a library provides."""
    versions = set()
    needs = False
    for line in output.splitlines():
        if line.startswith("Version "):
            needs = line.startswith("Version needs section ")
        if needs:
            match = re.search(r"\bName:\s+(\S+)", line)
            if match:
                versions.add(match[1])
    return versions


def _version_numbers(value: str) -> tuple[int, ...]:
    return tuple(map(int, value.split(".")))


def verify_ubuntu_abi(root: Path) -> dict:
    readelf = shutil.which("readelf")
    if not readelf:
        raise UbuntuCompatibilityError("ELF compatibility checks require readelf; install binutils.")
    root = root.resolve()
    count = 0
    maxima: dict[str, str] = {}
    special = set()
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            if not path.resolve().is_relative_to(root):
                raise UbuntuCompatibilityError(f"Package symlink escapes its root: {path.name}")
            continue  # The target is scanned once under its own name.
        if not path.is_file():
            continue
        with path.open("rb") as stream:
            if stream.read(4) != b"\x7fELF":
                continue
        relative = path.relative_to(root).as_posix()
        try:
            result = subprocess.run(
                [readelf, "--version-info", "--wide", str(path)],
                capture_output=True, text=True, check=False, timeout=20,
                env={**os.environ, "LC_ALL": "C"},
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise UbuntuCompatibilityError(f"Cannot inspect ELF file {relative}: {error}") from error
        if result.returncode or result.stderr.strip():
            raise UbuntuCompatibilityError(f"Cannot inspect ELF file {relative}: {result.stderr.strip()}")
        count += 1
        for version in sorted(required_symbol_versions(result.stdout)):
            family, _, number = version.partition("_")
            if family not in SYMBOL_LIMITS:
                continue
            if version in SPECIAL_VERSIONS:
                special.add(version)
                continue
            limit = SYMBOL_LIMITS[family]
            if not re.fullmatch(r"\d+(?:\.\d+)*", number):
                raise UbuntuCompatibilityError(f"{relative} requires unsupported runtime ABI {version}.")
            if _version_numbers(number) > _version_numbers(limit):
                raise UbuntuCompatibilityError(
                    f"{relative} requires {version}; Ubuntu {UBUNTU_VERSION} package "
                    f"baseline allows at most {family}_{limit}. Rebuild this component "
                    "with the supported toolchain or review the dependency baseline."
                )
            if family not in maxima or _version_numbers(number) > _version_numbers(maxima[family]):
                maxima[family] = number
    if not count:
        raise UbuntuCompatibilityError("The Linux package contains no ELF binaries to validate.")
    return {"ubuntu": UBUNTU_VERSION, "elfFiles": count,
            "maxRequired": maxima, "specialRequired": sorted(special)}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("build-host")
    subparsers.add_parser("package").add_argument("root", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "build-host":
            verify_build_host()
            print(f"Ubuntu {UBUNTU_VERSION} build environment verified.")
        else:
            print(json.dumps(verify_ubuntu_abi(args.root), sort_keys=True))
    except UbuntuCompatibilityError as error:
        parser.exit(1, f"Ubuntu compatibility check failed: {error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
