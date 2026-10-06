"""Static tooling and authored Erlang validation for the package gate."""

from importlib.metadata import version
import os
from pathlib import Path
import subprocess
import tempfile


def run(command: list[str], directory: Path, **arguments: object) -> int:
    print("Running " + " ".join(command), flush=True)
    return subprocess.run(command, cwd=directory, **arguments).returncode


def static(root: Path) -> int:
    actual = version("jsonschema")
    if actual != "4.26.0":
        print(f"jsonschema 4.26.0 is required; found {actual}", flush=True)
        return 1
    workflows = sorted(
        str(path.relative_to(root))
        for path in (root / ".github/workflows").iterdir()
        if path.suffix in (".yml", ".yaml")
    )
    shells = []
    for directory in ("scripts", "test/fixtures/stdio"):
        for path in (root / directory).rglob("*"):
            if not path.is_file() or {"build", "node_modules"}.intersection(path.parts):
                continue
            if path.suffix == ".sh" or (
                not path.suffix
                and path.read_bytes().startswith(
                    (b"#!/bin/sh", b"#!/usr/bin/env bash", b"#!/usr/bin/env sh")
                )
            ):
                shells.append(str(path.relative_to(root)))
    shells.sort()
    commands = [
        ["nix", "flake", "check", "--no-update-lock-file"],
        ["ruff", "check", "scripts", "test/fixtures/stdio"],
        ["actionlint", *workflows],
        ["shellcheck", *shells],
        ["shfmt", "-d", "-i", "2", *shells],
    ]
    for command in commands:
        status = run(command, root)
        if status:
            return status
    return 0


def native_sources(package: Path) -> list[Path]:
    return sorted(
        path
        for directory in ("src", "test", "dev")
        for path in (package / directory).rglob("*.erl")
    )


def native(package: Path) -> int:
    sources = native_sources(package)
    if not sources:
        print(f"No authored Erlang in {package}", flush=True)
        return 0
    libraries = package / "build/dev/erlang"
    include_arguments = [
        argument
        for include in sorted(libraries.glob("*/include"))
        for argument in ("-I", str(include))
    ]
    environment = dict(os.environ, ERL_LIBS=str(libraries))
    with tempfile.TemporaryDirectory(prefix="relay-native-check-") as output:
        return run(
            ["erlc", "-Werror", *include_arguments, "-o", output, *map(str, sources)],
            package,
            env=environment,
        )


def build(package: Path) -> int:
    status = run(["gleam", "build", "--warnings-as-errors"], package)
    return status if status else native(package)
