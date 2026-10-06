#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
server_pid=""
output_root="${RELAY_CONFORMANCE_OUTPUT_DIR:-$repo_root/build/conformance-results}"
mkdir -p "$output_root"
output_dir="$(mktemp -d "$output_root/run.XXXXXX")"
server_log="$output_dir/server.log"
: >"$server_log"

# Invoked recursively by cleanup through the EXIT trap.
# shellcheck disable=SC2329
terminate_process_tree() {
  local parent_pid="$1"
  local child_pid
  while read -r child_pid; do
    if [[ -n $child_pid ]]; then
      terminate_process_tree "$child_pid"
    fi
  done < <(ps -axo pid=,ppid= | awk -v parent="$parent_pid" '$2 == parent { print $1 }')
  kill -TERM "$parent_pid" 2>/dev/null || true
}

# ShellCheck cannot follow the EXIT trap through the explicit status exits below.
# shellcheck disable=SC2329
cleanup() {
  if [[ -n $server_pid ]]; then
    terminate_process_tree "$server_pid"
    wait "$server_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

cd "$repo_root"
nix develop --no-update-lock-file --command pnpm --dir scripts/conformance install --frozen-lockfile
nix develop --no-update-lock-file --command gleam run -m relay_conformance_server >"$server_log" 2>&1 &
server_pid=$!

server_url=""
for _ in $(seq 1 120); do
  server_url="$(sed -n 's/^RELAY_CONFORMANCE_URL=//p' "$server_log" | tail -n 1)"
  if [[ -n $server_url ]]; then
    break
  fi
  if ! kill -0 "$server_pid" 2>/dev/null; then
    cat "$server_log" >&2
    exit 1
  fi
  sleep 0.25
done

if [[ -z $server_url ]]; then
  cat "$server_log" >&2
  echo "Relay conformance server did not report its endpoint" >&2
  exit 1
fi

cli="scripts/conformance/node_modules/@modelcontextprotocol/conformance/dist/index.js"
nix develop --no-update-lock-file --command node "$cli" list --server --spec-version 2026-07-28 >"$output_dir/selection.log"
cli_status=0
nix develop --no-update-lock-file --command node \
  "$cli" \
  server \
  --url "$server_url" \
  --suite all \
  --spec-version 2026-07-28 \
  --output-dir "$output_dir" || cli_status=$?
validation_status=0
nix develop --no-update-lock-file --command python3 -B scripts/check_conformance_results.py "$output_dir" --selection "$output_dir/selection.log" || validation_status=$?
echo "Server evidence: $output_dir"
if [[ $cli_status -ne 0 ]]; then
  exit "$cli_status"
fi
exit "$validation_status"
