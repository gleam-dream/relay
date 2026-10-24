#!/usr/bin/env python3
"""Checks that negative compiler fixtures fail to compile with expected diagnostics."""

import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
FIXTURES_DIR = ROOT / "fixtures" / "negative"
PROBE_FILE = ROOT / "test" / "negative_probe.gleam"


def check():
    return subprocess.run(
        ["gleam", "check"],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )


def main():
    fixtures = sorted(FIXTURES_DIR.glob("*.gleam"))
    if not fixtures:
        print("FAIL: No negative fixtures found", file=sys.stderr)
        sys.exit(1)

    if PROBE_FILE.exists():
        sys.exit(f"FAIL: refusing to replace existing probe source: {PROBE_FILE}")
    controls = sorted((ROOT / "fixtures/positive").glob("*.gleam"))
    if not controls:
        sys.exit("FAIL: No positive compiler controls found")
    # Fresh mtimes prevent Gleam from reusing the preceding probe module.
    for control in controls:
        try:
            shutil.copyfile(control, PROBE_FILE)
            result = check()
            if result.returncode:
                sys.exit(
                    f"FAIL: positive control {control.name} did not compile:\n{result.stdout}"
                )
            print(f"PASS: positive control {control.stem} compiled")
        finally:
            PROBE_FILE.unlink(missing_ok=True)

    passed = 0
    for fixture in fixtures:
        expect_file = fixture.with_suffix(".expect")
        if not expect_file.exists():
            print(f"FAIL: Missing .expect for {fixture.name}", file=sys.stderr)
            sys.exit(1)

        fragments = [
            line.strip()
            for line in expect_file.read_text().splitlines()
            if line.strip() and not line.startswith("#")
        ]

        if not fragments:
            sys.exit(f"FAIL: empty expected diagnostic for {fixture.name}")

        try:
            shutil.copyfile(fixture, PROBE_FILE)
            result = check()
            if result.returncode == 0:
                print(
                    f"FAIL: {fixture.name} compiled successfully but was expected to fail!",
                    file=sys.stderr,
                )
                sys.exit(1)

            output = result.stdout
            for fragment in fragments:
                if fragment not in output:
                    print(
                        f"FAIL: {fixture.name} did not contain expected diagnostic fragment: {fragment!r}",
                        file=sys.stderr,
                    )
                    print(output, file=sys.stderr)
                    sys.exit(1)

            print(
                f"PASS: {fixture.stem} rejected at compile time with expected diagnostics"
            )
            passed += 1
        finally:
            if PROBE_FILE.exists():
                PROBE_FILE.unlink()

    print(f"All {passed} negative compiler fixtures rejected as expected.")


if __name__ == "__main__":
    main()
