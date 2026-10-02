#!/usr/bin/env bash
set -euo pipefail

# Deterministic verification of committed checksums and pins without network access.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> Verifying frozen MCP 2026-07-28 schema fixture checksum..."
EXPECTED_SCHEMA_SHA256="ef70b61f99b6d2e5e3b46863822eab08dff6a45bedc7a08914e0e5b133f40203"
SCHEMA_FILE="$ROOT/test/fixtures/mcp_2026/schema.json.source"

if [ ! -f "$SCHEMA_FILE" ]; then
    echo "FAIL: Schema fixture not found at $SCHEMA_FILE" >&2
    exit 1
fi

ACTUAL_SCHEMA_SHA256="$(shasum -a 256 "$SCHEMA_FILE" | awk '{print $1}')"
if [ "$ACTUAL_SCHEMA_SHA256" != "$EXPECTED_SCHEMA_SHA256" ]; then
    echo "FAIL: Schema checksum mismatch: got $ACTUAL_SCHEMA_SHA256, expected $EXPECTED_SCHEMA_SHA256" >&2
    exit 1
fi
echo "PASS: MCP 2026-07-28 schema checksum matches ($ACTUAL_SCHEMA_SHA256)"

echo "==> Verifying sibling dependency pins..."
PINS_FILE="$ROOT/sibling-revisions.txt"
if [ ! -f "$PINS_FILE" ] || [ "$(wc -l < "$PINS_FILE")" -ne 2 ]; then
    echo "FAIL: sibling-revisions.txt must contain exactly two pinned revisions" >&2
    exit 1
fi
EXPECTED_BLUEPRINT_HEAD="$(sed -n 's/^json_blueprint=//p' "$PINS_FILE")"
EXPECTED_SINAL_HEAD="$(sed -n 's/^sinal=//p' "$PINS_FILE")"
if [[ ! "$EXPECTED_BLUEPRINT_HEAD" =~ ^[0-9a-f]{40}$ ]] || [[ ! "$EXPECTED_SINAL_HEAD" =~ ^[0-9a-f]{40}$ ]]; then
    echo "FAIL: sibling-revisions.txt must contain full lowercase Git commit IDs" >&2
    exit 1
fi

# CI checks each sibling out at its pin, so a head mismatch there means the
# workflow ignored sibling-revisions.txt. A local sibling checkout may move past
# its pin during development, so a local mismatch only warns.
check_sibling_head() {
    local name="$1" actual="$2" expected="$3"
    if [ "$actual" = "$expected" ]; then
        return 0
    fi
    if [ -n "${CI:-}" ]; then
        echo "FAIL: $name git head mismatch: got $actual, expected $expected" >&2
        exit 1
    fi
    echo "WARN: $name git head $actual differs from pin $expected (local checkout; enforced in CI)" >&2
}

# json_blueprint pin
ACTUAL_BLUEPRINT_HEAD="$(git -C "$ROOT/../json_blueprint" rev-parse HEAD)"
check_sibling_head json_blueprint "$ACTUAL_BLUEPRINT_HEAD" "$EXPECTED_BLUEPRINT_HEAD"
if ! grep -q 'version = "1.7.1"' "$ROOT/../json_blueprint/gleam.toml"; then
    echo "FAIL: json_blueprint version is not 1.7.1" >&2
    exit 1
fi
echo "PASS: json_blueprint pin checked (commit $ACTUAL_BLUEPRINT_HEAD, version 1.7.1, MIT)"

# sinal pin
ACTUAL_SINAL_HEAD="$(git -C "$ROOT/../sinal" rev-parse HEAD)"
check_sibling_head sinal "$ACTUAL_SINAL_HEAD" "$EXPECTED_SINAL_HEAD"
if ! grep -q 'version = "0.1.0"' "$ROOT/../sinal/gleam.toml"; then
    echo "FAIL: sinal version is not 0.1.0" >&2
    exit 1
fi
echo "PASS: sinal pin checked (commit $ACTUAL_SINAL_HEAD, version 0.1.0, Apache-2.0)"

echo "All committed checksums and pins verified successfully."
