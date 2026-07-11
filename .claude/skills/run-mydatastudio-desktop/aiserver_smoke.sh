#!/usr/bin/env bash
# aiserver_smoke.sh — launch the Python aiserver on a fixed port and drive it
# with curl. No GGUF models required: the server skips model auto-load when the
# models dir is empty, and the health / skills / model-status endpoints work
# without any model loaded.
#
# Usage (from repo root or anywhere):
#   .claude/skills/run-mydatastudio-desktop/aiserver_smoke.sh
#
# Exit 0 = every checked endpoint responded as expected.
set -uo pipefail

PORT="${AICHAT_PORT:-8117}"
# Resolve the aiserver dir relative to this script (skill lives at
# <repo>/.claude/skills/run-mydatastudio-desktop/).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
AISERVER_DIR="$REPO_ROOT/aiserver"

fail() { echo "FAIL: $*" >&2; exit 1; }
[ -d "$AISERVER_DIR" ] || fail "aiserver dir not found at $AISERVER_DIR"

echo "== launching aiserver on port $PORT (pdm run python main.py) =="
cd "$AISERVER_DIR" || fail "cannot cd $AISERVER_DIR"
AICHAT_PORT="$PORT" AISERVER_LOG_LEVEL=info pdm run python main.py >/tmp/aiserver_smoke.log 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null' EXIT

echo "== waiting for server =="
up=0
for i in $(seq 1 30); do
  if curl -sf "http://127.0.0.1:$PORT/" >/dev/null 2>&1; then up=1; echo "up after ${i}s"; break; fi
  sleep 1
done
[ "$up" = 1 ] || { echo "--- server log ---"; cat /tmp/aiserver_smoke.log; fail "server never came up"; }

echo "== GET / (health) =="
curl -s "http://127.0.0.1:$PORT/" | python3 -m json.tool || fail "health check failed"
curl -s "http://127.0.0.1:$PORT/" | grep -q '"status": *"online"' || fail "health status not online"

echo "== GET /skills =="
curl -s "http://127.0.0.1:$PORT/skills" | python3 -c 'import sys,json;d=json.load(sys.stdin);print("skills:",len(d["skills"]))' \
  || fail "skills endpoint failed"

echo "== POST /util/model-status (reports whether the GGUF is on local disk) =="
curl -s -X POST "http://127.0.0.1:$PORT/util/model-status" \
  -H 'Content-Type: application/json' \
  -d '{"model_name":"ggml-org/gemma-4-12B-it-GGUF","filename":"gemma-4-12B-it-Q4_K_M.gguf"}' \
  | python3 -m json.tool || fail "model-status failed"

echo
echo "ALL CHECKS PASSED"
