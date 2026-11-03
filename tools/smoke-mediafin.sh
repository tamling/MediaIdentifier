#!/usr/bin/env bash
#
# Smoke-tests the `mediafin` binary end to end: builds it, starts it, and
# checks over a real socket that HTTPS works, that the interface is closed
# without the token and open with it, and that plain HTTP is not served on the
# TLS port.
#
# Run it from the repository root:
#     ./tools/smoke-mediafin.sh
#
set -euo pipefail

PORT="${MEDIAFIN_SMOKE_PORT:-8731}"
WORK="$(mktemp -d)"
export MEDIAFIN_CONFIG_DIR="$WORK/config"
BIN=".build/release/mediafin"
LOG="$WORK/server.log"
PID=""

cleanup() {
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  echo "--- server log ---" >&2
  cat "$LOG" >&2 || true
  exit 1
}

echo "==> Building"
swift build -c release --product mediafin
[ -x "$BIN" ] || fail "no binary at $BIN"

echo "==> --help works without any configuration"
"$BIN" --help | grep -q -- "--rotate-token" || fail "help text is missing options"

echo "==> Rejects bad input"
if "$BIN" --port 70000 >/dev/null 2>&1; then
  fail "an out-of-range port was accepted"
fi

echo "==> Starting on port $PORT"
"$BIN" --port "$PORT" --bind local >"$LOG" 2>&1 &
PID=$!

for _ in $(seq 1 60); do
  if curl -sk --max-time 2 "https://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then
    break
  fi
  kill -0 "$PID" 2>/dev/null || fail "the server exited during start-up"
  sleep 0.5
done

echo "==> /healthz answers over HTTPS"
health="$(curl -sk --max-time 5 "https://127.0.0.1:$PORT/healthz")" \
  || fail "could not reach /healthz over HTTPS"
[ "$health" = "ok" ] || fail "expected 'ok' from /healthz, got '$health'"

echo "==> The interface is closed without the token"
code="$(curl -sk --max-time 5 -o /dev/null -w '%{http_code}' "https://127.0.0.1:$PORT/")"
[ "$code" = "401" ] || fail "expected 401 without a token, got $code"

code="$(curl -sk --max-time 5 -o /dev/null -w '%{http_code}' \
  -H 'Authorization: Bearer wrong-token' "https://127.0.0.1:$PORT/api/status")"
[ "$code" = "401" ] || fail "expected 401 for a wrong token, got $code"

echo "==> The interface opens with the token"
TOKEN="$("$BIN" --print-token)"
[ -n "$TOKEN" ] || fail "--print-token printed nothing"
code="$(curl -sk --max-time 5 -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer $TOKEN" "https://127.0.0.1:$PORT/")"
[ "$code" = "200" ] || fail "expected 200 with the token, got $code"

echo "==> The token is not readable by other accounts"
mode="$(stat -c '%a' "$MEDIAFIN_CONFIG_DIR/token" 2>/dev/null \
  || stat -f '%Lp' "$MEDIAFIN_CONFIG_DIR/token")"
[ "$mode" = "600" ] || fail "token file mode is $mode, expected 600"

echo "==> Plain HTTP is not served on the TLS port"
if curl -s --max-time 5 "http://127.0.0.1:$PORT/healthz" 2>/dev/null | grep -q .; then
  fail "the TLS port answered an unencrypted request"
fi

echo "==> A certificate was created and is reported"
[ -f "$MEDIAFIN_CONFIG_DIR/cert.pem" ] || fail "no certificate was created"
grep -q "fingerprint" "$LOG" || fail "the certificate fingerprint was not reported"

echo "==> Shutting down on SIGTERM"
kill "$PID"
for _ in $(seq 1 20); do
  kill -0 "$PID" 2>/dev/null || break
  sleep 0.5
done
if kill -0 "$PID" 2>/dev/null; then
  fail "the server did not stop on SIGTERM"
fi
PID=""

echo
echo "All smoke tests passed."
