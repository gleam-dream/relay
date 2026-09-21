#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
server_log="$(mktemp)"
server_pid=""
output_dir="$repo_root/build/conformance-results"

terminate_process_tree() {
  local parent_pid="$1"
  local child_pid
  while read -r child_pid; do
    if [[ -n "$child_pid" ]]; then
      terminate_process_tree "$child_pid"
    fi
  done < <(ps -axo pid=,ppid= | awk -v parent="$parent_pid" '$2 == parent { print $1 }')
  kill -TERM "$parent_pid" 2>/dev/null || true
}

cleanup() {
  if [[ -n "$server_pid" ]]; then
    terminate_process_tree "$server_pid"
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -f "$server_log"
}
trap cleanup EXIT

cd "$repo_root"
nix develop --command pnpm --dir scripts/conformance install --frozen-lockfile
nix develop --command gleam run -m relay_conformance_server >"$server_log" 2>&1 &
server_pid=$!

server_url=""
for _ in $(seq 1 120); do
  server_url="$(sed -n 's/^RELAY_CONFORMANCE_URL=//p' "$server_log" | tail -n 1)"
  if [[ -n "$server_url" ]]; then
    break
  fi
  if ! kill -0 "$server_pid" 2>/dev/null; then
    cat "$server_log" >&2
    exit 1
  fi
  sleep 0.25
done

if [[ -z "$server_url" ]]; then
  cat "$server_log" >&2
  echo "Relay conformance server did not report its endpoint" >&2
  exit 1
fi

mkdir -p "$output_dir"
nix develop --command node \
  scripts/conformance/node_modules/@modelcontextprotocol/conformance/dist/index.js \
  server \
  --url "$server_url" \
  --suite all \
  --spec-version 2026-07-28 \
  --output-dir "$output_dir"
