#!/usr/bin/env bash
#
# Smoke-tests the `mediafin` binary: the headless runner that holds the engine
# so scheduled work happens with no window open.
#
# It used to test a web server — HTTPS, an access token, a /healthz endpoint.
# That server is gone, and so are its options, so testing for them was testing
# that a deleted feature still existed.
#
# What matters about this binary is the process contract around it, because a
# systemd unit and a cron line both depend on it: --once has to RETURN, --watch
# has to stay up and stop on SIGTERM, and a bare invocation must not silently
# do nothing. Whether the schedule picks the right moment is the engine's
# business and is covered by the Core tests.
#
# Run it from the repository root:
#     ./tools/smoke-mediafin.sh
#
set -euo pipefail

WORK="$(mktemp -d)"
export MEDIAFIN_CONFIG_DIR="$WORK/config"
BIN=".build/release/mediafin"
LOG="$WORK/runner.log"
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
  if [ -f "$LOG" ]; then
    echo "--- runner log ---" >&2
    cat "$LOG" >&2 || true
  fi
  exit 1
}

echo "==> Building"
swift build -c release --product mediafin
[ -x "$BIN" ] || fail "no binary at $BIN"

echo "==> --help names what it offers"
"$BIN" --help | grep -q -- "--watch" || fail "--help does not mention --watch"
"$BIN" --help | grep -q -- "--once" || fail "--help does not mention --once"

echo "==> --help says where the interface is"
# Because this binary draws nothing, and somebody who runs it expecting a
# window needs to be told where the window is rather than left guessing.
"$BIN" --help | grep -q "mediafin-gtk" || fail "--help does not point at the window"

echo "==> --version prints a version"
"$BIN" --version | grep -qE "Mediafin [0-9]+\.[0-9]+\.[0-9]+" \
  || fail "--version printed something unexpected"

echo "==> A bare invocation refuses rather than doing nothing"
code=0
"$BIN" >"$LOG" 2>&1 || code=$?
[ "$code" = "64" ] || fail "a bare invocation exited $code, expected 64"
grep -q "mediafin-gtk" "$LOG" || fail "a bare invocation did not say where to go"

echo "==> An unknown option refuses"
code=0
"$BIN" --serve >/dev/null 2>&1 || code=$?
[ "$code" = "64" ] || fail "an unknown option exited $code, expected 64"

echo "==> --once returns instead of sitting there"
# The whole point: a cron line that never returns piles up, and systemd would
# kill a run it thinks has hung. Nothing is scheduled here, so there is no
# work — this is about the process coming back at all.
timeout 90 "$BIN" --once >"$LOG" 2>&1 || fail "--once did not finish"

echo "==> --watch stays up and stops on SIGTERM"
"$BIN" --watch >"$LOG" 2>&1 &
PID=$!
sleep 3
kill -0 "$PID" 2>/dev/null || fail "--watch exited on its own"
kill "$PID"
for _ in $(seq 1 20); do
  kill -0 "$PID" 2>/dev/null || break
  sleep 0.5
done
if kill -0 "$PID" 2>/dev/null; then
  # SIGKILL first, and only then fail. Without this the cleanup trap's
  # `wait` blocks on a process that is ignoring SIGTERM -- which is exactly
  # what happened, and a check that hangs for six hours is worse than no
  # check: it reports nothing, and it holds the runner while doing it.
  kill -9 "$PID" 2>/dev/null || true
  wait "$PID" 2>/dev/null || true
  PID=""
  fail "--watch did not stop on SIGTERM (it had to be killed)"
fi
PID=""

echo "==> A credentials file left world-readable is tightened"
# This used to loop over one path that is never there. The comment explaining
# why -- "the engine writes when there is something to write, and with nothing
# configured there is nothing" -- was correct, and it meant `[ -f ]` was
# always false, `continue` always fired, and the stat and the mode comparison
# never ran. The step printed "Nothing secret is left world-readable" on every
# run while checking nothing, and it is the ONLY permission assertion in the
# smoke test of the binary that runs as a systemd service.
#
# So the file is put there, deliberately readable by everyone, and the
# assertion is about what the program does with it: AppCoordinator's init
# calls tightenPermissionsIfNeeded, which is the defence this is for.
install -d -m 700 "$MEDIAFIN_CONFIG_DIR"
secret="$MEDIAFIN_CONFIG_DIR/secrets.json"
printf '{"local-llm-api-key":"not-a-real-key"}\n' > "$secret"
chmod 644 "$secret"
before="$(stat -c '%a' "$secret" 2>/dev/null || stat -f '%Lp' "$secret")"
[ "$before" = "644" ] || fail "the fixture is mode $before, so it proves nothing"
timeout 90 "$BIN" --once >"$LOG" 2>&1 || fail "--once did not finish"
mode="$(stat -c '%a' "$secret" 2>/dev/null || stat -f '%Lp' "$secret")"
[ "$mode" = "600" ] || fail "$secret is still mode $mode after a run, expected 600"
# And the key itself survived the tightening.
grep -q "not-a-real-key" "$secret" || fail "the credentials file was rewritten"

echo
echo "All smoke tests passed."
