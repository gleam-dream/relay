#!/usr/bin/env bash
# Run application tests in the repository's Nix development shell.
set -euo pipefail
cd "$(dirname "$0")/.."
native_output="$(mktemp -d)"
trap 'rm -rf "$native_output"' EXIT
gleam build --warnings-as-errors
includes=()
for directory in build/dev/erlang/*/include; do includes+=(-I "$directory"); done
ERL_LIBS="$PWD/build/dev/erlang" find src test dev -name '*.erl' -exec erlc -Werror "${includes[@]}" -o "$native_output" {} +
gleam test
(cd examples/relay_usage && gleam build --warnings-as-errors && gleam test)
python3 -B scripts/check_negative_fixtures.py
python3 -B scripts/relay_schema_check.py
bash scripts/conformance/run-server-suite.sh
