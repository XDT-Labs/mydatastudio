#!/usr/bin/env bash
# Checks a built Linux bundle: its aiserver starts and enforces auth, and the app
# itself starts under Xvfb. The app only spawns its aiserver after onboarding,
# which a headless run can't reach, so the two are started separately here.
#
# Xvfb is started directly rather than through xvfb-run, which can keep waiting
# after the app has been killed. Every wait is bounded so a hang fails the job.
#
# Usage: linux_smoke_test.sh <bundle-dir>
set -euo pipefail

bundle=$(cd "$1" && pwd)
work=$(mktemp -d)
pids=()
cleanup() {
  for pid in "${pids[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
}
trap cleanup EXIT

echo "--- aiserver"
zip="$bundle/data/flutter_assets/app/aiserver-linux.zip"
[ -f "$zip" ] || { echo "Error: $zip is not in the bundle"; exit 1; }
unzip -q "$zip" -d "$work/aiserver"

AISERVER_TOKEN=smoke APP_SUPPORT_DIR="$work" AICHAT_MODELS_DIR="$work/models" \
  timeout 180 "$work/aiserver/aiserver" > "$work/aiserver.log" 2>&1 &
server=$!
pids+=("$server")

url=""
for _ in $(seq 1 120); do
  url=$(grep -oE 'http://(127\.0\.0\.1|localhost):[0-9]+' "$work/aiserver.log" | head -1 || true)
  [ -n "$url" ] && break
  kill -0 "$server" 2>/dev/null || break
  sleep 1
done
if [ -z "$url" ]; then
  echo "Error: aiserver printed no URL"
  tail -40 "$work/aiserver.log"
  exit 1
fi
echo "aiserver at $url"

status=$(curl -s -m 20 -o /dev/null -w '%{http_code}' "$url/skills")
[ "$status" = 401 ] || { echo "Error: /skills without a token returned $status, expected 401"; exit 1; }
status=$(curl -s -m 20 -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer smoke' "$url/skills")
[ "$status" = 200 ] || { echo "Error: /skills with the token returned $status, expected 200"; exit 1; }

kill -TERM "$server"
for _ in $(seq 1 10); do
  kill -0 "$server" 2>/dev/null || break
  sleep 1
done
if kill -0 "$server" 2>/dev/null; then
  echo "Error: aiserver ignored SIGTERM"
  exit 1
fi

echo "--- app under Xvfb"
Xvfb :99 -screen 0 1440x900x24 > /dev/null 2>&1 &
pids+=("$!")
sleep 2

mkdir -p "$work/home"
launcher="$bundle/mydatastudio"
[ -x "$bundle/AppRun" ] && launcher="$bundle/AppRun"
HOME="$work/home" DISPLAY=:99 timeout 60 "$launcher" > "$work/app.log" 2>&1 &
app=$!
pids+=("$app")
sleep 20

if ! kill -0 "$app" 2>/dev/null; then
  echo "Error: the app exited during startup"
  tail -40 "$work/app.log"
  exit 1
fi
if ! find "$work/home/.local/share" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | grep -q .; then
  echo "Error: the app created no support directory"
  tail -40 "$work/app.log"
  exit 1
fi
echo "Smoke test passed"
