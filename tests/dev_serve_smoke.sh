#!/usr/bin/env bash
# `dev serve` on the support example, driven by curl (PLAN.md §19.2).
# Fake API keys: model calls fail, which covers the error paths.
# Run from the repository root: bash tests/dev_serve_smoke.sh
set -euo pipefail

cd "$(dirname "$0")/../examples/support"
port=${PORT:-4199}
base="http://127.0.0.1:$port"
log=$(mktemp)
db=$(mktemp -d)/smoke.sqlite

zig build install >/dev/null
ANTHROPIC_API_KEY=fake OPENAI_API_KEY=fake zig build dev -- serve --port "$port" --db "$db" >"$log" 2>&1 &
server=$!
trap 'kill $server 2>/dev/null; pkill -f "zastra-dev serve --port $port" 2>/dev/null || true; rm -f "$log"' EXIT

for _ in $(seq 1 600); do
  curl -sf "$base/api/agents" >/dev/null 2>&1 && break
  if ! kill -0 $server 2>/dev/null; then cat "$log"; echo "server exited"; exit 1; fi
  sleep 0.5
done

fail() { echo "FAIL: $*"; cat "$log"; exit 1; }
# expect <status> <grep pattern> <curl args...>
expect() {
  local want=$1 pattern=$2; shift 2
  local out status
  out=$(curl -s -w '\n%{http_code}' "$@")
  status=${out##*$'\n'}
  out=${out%$'\n'*}
  [ "$status" = "$want" ] || fail "$* -> $status (want $want): $out"
  grep -q -- "$pattern" <<<"$out" || fail "$* -> no '$pattern' in: $out"
  echo "ok  $status $*"
}

expect 200 '"id":"support"' "$base/api/agents"
expect 200 '"spends_money"' "$base/api/agents/support"
expect 404 '"UnknownAgent"' "$base/api/agents/nobody"
expect 200 '"handle_ticket"' "$base/api/workflows"
expect 200 'flowchart' "$base/api/workflows/handle_ticket/graph"
expect 200 '"context_window"' "$base/api/models"
expect 200 '^\[' "$base/api/runs"
expect 404 '"RunNotFound"' "$base/api/runs/nope"
expect 400 '"InvalidInput"' -X POST -d '{"input":7}' "$base/api/agents/support/generate"
# A fake key: the provider rejects it.
expect 502 '"Unauthorized"' -X POST -d '{"input":"hi"}' "$base/api/agents/support/generate"
expect 200 'event: error' -N -X POST -d '{"input":"hi"}' "$base/api/agents/support/stream"
# Security rules.
expect 403 '"ForbiddenHost"' -H 'Host: evil.example' "$base/api/agents"
expect 403 '"ForbiddenOrigin"' -H 'Origin: https://evil.example' "$base/api/agents"
expect 413 '"BodyTooLarge"' -X POST -H 'Content-Type: application/json' --data-binary @<(head -c 1048577 /dev/zero | tr '\0' ' ') "$base/api/agents/support/generate"
echo "dev serve smoke: all passed"
