#!/usr/bin/env bash
# launch_client.sh — build & launch the Flutter macOS client wired to an
# external aiserver, so you never need to build the Python binary or download
# GGUF models. Starts the aiserver on a fixed port, then runs the app with
# --dart-define=PYTHON_SERVER_URL pointing at it.
#
# After this returns "APP LAUNCHED", take a screenshot with the computer-use
# MCP (request_access for "MyDataStudio", then the screenshot tool). The plain
# `screencapture` CLI fails here with "could not create image from display"
# unless the calling terminal has macOS Screen Recording permission.
#
# Usage:  .claude/skills/run-mydatastudio-desktop/launch_client.sh
# Stop:   kill the flutter + aiserver PIDs it prints (or pkill -f mydatastudio.app).
set -uo pipefail

PORT="${AICHAT_PORT:-8117}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
AISERVER_DIR="$REPO_ROOT/aiserver"
CLIENT_DIR="$REPO_ROOT/client"
LOG="/tmp/mds_client_run.log"

echo "== starting aiserver on port $PORT =="
( cd "$AISERVER_DIR" && AICHAT_PORT="$PORT" AISERVER_LOG_LEVEL=info pdm run python main.py \
    >/tmp/mds_aiserver.log 2>&1 ) &
AISERVER_PID=$!
for i in $(seq 1 30); do
  curl -sf "http://127.0.0.1:$PORT/" >/dev/null 2>&1 && { echo "aiserver up (pid $AISERVER_PID)"; break; }
  sleep 1
done

echo "== flutter pub get =="
( cd "$CLIENT_DIR" && flutter pub get >/dev/null 2>&1 )

echo "== flutter run -d macos (PYTHON_SERVER_URL=http://127.0.0.1:$PORT) =="
( cd "$CLIENT_DIR" && flutter run -d macos \
    --dart-define=PYTHON_SERVER_URL="http://127.0.0.1:$PORT" >"$LOG" 2>&1 ) &
FLUTTER_PID=$!

echo "== waiting for app to launch (first build compiles pods; can take minutes) =="
for i in $(seq 1 120); do
  if grep -q "Flutter run key commands" "$LOG" 2>/dev/null; then
    echo "APP LAUNCHED after ~$((i*5))s"
    grep -m1 "Starting remote AI Chat service at" "$LOG" | sed 's/^flutter: *//' || true
    echo "flutter_pid=$FLUTTER_PID aiserver_pid=$AISERVER_PID  (log: $LOG)"
    echo "Now screenshot via computer-use MCP: request_access [\"MyDataStudio\"] then screenshot."
    exit 0
  fi
  if ! kill -0 "$FLUTTER_PID" 2>/dev/null; then
    echo "flutter run exited early; tail of log:"; tail -20 "$LOG"; exit 1
  fi
  sleep 5
done
echo "timed out waiting for launch; tail of log:"; tail -20 "$LOG"; exit 1
