#!/usr/bin/env python3
"""Validate the pinned server suite's machine results independently of CLI exit."""

import argparse
import json
from pathlib import Path
import re

STATUSES = {"SUCCESS", "FAILURE", "WARNING", "INFO"}


def selection(text: str) -> tuple[str, ...]:
    names = []
    for line in text.splitlines():
        if not line.strip() or line == "Server scenarios (test against a server):":
            continue
        match = re.fullmatch(r"  - ([a-zA-Z0-9_-]+)(?: \[.*\])?", line)
        if not match:
            raise ValueError(f"unexpected server selection line: {line!r}")
        names.append(match[1])
    if not names or len(names) != len(set(names)):
        raise ValueError("empty or duplicate server scenario selection")
    return tuple(names)


def summarize(directory: Path, expected: tuple[str, ...]) -> dict:
    errors = []
    if not expected or len(expected) != len(set(expected)):
        errors.append("empty or duplicate server scenario selection")
    found = {}
    for path in sorted(directory.glob("server-*")):
        if not path.is_dir():
            continue
        match = re.fullmatch(
            r"server-(.+)-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-\d{3}Z", path.name
        )
        if not match or match[1] not in expected:
            errors.append(f"unexpected server result directory: {path.name}")
            continue
        name = match[1]
        if name in found:
            errors.append(f"duplicate server result: {name}")
        found[name] = path
    scenarios = []
    totals = dict.fromkeys(sorted(STATUSES), 0)
    for name in expected:
        path = found.get(name)
        if path is None or not (path / "checks.json").is_file():
            errors.append(f"missing or skipped required server scenario: {name}")
            continue
        try:
            checks = json.loads((path / "checks.json").read_text())
        except (OSError, ValueError) as error:
            errors.append(f"invalid checks for {name}: {error}")
            continue
        if not isinstance(checks, list) or any(
            not isinstance(item, dict)
            or not isinstance(item.get("status"), str)
            or item.get("status") not in STATUSES
            for item in checks
        ):
            errors.append(f"invalid check statuses for {name}")
            continue
        counts = {
            status: sum(item["status"] == status for item in checks)
            for status in sorted(STATUSES)
        }
        assertions = counts["SUCCESS"] + counts["FAILURE"]
        for status, count in counts.items():
            totals[status] += count
        if counts["FAILURE"] or counts["WARNING"]:
            errors.append(f"failed or warning server checks: {name}")
        if not assertions:
            errors.append(f"server scenario emitted no assertions: {name}")
        scenarios.append(
            {
                "name": name,
                "checks": counts,
                "assertions": assertions,
                "zero_check_non_evidence": not assertions,
            }
        )
    if not totals["SUCCESS"]:
        errors.append("server suite emitted no passing assertions")
    return {
        "accepted": not errors,
        "selected": len(expected),
        "reported": len(scenarios),
        "checks": totals,
        "zero_check_non_evidence": [
            item["name"] for item in scenarios if item["zero_check_non_evidence"]
        ],
        "scenarios": scenarios,
        "errors": errors,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--selection", required=True, type=Path)
    arguments = parser.parse_args()
    try:
        selected = selection(arguments.selection.read_text())
        summary = summarize(arguments.directory, selected)
    except (OSError, ValueError) as error:
        summary = {"accepted": False, "errors": [str(error)]}
    (arguments.directory / "summary.json").write_text(
        json.dumps(summary, indent=2) + "\n"
    )
    if not summary["accepted"]:
        raise SystemExit("Server evidence rejected: " + "; ".join(summary["errors"]))
    print(
        f"Accepted {summary['reported']} server scenario results, {summary['checks']['SUCCESS']} passing assertions; zero-check non-evidence: {summary['zero_check_non_evidence']}"
    )


if __name__ == "__main__":
    main()
